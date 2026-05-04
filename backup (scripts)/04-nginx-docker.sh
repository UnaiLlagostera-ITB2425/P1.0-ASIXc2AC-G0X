#!/bin/bash
# =============================================================================
# 04-nginx-docker.sh
# Configuración del proxy NGINX en Docker
# =============================================================================

set -euo pipefail

echo "======================================================"
echo " PASO 1 — Crear estructura de directorios"
echo "======================================================"

mkdir -p ~/nginx-docker/{conf,certs,html}

echo ""
echo "======================================================"
echo " PASO 2 — docker-compose.yml"
echo "======================================================"

cat <<'EOF' > ~/nginx-docker/docker-compose.yml
services:
  nginx-proxy:
    image: nginx:alpine
    container_name: nginx-proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
      - ./html:/usr/share/nginx/html:ro
    networks:
      - nginx-net
    restart: unless-stopped

networks:
  nginx-net:
    driver: bridge
EOF

echo ""
echo "======================================================"
echo " PASO 3 — nginx.conf"
echo "======================================================"

# Obtener el NodePort del Ingress (se necesita el clúster levantado)
INGRESS_HTTP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
INGRESS_HTTPS=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')

echo "NodePort HTTP:  ${INGRESS_HTTP}"
echo "NodePort HTTPS: ${INGRESS_HTTPS}"

cat <<EOF > ~/nginx-docker/conf/nginx.conf
events {
    worker_connections 1024;
}

http {
    server {
        listen 80;
        server_name _;

        location / {
            proxy_pass http://10.0.1.204:${INGRESS_HTTP};
            proxy_set_header Host              \$host;
            proxy_set_header X-Real-IP         \$remote_addr;
            proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }

    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;

        location / {
            proxy_pass https://10.0.1.204:${INGRESS_HTTPS};
            proxy_set_header Host              \$host;
            proxy_set_header X-Real-IP         \$remote_addr;
            proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF

echo ""
echo "======================================================"
echo " PASO 4 — Levantar el proxy"
echo "======================================================"

cd ~/nginx-docker
docker compose up -d
docker compose ps

echo ""
echo "✅ Proxy NGINX levantado. Continúa con: 05-deployments.sh"
