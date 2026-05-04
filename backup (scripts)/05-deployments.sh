#!/bin/bash
# =============================================================================
# 05-deployments.sh
# Despliegue de phpMyAdmin, Secrets, ConfigMap y manifiestos de MariaDB externo
# =============================================================================

set -euo pipefail

MARIADB_IP="10.2.2.191"
DOMAIN="meu-project.me"
PMA_DOMAIN="pma.meu-project.me"
PUBLIC_IP="54.144.217.31"

echo "======================================================"
echo " PASO 1 — Namespace y directorios"
echo "======================================================"

mkdir -p ~/saas-hosting/k8s/{database,phpmyadmin,secrets,configmaps,ingress}

echo ""
echo "======================================================"
echo " PASO 2 — Secret MariaDB"
echo "======================================================"

# Generar base64
ROOT_PASS=$(echo -n "ITB2026" | base64)
DB_USER=$(echo -n "meu_admin" | base64)
DB_PASS=$(echo -n "ITB2026" | base64)

cat <<EOF > ~/saas-hosting/k8s/secrets/secret-mariadb.yaml
apiVersion: v1
kind: Secret
metadata:
  name: mariadb-credentials
  namespace: default
type: Opaque
data:
  MARIADB_ROOT_PASSWORD: ${ROOT_PASS}
  MARIADB_USER: ${DB_USER}
  MARIADB_PASSWORD: ${DB_PASS}
EOF

kubectl apply -f ~/saas-hosting/k8s/secrets/secret-mariadb.yaml
kubectl get secret mariadb-credentials

echo ""
echo "======================================================"
echo " PASO 3 — ConfigMap MariaDB"
echo "======================================================"

cat <<EOF > ~/saas-hosting/k8s/configmaps/configmap-mariadb.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mariadb-config
  namespace: default
data:
  my.cnf: |
    [mariadb]
    skip-name-resolve
    collation-server             = utf8mb4_unicode_ci
    innodb_buffer_pool_size      = 512M
    innodb_buffer_pool_instances = 1
    innodb_file_per_table        = 1
    max_connections              = 80
    tmp_table_size               = 64M
    max_heap_table_size          = 64M
  DB_HOST: "${MARIADB_IP}"
  DB_PORT: "3306"
  DB_NAME: "plataforma_hosting"
EOF

kubectl apply -f ~/saas-hosting/k8s/configmaps/configmap-mariadb.yaml

echo ""
echo "======================================================"
echo " PASO 4 — Service + Endpoints externo MariaDB"
echo "======================================================"

cat <<EOF > ~/saas-hosting/k8s/database/mariadb-external-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: mariadb-externo
  namespace: default
spec:
  type: ClusterIP
  ports:
  - port: 3306
    targetPort: 3306
    protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: mariadb-externo
  namespace: default
subsets:
- addresses:
  - ip: ${MARIADB_IP}
  ports:
  - port: 3306
EOF

kubectl apply -f ~/saas-hosting/k8s/database/mariadb-external-service.yaml
kubectl describe service mariadb-externo | grep Endpoints

echo ""
echo "======================================================"
echo " PASO 5 — phpMyAdmin"
echo "======================================================"

cat <<EOF > ~/saas-hosting/k8s/phpmyadmin/phpmyadmin.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: phpmyadmin
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: phpmyadmin
  template:
    metadata:
      labels:
        app: phpmyadmin
    spec:
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      nodeSelector:
        kubernetes.io/hostname: k8s-master
      containers:
      - name: phpmyadmin
        image: phpmyadmin:latest
        ports:
        - containerPort: 80
        env:
        - name: PMA_HOST
          value: "${MARIADB_IP}"
        - name: PMA_PORT
          value: "3306"
        - name: PMA_ABSOLUTE_URI
          value: "https://${PMA_DOMAIN}/"
---
apiVersion: v1
kind: Service
metadata:
  name: phpmyadmin-service
  namespace: default
spec:
  selector:
    app: phpmyadmin
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: phpmyadmin-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "${PUBLIC_IP}/32"
spec:
  ingressClassName: nginx
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

kubectl apply -f ~/saas-hosting/k8s/phpmyadmin/phpmyadmin.yaml

echo ""
echo "======================================================"
echo " PASO 6 — Verificación general"
echo "======================================================"

echo "--- Pods ---"
kubectl get pods -o wide

echo "--- Services ---"
kubectl get svc

echo "--- Ingress ---"
kubectl get ingress

echo ""
echo "======================================================"
echo " VERIFICACIÓN DE CONECTIVIDAD A MARIADB"
echo "======================================================"
bash -c "timeout 5 bash -c 'echo > /dev/tcp/${MARIADB_IP}/3306' && echo '✅ MARIADB CONECTADO' || echo '❌ TIMEOUT — revisar SG o VPC Peering'"

echo ""
echo "✅ Despliegues completados."
echo "   phpMyAdmin: http://${PMA_DOMAIN}"
echo "   Para TLS: ejecutar 06-tls.sh"
