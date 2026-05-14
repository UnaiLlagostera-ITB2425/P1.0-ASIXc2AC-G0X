# YAML Template Maestro

---

## Contexto y justificación

Cuando la API recibe una petición para crear un nuevo cliente, necesita desplegar automáticamente tres recursos Kubernetes: un **Deployment** (pod con Nginx+PHP-FPM), un **Service** (expone el pod internamente) y un **Ingress** (enruta el dominio del cliente al Service). En lugar de generar YAML estático para cada cliente, usamos un **Helm chart propio** parametrizado que se instancia por cliente.

Todo se gestiona desde el **master** (`k8s-master`).

### ¿Por qué Helm y no YAML estático?

| Opción | Problema |
|--------|----------|
| YAML estático por cliente | Hay que copiar y editar ficheros manualmente. Sin historial, sin rollback |
| Script bash con `sed` | Frágil, difícil de mantener, sin control de versiones |
| **Helm chart** | `helm install/upgrade/uninstall` con un solo comando. Historial completo, rollback a revisión anterior, valores parametrizados |

Con Helm, crear un cliente nuevo es tan simple como:

```bash
helm install cliente-acme ~/saas-hosting/helm/client-chart \
  --set client.name=acme \
  --set client.domain=acme.meu-project.me
```

Y eliminarlo:

```bash
helm uninstall cliente-acme
```

---

## Decisiones de diseño

| Decisión | Justificación |
|----------|---------------|
| **Helm chart propio** | `helm install/upgrade/uninstall` por cliente, historial de revisiones y rollback |
| **Namespace por cliente** | Aislamiento total de recursos: un cliente no puede ver ni afectar a otro. Permite aplicar cuotas de CPU/RAM por cliente |
| **IngressClass: nginx** | Usa el ingress-nginx desplegado en `k8s-submaster`, que es el punto de entrada del tráfico externo |
| **ClusterIP para el Service** | El pod nunca es accesible directamente desde fuera. Todo el tráfico pasa por el Ingress, que gestiona SSL y enrutamiento |
| **Resource limits** | Sin limits, un pod descontrolado puede consumir toda la CPU/RAM del nodo y afectar a todos los clientes |
| **cert-manager annotation** | El Ingress solicita automáticamente certificado TLS de Let's Encrypt al crearse |

---

## Arquitectura de un cliente desplegado

```text
Internet
   ↓ HTTPS :443
[Ingress Controller — k8s-submaster]
   ↓ HTTP :80 (internamente)
[Service: acme-service — ClusterIP]   ← solo accesible dentro del cluster
   ↓ :8080
[Pod: acme-deployment]
  └─ Nginx :8080    ← sirve ficheros estáticos
  └─ PHP-FPM :9000  ← ejecuta PHP
  └─ /var/www/html/ ← ficheros del cliente
```

### Flujo real del tráfico

1. El usuario entra en `https://acme.meu-project.me`.
2. El DNS apunta al Ingress Controller del clúster.
3. El Ingress Controller recibe la petición y mira el `Host`.
4. Si el host coincide con `acme.meu-project.me`, reenvía el tráfico al Service `acme-service`.
5. El Service envía la petición al pod `acme-deployment`.
6. Dentro del pod, Nginx sirve estáticos o pasa PHP a PHP-FPM.

---

## Estructura del chart

```text
~/saas-hosting/helm/client-chart/
├── Chart.yaml          ← metadatos del chart (nombre, versión)
├── values.yaml         ← valores por defecto (se sobreescriben por cliente)
└── templates/
    ├── namespace.yaml  ← crea el namespace aislado del cliente
    ├── deployment.yaml ← define el pod con saas-php:8.3
    ├── service.yaml    ← expone el pod internamente via ClusterIP
    └── ingress.yaml    ← enruta el dominio del cliente al service + TLS
```

Crear la estructura desde el master:

```bash
mkdir -p ~/saas-hosting/helm/client-chart/templates
cd ~/saas-hosting/helm/client-chart
```

---

## `Chart.yaml`

**Para qué sirve:** Fichero de metadatos obligatorio en todo Helm chart. Define el nombre, versión del chart y versión de la aplicación que despliega. Helm lo usa para identificar el chart y mostrarlo en `helm list`.

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

### Qué significa cada campo

| Campo | Significado |
|-------|-------------|
| `apiVersion: v2` | Versión del formato de chart de Helm 3 |
| `name` | Nombre lógico del chart |
| `description` | Texto descriptivo |
| `type: application` | Indica que despliega una aplicación, no una librería |
| `version` | Versión del chart |
| `appVersion` | Versión de la aplicación desplegada |

---

## `values.yaml` — Valores por defecto

**Para qué sirve:** Define los valores por defecto del chart. Cada vez que se instala un cliente nuevo, estos valores se sobreescriben con `--set` o con un fichero `values-cliente.yaml`. Es la fuente de configuración del despliegue.

```bash
cat > values.yaml << 'EOF'
# Identificador único del cliente
# Se sobreescribe en cada helm install con --set client.name=xxx
client:
  name: "default"
  domain: "default.meu-project.me"
  image: "registry.meu-project.me/saas-php:8.3"

# Recursos asignados al pod del cliente
# requests: mínimo garantizado | limits: máximo permitido
resources:
  requests:
    memory: "64Mi"
    cpu: "50m"
  limits:
    memory: "256Mi"
    cpu: "250m"

# Número de réplicas del pod
replicaCount: 1
EOF
```

### Qué controla cada bloque

- `client.name`: nombre corto del cliente, usado en nombres de recursos.
- `client.domain`: dominio final del cliente.
- `client.image`: imagen Docker que se desplegará.
- `resources.requests`: recursos mínimos garantizados por Kubernetes.
- `resources.limits`: techo máximo permitido.
- `replicaCount`: número de pods de ese cliente.

---

## `templates/namespace.yaml`

**Para qué sirve:** Crea un namespace Kubernetes exclusivo para el cliente. El namespace actúa como una caja aislada. Todos los recursos del cliente viven dentro y no interfieren con otros clientes.

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

### Por qué es importante el namespace

- Aísla Deployment, Service, Ingress, Secrets y futuros PVC.
- Permite borrar un cliente completo eliminando su namespace.
- Facilita aplicar cuotas o políticas por cliente.
- Ayuda a listar recursos por cliente sin mezclar nada.

> La label `managed-by: saas-api` permite listar todos los namespaces gestionados automáticamente con `kubectl get ns -l managed-by=saas-api`.

---

## `templates/deployment.yaml`

**Para qué sirve:** Define el pod del cliente. Kubernetes usa este manifiesto para arrancar y mantener el contenedor `saas-php:8.3`. Si el pod muere, el Deployment lo vuelve a crear automáticamente.

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

### Qué hace cada parte

| Sección | Función |
|---------|---------|
| `replicas` | Número de pods deseados |
| `selector.matchLabels` | Cómo encuentra el Deployment sus pods |
| `template.metadata.labels` | Etiquetas reales del pod |
| `containers.image` | Imagen Docker a arrancar |
| `containerPort: 8080` | Puerto expuesto por Nginx en el contenedor |
| `resources` | CPU y RAM reservadas/máximas |

> El `containerPort: 8080` tiene que coincidir con el puerto que expone la imagen `saas-php:8.3`. Si se cambia el Dockerfile, hay que cambiar también este valor.

---

## `templates/service.yaml`

**Para qué sirve:** Crea un punto de acceso interno estable al pod del cliente. Los pods tienen IP dinámica, pero el Service mantiene un punto fijo dentro del clúster. El Ingress no apunta al pod, apunta al Service.

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

### Traducción práctica

- El Service escucha en el puerto **80** dentro del cluster.
- Reenvía el tráfico al puerto **8080** del contenedor.
- Si el pod se recrea con otra IP, el Service sigue funcionando igual.

### Por qué `ClusterIP`

Usamos `ClusterIP` porque:
- el cliente no debe exponerse directamente a internet,
- el único punto de entrada debe ser el Ingress,
- centraliza TLS, hostnames y routing en una sola capa.

---

## `templates/ingress.yaml`

**Para qué sirve:** Define las reglas de enrutamiento del tráfico externo. Cuando llega una petición para `acme.meu-project.me`, el Ingress Controller la recibe, valida el host y la envía al Service correcto.

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

### Qué hace cada bloque

| Bloque | Función |
|--------|---------|
| `annotations.cert-manager.io/cluster-issuer` | Pide certificado TLS automático |
| `ingressClassName: nginx` | Indica qué controlador procesa este Ingress |
| `tls.hosts` | Dominios cubiertos por el certificado |
| `secretName` | Secret donde cert-manager guarda certificado y clave |
| `rules.host` | Dominio que dispara esta regla |
| `backend.service.name` | Service destino |
| `backend.service.port.number` | Puerto del Service destino |

> El `secretName` debe existir en el mismo namespace. cert-manager lo crea automáticamente cuando emite el certificado.

---

## Uso

### Instalar un cliente nuevo

```bash
helm install cliente-acme ~/saas-hosting/helm/client-chart \
  --set client.name=acme \
  --set client.domain=acme.meu-project.me \
  --set client.image=registry.meu-project.me/saas-php:8.3
```

Este comando hace lo siguiente:

1. Crea el namespace `client-acme`.
2. Crea el Deployment `acme-deployment`.
3. Arranca el pod con la imagen indicada.
4. Crea el Service `acme-service`.
5. Crea el Ingress `acme-ingress`.
6. cert-manager detecta el Ingress y solicita el certificado TLS.

### Actualizar un cliente existente

```bash
helm upgrade cliente-acme ~/saas-hosting/helm/client-chart \
  --set client.name=acme \
  --set client.domain=acme.meu-project.me
```

### Ver historial de revisiones

```bash
helm history cliente-acme
```

### Hacer rollback

```bash
helm rollback cliente-acme 1
```

### Eliminar un cliente

```bash
helm uninstall cliente-acme
kubectl delete namespace client-acme
```

> `helm uninstall` elimina los recursos del release, pero es buena práctica borrar también el namespace para limpiar Secrets, certificados y futuros volúmenes.

---

## Verificación

```bash
# Ver releases instalados
helm list -A

# Ver todos los recursos del cliente
kubectl get all -n client-acme

# Ver Ingress
kubectl get ingress -n client-acme

# Ver certificado emitido
kubectl get certificate -n client-acme

# Ver logs del pod
kubectl logs -n client-acme deployment/acme-deployment
```

### Qué deberías ver

- `helm list -A`: release `cliente-acme` en estado `deployed`
- `kubectl get all -n client-acme`: Deployment, ReplicaSet, Pod y Service
- `kubectl get ingress -n client-acme`: host `acme.meu-project.me`
- `kubectl get certificate -n client-acme`: certificado en estado `Ready=True`

---

## Diagrama de flujo

```text
API recibe POST /clients {name: "acme", domain: "acme.meu-project.me"}
   ↓
helm install client-chart --set client.name=acme --set client.domain=...
   ↓
Kubernetes crea:
  ├── Namespace: client-acme
  ├── Deployment: acme-deployment  → Pod con saas-php:8.3
  ├── Service: acme-service        → ClusterIP :80 → pod :8080
  └── Ingress: acme-ingress        → acme.meu-project.me → acme-service
           ↓
      cert-manager detecta el nuevo Ingress
           ↓
      Solicita certificado a Let's Encrypt
           ↓
      Guarda cert en Secret: acme-tls
           ↓
      HTTPS activo en acme.meu-project.me
```