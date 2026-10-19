# plattform-flux

Plattformkomponenter styrt av Flux – samme struktur for det lokale klusteret
(Rancher Desktop) og AKS. Første komponent: **cert-manager** med utstedere.

```
plattform-flux/
├── bootstrap/lokal.yaml            kobler et lokalt kluster til repoet
├── clusters/
│   ├── lokal/                      det Flux følger lokalt
│   │   ├── cluster-vars.yaml       variabler for klusteret (ingen hemmeligheter)
│   │   └── infrastruktur.yaml      lag 1: controllers → lag 2: configs
│   └── azure-utv/                  det samme for AKS utv
├── infrastruktur/
│   ├── kilder/                     Helm-repoer (jetstack)
│   ├── controllers/                programvare som lager CRD-er
│   │   ├── base/cert-manager/      felles HelmRelease (v1.21.2)
│   │   ├── lokal/                  base uten tillegg
│   │   └── azure-utv/              base + workload identity
│   └── configs/                    ressurser som bruker CRD-ene
│       ├── lokal/                  egen CA → ClusterIssuer 'plattform'
│       └── azure-utv/              Let's Encrypt (DNS-01, Azure DNS) → 'plattform'
├── eksempler/gateway-https.yaml    neste steg: HTTPS på Gatewayen
└── scripts/stol-pa-lokal-ca.sh     få Windows til å stole på den lokale CA-en
```

## Prinsippene

- **Base + miljø:** det som er likt ligger i `base/`, miljøene legger bare til forskjellene.
- **To lag med rekkefølge:** `infra-configs` venter på `infra-controllers`, så
  cert-manager og CRD-ene finnes før ClusterIssuers lages.
- **Variabler per kluster:** `${NAVN}` i manifestene fylles fra
  `clusters/<miljø>/cluster-vars.yaml` (Flux `postBuild.substituteFrom`).
- **Samme navn overalt:** ClusterIssuer-en heter `plattform` både lokalt og i
  Azure. Apper og Gateways skriver `cert-manager.io/cluster-issuer: plattform`
  og fungerer likt i begge miljøer – bare utstederen bak er forskjellig.

## Lokalt og Let's Encrypt

Let's Encrypt kan **ikke** brukes lokalt. LE må enten nå domenet over internett
(HTTP-01) eller se en TXT-post i offentlig DNS (DNS-01). `*.localhost` er ingen
av delene. Lokalt lager cert-manager derfor en egen CA, og du kan få Windows til
å stole på den med `scripts/stol-pa-lokal-ca.sh`.

## Kom i gang lokalt

Forutsetter Rancher Desktop med Flux installert (`flux install`) og Gateway
API-CRD-ene på plass (installeres av `storkonf-k8s/scripts/lokal-opp.sh`).

```bash
# 1. Push repoet (privat) og lag et fine-grained token: Contents Read-only
git init -b main && git add . && git commit -m "Plattform: cert-manager"
git remote add origin https://github.com/<din-bruker>/plattform-flux.git
git push -u origin main

# 2. Tilgang for Flux
read -rs -p "GitHub PAT: " PAT; echo
kubectl create secret generic plattform-git -n flux-system \
  --from-literal=username=git --from-literal=password="$PAT"
unset PAT

# 3. Koble klusteret til repoet
sed -i 's|DIN-BRUKER|<din-bruker>|' bootstrap/lokal.yaml
kubectl apply -f bootstrap/lokal.yaml

# 4. Følg med
flux get kustomizations                     # plattform → infra-controllers → infra-configs
flux get helmreleases -n cert-manager
kubectl get pods -n cert-manager
kubectl get clusterissuer                   # selvsignert, plattform: READY True
kubectl get certificate -A                  # lokal-ca og test-localhost: READY True

# 5. (valgfritt) stol på den lokale CA-en i Windows
./scripts/stol-pa-lokal-ca.sh
```

## AKS utv

> UTKAST. Avklares med plattformteamet før bruk.

**Forutsetninger i Azure** (én gang):

```bash
# Managed identity for cert-manager
az identity create -g <rg> -n cert-manager-utv
CLIENT_ID=$(az identity show -g <rg> -n cert-manager-utv --query clientId -o tsv)

# Lov å endre DNS-sonen (bare den ene sonen)
SONE_ID=$(az network dns zone show -g <dns-rg> -n <sone> --query id -o tsv)
az role assignment create --assignee "$CLIENT_ID" --role "DNS Zone Contributor" --scope "$SONE_ID"

# Stol på tokens fra klusterets ServiceAccount cert-manager/cert-manager
ISSUER=$(az aks show -g <rg> -n <aks> --query oidcIssuerProfile.issuerUrl -o tsv)
az identity federated-credential create -g <rg> --identity-name cert-manager-utv \
  -n cert-manager --issuer "$ISSUER" \
  --subject system:serviceaccount:cert-manager:cert-manager \
  --audiences api://AzureADTokenExchange
```

Klusteret må ha OIDC issuer og workload identity slått på
(`az aks update --enable-oidc-issuer --enable-workload-identity`).

Fyll inn `clusters/azure-utv/cluster-vars.yaml`, og koble klusteret til repoet –
enten med AKS sin Flux-utvidelse (Microsoft-støttet):

```bash
az k8s-configuration flux create -g <rg> -c <aks> -t managedClusters \
  -n plattform --namespace flux-system --scope cluster \
  -u https://github.com/<org>/plattform-flux --branch main \
  --kustomization name=plattform path=./clusters/azure-utv prune=true
```

…eller med `flux bootstrap`. Test først med `letsencrypt-staging` (testsertifikatet
gjør det), og bytt til `plattform` (produksjon) når staging virker.

## Sikkerhet

- **Let's Encrypt publiserer alle vertsnavn** i offentlige Certificate
  Transparency-logger. Alle navn du lager sertifikat for, blir søkbare (f.eks. på
  crt.sh). For interne tjenester kan en intern CA (cert-manager har utstedere for
  bl.a. Vault og ADCS) være et bedre valg. Avklar med informasjonssikkerhet.
- **Workload identity** i Azure: ingen passord til DNS lagres i klusteret.
  Identiteten har bare `DNS Zone Contributor` på én sone.
- **Lokal CA:** stol bare på den på din egen maskin, og fjern den
  (`./scripts/stol-pa-lokal-ca.sh --fjern`) når du ikke trenger den.
  Privatnøkkelen ligger i klusteret (`cert-manager/lokal-ca`).

## Neste steg

1. Flytt Gateway API-CRD-ene, Traefik og Gatewayen hit (`infrastruktur/controllers`
   og `configs`), slik at `lokal-opp.sh` ikke lenger installerer dem.
2. Legg til HTTPS-listener med `cert-manager.io/cluster-issuer: plattform`
   (se `eksempler/gateway-https.yaml`).
3. Flere plattformkomponenter etter samme mønster (f.eks. external-secrets,
   overvåking).
