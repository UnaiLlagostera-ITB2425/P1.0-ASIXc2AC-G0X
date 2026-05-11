# YAML Template Maestro

---

## Contexto y justificación

Cuando la API recibe una petición para crear un nuevo cliente, necesita desplegar automáticamente tres recursos Kubernetes: un **Deployment** (pod con Nginx+PHP-FPM), un **Service** (expone el pod internamente) y un **Ingress** (enruta el dominio del cliente al Service). En lugar de generar YAML estático para cada cliente, usamos un **Helm chart propio** parametrizado que se instancia por cliente.

Todo se gestiona desde el **master** (`k8s-master`).

---

## Decisiones de diseño

| Decisión | Justificación |
|----------|---------------|
| **Helm chart propio** | `helm install/upgrade/uninstall` por cliente, historial de revisiones y rollback |
| **Namespace por cliente** | Aislamiento de recursos, cuotas y RBAC independientes |
| **IngressClass: nginx** | Usa el ingress-nginx desplegado en `k8s-submaster` |
| **ClusterIP para el Service** | El tráfico externo siempre pasa por el Ingress |
| **Resource limits** | Evita que un cliente consuma todos los recursos del nodo |

---

## Estructura del chart
~/saas-hosting/helm/client-chart/
├── Chart.yaml
├── values.yaml
└── templates/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
└── ingress.yaml

text

Crear la estructura desde el master:

```bash
mkdir -p ~/saas-hosting/helm/client-chart/templates
cd ~/saas-hosting/helm/client-chart
```

---

## `Chart.yaml`

```bash
cat > Chart.yaml << 'EOF'
apiVersion: v2
name: client-chart
description: Chart para despliegue de clientes SaaS
type: application
version: 1.0.0
appVersion: "1.0.0"
EOF
```

---

## `values.yaml`

```bash
cat > values.yaml << 'EOF'
client:
  name: "default"
  domain: "default.meu-project.me"
  image: "saas-php:8.3"

resources:
  requests:
    memory: "64Mi"
    cpu: "50m"
  limits:
    memory: "256Mi"
    cpu: "250m"

replicaCount: 1
EOF
```

---

## `templates/namespace.yaml`

```bash
cat > templates/namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: client-{{ .Values.client.name }}
  labels:
    managed-by: saas-api
    client: {{ .Values.client.name }}
EOF
```

---

## `templates/deployment.yaml`

```bash
cat > templates/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.client.name }}-deployment
  namespace: client-{{ .Values.client.name }}
  labels:
    app: {{ .Values.client.name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.client.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.client.name }}
    spec:
      containers:
        - name: php-nginx
          image: {{ .Values.client.image }}
          ports:
            - containerPort: 8080
          resources:
            requests:
              memory: {{ .Values.resources.requests.memory }}
              cpu: {{ .Values.resources.requests.cpu }}
            limits:
              memory: {{ .Values.resources.limits.memory }}
              cpu: {{ .Values.resources.limits.cpu }}
EOF
```

---

## `templates/service.yaml`

```bash
cat > templates/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.client.name }}-service
  namespace: client-{{ .Values.client.name }}
spec:
  type: ClusterIP
  selector:
    app: {{ .Values.client.name }}
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
EOF
```

---

## `templates/ingress.yaml`

```bash
cat > templates/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Values.client.name }}-ingress
  namespace: client-{{ .Values.client.name }}
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - {{ .Values.client.domain }}
      secretName: {{ .Values.client.name }}-tls
  rules:
    - host: {{ .Values.client.domain }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Values.client.name }}-service
                port:
                  number: 80
EOF
```

---

## Uso

```bash
# Instalar cliente nuevo
helm install cliente-acme ~/saas-hosting/helm/client-chart \
  --set client.name=acme \
  --set client.domain=acme.meu-project.me \
  --set client.image=registry.meu-project.me/saas-php:8.3

# Actualizar cliente
helm upgrade cliente-acme ~/saas-hosting/helm/client-chart \
  --set client.name=acme \
  --set client.domain=acme.meu-project.me

# Eliminar cliente
helm uninstall cliente-acme
kubectl delete namespace client-acme
```

---

## Verificación

```bash
helm list -A
kubectl get all -n client-acme
kubectl get ingress -n client-acme
```

---

## Diagrama de flujo
API recibe POST /clients {name: "acme", domain: "acme.meu-project.me"}
↓
helm install client-chart --set client.name=acme --set client.domain=...
↓
Kubernetes crea:
├── Namespace: client-acme
├── Deployment: acme-deployment → Pod con saas-php:8.3
├── Service: acme-service → ClusterIP :80 → :8080
└── Ingress: acme-ingress → acme.meu-project.me → acme-service