#!/bin/bash
# =============================================================================
# 03-addons.sh
# Instalación de addons: Ingress NGINX, cert-manager, local-path-provisioner
# =============================================================================

set -euo pipefail

echo "======================================================"
echo " PASO 1 — Ingress NGINX Controller"
echo "======================================================"

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

# Mover Ingress al Master para estabilidad
echo "Esperando a que el Ingress esté listo..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type=json \
  -p='[
    {"op":"add","path":"/spec/template/spec/tolerations","value":[
      {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}
    ]},
    {"op":"add","path":"/spec/template/spec/nodeSelector","value":{
      "kubernetes.io/hostname":"k8s-master"
    }}
  ]'

kubectl get svc -n ingress-nginx

echo ""
echo "======================================================"
echo " PASO 2 — cert-manager"
echo "======================================================"

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml

echo "Esperando a que cert-manager esté listo (90s)..."
sleep 90
kubectl get pods -n cert-manager

echo ""
echo "======================================================"
echo " PASO 3 — local-path-provisioner (StorageClass default)"
echo "======================================================"

kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml

# Marcar como StorageClass por defecto
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl get storageclass

echo ""
echo "======================================================"
echo " PASO 4 — ClusterIssuer Let's Encrypt"
echo "======================================================"

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: erick.garcia.7e8@itb.cat
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

kubectl get clusterissuer

echo ""
echo "✅ Addons instalados. Continúa con: 04-nginx-docker.sh"
