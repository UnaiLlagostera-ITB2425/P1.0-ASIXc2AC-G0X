#!/bin/bash
# =============================================================================
# 06-tls.sh
# Configuración de TLS con cert-manager para todos los dominios
# Requiere que los dominios apunten ya a la IP pública: 54.144.217.31
# =============================================================================

set -euo pipefail

DOMAIN="meu-project.me"
PMA_DOMAIN="pma.meu-project.me"

echo "======================================================"
echo " PASO 1 — Verificar DNS (los dominios deben apuntar a 54.144.217.31)"
echo "======================================================"

echo "Verificando ${DOMAIN}..."
dig +short ${DOMAIN} || nslookup ${DOMAIN}

echo "Verificando ${PMA_DOMAIN}..."
dig +short ${PMA_DOMAIN} || nslookup ${PMA_DOMAIN}

echo ""
echo "======================================================"
echo " PASO 2 — Ingress principal con TLS"
echo "======================================================"

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: meu-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${DOMAIN}
    - www.${DOMAIN}
    secretName: meu-project-tls
  rules:
  - host: ${DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: meu-svc
            port:
              number: 80
  - host: www.${DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: meu-svc
            port:
              number: 80
EOF

echo ""
echo "======================================================"
echo " PASO 3 — Ingress phpMyAdmin con TLS"
echo "======================================================"

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: phpmyadmin-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/whitelist-source-range: "54.144.217.31/32"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - ${PMA_DOMAIN}
    secretName: pma-meu-project-tls
  rules:
  - host: ${PMA_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: phpmyadmin-service
            port:
              number: 80
EOF

echo ""
echo "======================================================"
echo " PASO 4 — Monitorizar emisión de certificados"
echo "======================================================"

echo "Esperando emisión de certificados (puede tardar 1-3 minutos)..."
sleep 30

kubectl get certificate
kubectl get certificaterequest
kubectl describe certificate meu-project-tls 2>/dev/null || true
kubectl describe certificate pma-meu-project-tls 2>/dev/null || true

echo ""
echo "✅ TLS configurado."
echo "   Dominio principal: https://${DOMAIN}"
echo "   phpMyAdmin:        https://${PMA_DOMAIN}"
