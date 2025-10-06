#!/bin/bash
set -euo pipefail

CID="040b6694-b599-4742-ae79-93597727c5c0"  # reuse your clientID
HDR=(-H "Accept: application/json"
     -H "X-Plex-Client-Identifier: $CID"
     -H "X-Plex-Product: K8sPlexClaimer"
     -H "X-Plex-Version: 1.0"
     -H "X-Plex-Device: Script"
     -H "X-Plex-Platform: Linux")

# 1) Create PIN (strong=true)
PIN_JSON="$(curl -fsSL -X POST "https://plex.tv/api/v2/pins?strong=true" "${HDR[@]}")"
PIN_ID="$(printf '%s' "$PIN_JSON" | jq -r .id)"
PIN_CODE="$(printf '%s' "$PIN_JSON" | jq -r .code)"
echo "Open: https://app.plex.tv/auth#?clientID=$CID&code=$PIN_CODE&context%5Bdevice%5D%5Bproduct%5D=K8sPlexClaimer"

# 2) Poll for long-lived token (authToken)
for i in {1..90}; do
  RES="$(curl -fsSL "https://plex.tv/api/v2/pins/$PIN_ID" "${HDR[@]}")"
  TOK="$(printf '%s' "$RES" | jq -r .authToken)"
  if [ "$TOK" != "null" ]; then
    echo "X-Plex-Token=$TOK"
    exit 0
  fi
  sleep 1
done

echo "Timed out waiting for approval (did you click 'Allow' on the Plex page?)" >&2
exit 1
