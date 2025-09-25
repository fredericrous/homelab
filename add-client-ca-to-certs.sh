#!/bin/bash

# Add client CA to cert-manager TLS secrets for mTLS
CA_CRT=$(kubectl get secret client-ca-cert -n istio-ingress -o jsonpath='{.data.ca\.crt}')

SERVICES=("authelia:authelia" "plex:plex" "nextcloud:nextcloud" "nextcloud:nextcloud-mobile")

for SERVICE_INFO in "${SERVICES[@]}"; do
  NAMESPACE=$(echo $SERVICE_INFO | cut -d: -f1)
  SECRET=$(echo $SERVICE_INFO | cut -d: -f2)
  
  echo "Adding client CA to ${SECRET}-tls secret in ${NAMESPACE} namespace..."
  
  kubectl patch secret ${SECRET}-tls -n ${NAMESPACE} \
    --patch="{\"data\":{\"ca.crt\":\"$CA_CRT\"}}"
    
  echo "✅ Added client CA to ${SECRET}-tls"
done

echo "🎉 Client CA added to all TLS secrets!"