#!/usr/bin/env bash
# Henter den lokale CA-en fra klusteret og legger den i Windows' sertifikatlager
# for DIN bruker, så nettlesere (Edge/Chrome) stoler på https://*.localhost.
#
#   ./scripts/stol-pa-lokal-ca.sh          legg til
#   ./scripts/stol-pa-lokal-ca.sh --fjern  fjern igjen
#
# Gjelder bare din Windows-bruker og bare denne CA-en. Firefox har eget lager.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(kubectl config current-context)" == "rancher-desktop" ]] \
  || { echo "Avbryter: konteksten er ikke rancher-desktop." >&2; exit 1; }

NAVN="Lokal plattform-CA (rancher-desktop)"

if [[ "${1:-}" == "--fjern" ]]; then
  certutil.exe -user -delstore Root "$NAVN"
  exit 0
fi

kubectl get secret lokal-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > lokal-ca.crt
echo "Lagret lokal-ca.crt. Windows spør om du vil stole på sertifikatet – svar Ja."
certutil.exe -user -addstore Root lokal-ca.crt
echo "Ferdig. Test: curl --cacert lokal-ca.crt https://sal.localhost/   (når HTTPS er satt opp)"
