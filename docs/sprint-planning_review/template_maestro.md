# 📦 Creación YAML Template Maestro

## 1. Contexto y justificación

En un entorno SaaS multi-tenant donde cada cliente tiene su propia aplicación desplegada en el clúster, escribir YAMLs de Kubernetes de forma manual para cada app es inviable. Un solo despliegue típico requiere al menos 4 recursos independientes: `Deployment`, `Service`, `Ingress` y `PersistentVolumeClaim`. Si tenemos 10 clientes, son 40 ficheros YAML a mantener manualmente, con el riesgo de inconsistencias, errores tipográficos y deuda técnica acumulada.

La solución es crear un **Helm chart maestro** — una plantilla parametrizada donde toda la lógica de infraestructura está escrita una sola vez, y cada app solo necesita un fichero `values.yaml` con sus valores específicos (nombre, imagen, dominio, BBDD, etc.). Helm se encarga de renderizar los templates y aplicarlos al clúster.

### ¿Por qué Helm y no Kustomize u otras alternativas?

| Herramienta | Ventaja | Inconveniente |
|---|---|---|
| **Helm** | Ecosistema maduro, versionado de releases, rollback nativo | Curva de aprendizaje de Go templates |
| **Kustomize** | Nativo en kubectl, sin dependencias | Menos potente para lógica condicional |
| **Jsonnet** | Muy flexible | Requiere aprender un lenguaje nuevo |

Elegimos Helm porque ya está instalado en el clúster, tiene soporte nativo de rollback (`helm rollback`), y permite empaquetar el chart como artefacto versionado para distribuirlo.

---

## 2. Arquitectura del chart

### Diagrama de recursos generados

```
values.yaml
     │
     ▼
Helm Template Engine
     │
     ├──▶ Deployment       → Gestiona el ciclo de vida del pod (imagen, env vars, recursos)
     ├──▶ Service          → Expone el pod internamente en el clúster (ClusterIP)
     ├──▶ Ingress          → Enruta tráfico externo HTTP/HTTPS al Service
     └──▶ PersistentVolumeClaim × N  → Almacenamiento persistente (código PHP, logs)
```

### Flujo de una petición web

```
Internet → DNS (meu-project.me → 54.163.235.144)
         → AWS Security Group (puerto 80/443)
         → Nginx Ingress Controller (NodePort)
         → Service ClusterIP (puerto 80)
         → Pod (nginx + php-fpm, puerto 8080)
         → Lee código PHP del PVC (meu-html-pvc)
         → Responde con HTML
```

### Estructura de ficheros

```
~/saas-hosting/helm/saas-app/
├── Chart.yaml               → Metadatos del chart: nombre, versión, descripción
├── values.yaml              → Valores por defecto (sobreescribibles por app)
└── templates/
    ├── deployment.yaml      → Pod con imagen, env vars, recursos y volúmenes
    ├── service.yaml         → ClusterIP que conecta Ingress con el Pod
    ├── ingress.yaml         → Reglas de routing HTTP/HTTPS + TLS automático via cert-manager
    └── pvc.yaml             → Volúmenes persistentes definidos dinámicamente
```

---

## 3. Ficheros del chart

### 3.1 `Chart.yaml` — Metadatos

```yaml
apiVersion: v2
name: saas-app
description: Plantilla maestra para despliegue de apps SaaS en Kubernetes
type: application
version: 1.0.0
appVersion: "1.0.0"
```

**Campos relevantes:**
- `apiVersion: v2` → formato Helm 3, obligatorio para charts modernos
- `type: application` → chart que genera recursos en el clúster (alternativa: `library`, solo para templates reutilizables)
- `version` → versión del chart en sí (infraestructura)
- `appVersion` → versión de la aplicación que despliega (informativo)

---

### 3.2 `values.yaml` — Parámetros configurables

Este es el fichero más importante. Define todos los valores por defecto que los templates usarán. Cada app que se despliegue con este chart sobreescribirá los valores que necesite.

```yaml
# ─── Identificación ───────────────────────────────────────────────────────────
# Nombre base que se usará en todos los recursos: deployment, svc, ingress, pvc
app:
  name: meu

# ─── Imagen ───────────────────────────────────────────────────────────────────
# IMPORTANTE: el repository debe incluir siempre el prefijo del registry interno.
# Sin prefijo, Kubernetes busca la imagen en Docker Hub y falla con ImagePullBackOff.
image:
  repository: 10.97.214.208:5000/saas-php   # ClusterIP del registry interno
  tag: "8.3"
  pullPolicy: IfNotPresent                   # No re-descarga si la imagen ya existe en el nodo

# ─── Replicas ─────────────────────────────────────────────────────────────────
replicaCount: 1

# ─── Recursos ─────────────────────────────────────────────────────────────────
# requests: mínimo garantizado al pod
# limits: máximo que puede consumir antes de ser killed (OOMKilled)
resources:
  requests:
    cpu: 100m        # 0.1 vCPU
    memory: 128Mi
  limits:
    cpu: 500m        # 0.5 vCPU
    memory: 256Mi

# ─── Variables de entorno (no sensibles) ──────────────────────────────────────
# Se inyectan directamente en el contenedor como variables de entorno.
# El código PHP las lee con getenv('DB_HOST'), $_ENV['DB_HOST'], etc.
env:
  DB_HOST: "10.2.2.154"    # IP privada de la instancia RDS/MySQL
  DB_PORT: "3306"
  DB_NAME: "meu_project"

# ─── Secrets (credenciales sensibles) ─────────────────────────────────────────
# Las credenciales NUNCA van en texto plano en el values.yaml.
# Se almacenan en un Kubernetes Secret y se referencian por nombre.
# Crear el secret manualmente antes del helm install:
#   kubectl create secret generic meu-db-secret \\
#     --from-literal=DB_USER=usuario \\
#     --from-literal=DB_PASSWORD=contraseña
envSecret:
  secretName: "meu-db-secret"
  keys:
    - DB_USER
    - DB_PASSWORD

# ─── Service ──────────────────────────────────────────────────────────────────
# ClusterIP: solo accesible dentro del clúster (el Ingress lo enruta)
# port: puerto que expone el Service (el que usa el Ingress)
# targetPort: puerto real donde escucha la app dentro del contenedor
service:
  type: ClusterIP
  port: 80
  targetPort: 8080    # nginx dentro del contenedor escucha en 8080

# ─── Ingress ──────────────────────────────────────────────────────────────────
# Gestiona el routing externo HTTP/HTTPS.
# cert-manager genera automáticamente el certificado TLS de Let's Encrypt
# cuando detecta la anotación cert-manager.io/cluster-issuer en el Ingress.
ingress:
  enabled: true
  className: nginx
  host: meu-project.me
  wwwHost: www.meu-project.me
  tls: true
  tlsSecret: meu-project-tls    # Nombre del Secret donde cert-manager guardará el certificado

# ─── Persistencia ─────────────────────────────────────────────────────────────
# Cada item genera un PVC independiente.
# storageClass: local-path usa el disco local del nodo worker (Rancher local-path-provisioner)
# IMPORTANTE: ReadWriteOnce significa que solo un pod puede montar el volumen a la vez.
# Para múltiples réplicas se necesitaría ReadWriteMany (NFS, EFS, etc.)
persistence:
  enabled: true
  storageClass: local-path
  items:
    - name: html          # Se monta en /var/www/html — aquí va el código PHP
      size: 2Gi
      mountPath: /var/www/html
    - name: logs          # Se monta en /var/log/nginx — logs de acceso y error
      size: 1Gi
      mountPath: /var/log/nginx
```

---

### 3.3 `templates/deployment.yaml` — El corazón del chart

El Deployment gestiona el ciclo de vida de los pods: cuántos hay, qué imagen usan, qué variables de entorno inyectan, qué volúmenes montan y qué recursos consumen.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.app.name }}
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Values.app.name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.app.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.app.name }}
    spec:
      containers:
        - name: {{ .Values.app.name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.targetPort }}

          # Variables de entorno no sensibles — se leen directamente de values.yaml
          env:
            {{- range $key, $val := .Values.env }}
            - name: {{ $key }}
              value: {{ $val | quote }}
            {{- end }}

            # Variables sensibles — se leen del Kubernetes Secret (nunca en texto plano)
            {{- range .Values.envSecret.keys }}
            - name: {{ . }}
              valueFrom:
                secretKeyRef:
                  name: {{ $.Values.envSecret.secretName }}
                  key: {{ . }}
            {{- end }}

          # Límites de CPU y memoria — evitan que un pod monopolice el nodo
          resources:
            {{- toYaml .Values.resources | nindent 12 }}

          # Montaje de volúmenes persistentes dentro del contenedor
          {{- if .Values.persistence.enabled }}
          volumeMounts:
            {{- range .Values.persistence.items }}
            - name: {{ .name }}
              mountPath: {{ .mountPath }}
            {{- end }}
          {{- end }}

      # Definición de los volúmenes — referencian los PVCs creados por pvc.yaml
      {{- if .Values.persistence.enabled }}
      volumes:
        {{- range .Values.persistence.items }}
        - name: {{ .name }}
          persistentVolumeClaim:
            claimName: {{ $.Values.app.name }}-{{ .name }}-pvc
        {{- end }}
      {{- end }}
```

**Notas importantes sobre el template:**
- `{{ .Release.Namespace }}` — Helm inyecta el namespace del release automáticamente, no hay que hardcodearlo
- `{{- range $key, $val := .Values.env }}` — itera sobre el mapa de variables de entorno y genera una entrada por cada clave
- `{{- toYaml .Values.resources | nindent 12 }}` — convierte el objeto `resources` a YAML con indentación correcta
- `$.Values` (con `$`) dentro de un `range` — necesario para acceder al contexto raíz cuando estás dentro de un bucle

---

### 3.4 `templates/service.yaml` — Exposición interna

El Service actúa como balanceador de carga interno. El Ingress no habla directamente con los pods, sino con el Service, que enruta al pod correcto según el selector `app: {{ .Values.app.name }}`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.app.name }}-svc
  namespace: {{ .Release.Namespace }}
  labels:
    app: {{ .Values.app.name }}
spec:
  type: {{ .Values.service.type }}    # ClusterIP: solo accesible dentro del clúster
  selector:
    app: {{ .Values.app.name }}       # Conecta con los pods que tengan este label
  ports:
    - protocol: TCP
      port: {{ .Values.service.port }}          # Puerto que expone el Service (80)
      targetPort: {{ .Values.service.targetPort }}  # Puerto real del contenedor (8080)
```

**¿Por qué el Service escucha en 80 pero el contenedor en 8080?**  
Por convención y seguridad, los contenedores no deben ejecutarse como root ni escuchar en puertos privilegiados (< 1024). El nginx dentro del contenedor escucha en 8080, y el Service traduce las peticiones del puerto 80 al 8080 de forma transparente.

---

### 3.5 `templates/ingress.yaml` — Routing externo y TLS

El Ingress es el punto de entrada del tráfico externo. El Nginx Ingress Controller lo lee y configura nginx para enrutar peticiones a los Services correctos según el hostname.

La anotación `cert-manager.io/cluster-issuer` hace que cert-manager detecte el Ingress automáticamente y solicite un certificado TLS a Let's Encrypt para los dominios especificados en `spec.tls`.

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Values.app.name }}-ingress
  namespace: {{ .Release.Namespace }}
  annotations:
    # cert-manager detecta esta anotación y solicita el certificado automáticamente
    cert-manager.io/cluster-issuer: "letsencrypt-production"
    # Redirige HTTP → HTTPS automáticamente
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    # No fuerza SSL en la primera petición (evita bucles con HSTS)
    nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
spec:
  ingressClassName: {{ .Values.ingress.className }}    # nginx
  tls:
    - hosts:
        - {{ .Values.ingress.host }}        # meu-project.me
        - {{ .Values.ingress.wwwHost }}     # www.meu-project.me
      secretName: {{ .Values.ingress.tlsSecret }}   # donde cert-manager guardará el certificado
  rules:
    # Regla para el dominio raíz
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Values.app.name }}-svc
                port:
                  number: {{ .Values.service.port }}
    # Regla para www — mismo backend, dominio diferente
    - host: {{ .Values.ingress.wwwHost }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Values.app.name }}-svc
                port:
                  number: {{ .Values.service.port }}
{{- end }}
```

---

### 3.6 `templates/pvc.yaml` — Almacenamiento persistente

Los PersistentVolumeClaims son las "reservas de disco" del pod. Sin PVCs, cualquier fichero escrito dentro del contenedor se pierde al reiniciarse. El chart genera un PVC por cada item definido en `persistence.items`.

```yaml
{{- if .Values.persistence.enabled }}
{{- range .Values.persistence.items }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $.Values.app.name }}-{{ .name }}-pvc    # ej: meu-html-pvc, meu-logs-pvc
  namespace: {{ $.Release.Namespace }}
spec:
  accessModes:
    - ReadWriteOnce    # Un solo pod puede montar el volumen. Para múltiples réplicas usar RWX.
  storageClassName: {{ $.Values.persistence.storageClass }}    # local-path
  resources:
    requests:
      storage: {{ .size }}
---
{{- end }}
{{- end }}
```

**¿Qué es `local-path`?**  
Es el StorageClass de Rancher Local Path Provisioner. Cuando se crea un PVC con esta clase, el provisioner crea automáticamente un directorio en el disco local del nodo worker (`/var/lib/rancher/local-path-provisioner/`) y lo monta en el pod. Es rápido y simple, pero tiene la limitación de que el volumen está atado al nodo — si el pod se mueve a otro nodo, no puede acceder a sus datos.

---

## 4. Comandos de uso

### Primer despliegue de una app

```bash
# 1. Crear el secret con las credenciales de BBDD ANTES del helm install
kubectl create secret generic meu-db-secret \\
  --from-literal=DB_USER=usuario_real \\
  --from-literal=DB_PASSWORD=contraseña_real \\
  -n default

# 2. Instalar el chart
helm install meu-project ~/saas-hosting/helm/saas-app -n default

# 3. Verificar que todo ha levantado
kubectl get pods,svc,ingress,pvc -n default
```

### Actualizar tras cambios en `values.yaml`

```bash
helm upgrade meu-project ~/saas-hosting/helm/saas-app -n default

# Ver diferencias antes de aplicar (requiere plugin helm-diff)
helm diff upgrade meu-project ~/saas-hosting/helm/saas-app -n default
```

### Hacer rollback a la versión anterior

```bash
# Ver historial de releases
helm history meu-project -n default

# Rollback a la revisión anterior
helm rollback meu-project -n default

# Rollback a una revisión específica
helm rollback meu-project 2 -n default
```

### Desplegar una segunda app con el mismo chart

```bash
# Crear un values.yaml específico para la nueva app
cat > ~/saas-hosting/helm/cliente2-values.yaml << 'EOF'
app:
  name: cliente2

image:
  repository: 10.97.214.208:5000/cliente2-php
  tag: "1.0"

env:
  DB_HOST: "10.2.2.154"
  DB_NAME: "cliente2_db"

envSecret:
  secretName: "cliente2-db-secret"

ingress:
  host: cliente2.meu-project.me
  wwwHost: www.cliente2.meu-project.me
  tlsSecret: cliente2-tls
EOF

helm install cliente2 ~/saas-hosting/helm/saas-app \\
  -n default \\
  -f ~/saas-hosting/helm/cliente2-values.yaml
```

### Eliminar una app

```bash
helm uninstall meu-project -n default
# IMPORTANTE: los PVCs NO se eliminan automáticamente para evitar pérdida de datos.
# Eliminarlos manualmente si ya no se necesitan:
kubectl delete pvc meu-html-pvc meu-logs-pvc -n default
```

---

## 5. Copiar código PHP al PVC

El PVC `meu-html-pvc` se crea vacío. El código PHP debe copiarse manualmente la primera vez. El procedimiento es lanzar un pod temporal que monte el PVC y usar `kubectl cp` para transferir los ficheros:

```bash
# 1. Lanzar pod auxiliar con el PVC montado
kubectl run copy-helper --image=busybox --restart=Never \\
  --overrides='{
    "spec":{
      "volumes":[{"name":"html","persistentVolumeClaim":{"claimName":"meu-html-pvc"}}],
      "containers":[{
        "name":"copy-helper",
        "image":"busybox",
        "command":["sleep","3600"],
        "volumeMounts":[{"name":"html","mountPath":"/html"}]
      }]
    }
  }'

# 2. Esperar que el pod esté listo
kubectl wait pod/copy-helper --for=condition=Ready --timeout=30s

# 3. Copiar el código
kubectl cp ~/saas-hosting/src/. copy-helper:/html/

# 4. Verificar
kubectl exec copy-helper -- ls -la /html

# 5. Limpiar
kubectl delete pod copy-helper
```

---

## 6. Registry interno

Todas las imágenes custom del proyecto se almacenan en el registry privado desplegado dentro del clúster. El procedimiento de build y push desde el nodo master es:

```bash
# 1. Abrir túnel al registry (el DNS .cluster.local no resuelve fuera de pods)
kubectl port-forward -n registry svc/registry-svc 5000:5000 &

# 2. Configurar Docker para aceptar el registry HTTP
echo '{"insecure-registries":["localhost:5000","10.97.214.208:5000"]}' \\
  | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker

# 3. Build de la imagen
docker build -t localhost:5000/saas-php:8.3 ~/saas-hosting/docker/base/

# 4. Push al registry interno
docker push localhost:5000/saas-php:8.3

# 5. Verificar que la imagen está disponible
curl http://localhost:5000/v2/_catalog
# Respuesta esperada: {"repositories":["saas-php"]}
```

---

## 7. Problemas encontrados durante la implementación

### ❌ Problema 1 — `ImagePullBackOff`: imagen buscada en Docker Hub

**Descripción:**  
Al aplicar el chart por primera vez, el pod quedaba en estado `ImagePullBackOff`. El evento del pod mostraba:
```
Failed to pull image "docker.io/library/saas-php:8.3": pull access denied
```
Kubernetes interpretaba `saas-php` como una imagen pública de Docker Hub porque no tenía prefijo de registry.

**Causa raíz:**  
El campo `repository` en `values.yaml` estaba configurado como `saas-php` sin indicar el registry interno. Kubernetes usa `docker.io/library/` como registry por defecto cuando no se especifica ninguno.

**Solución:**  
Cambiar `repository: saas-php` por `repository: 10.97.214.208:5000/saas-php` en `values.yaml`, usando la ClusterIP del registry interno.

---

### ❌ Problema 2 — `docker push` falla desde el nodo master

**Descripción:**  
Al intentar hacer push de la imagen al registry usando el nombre DNS del Service:
```bash
docker push registry-svc.registry.svc.cluster.local:5000/saas-php:8.3
```
El comando fallaba con:
```
dial tcp: lookup registry-svc.registry.svc.cluster.local on 127.0.0.53:53: server misbehaving
```

**Causa raíz:**  
El DNS `*.svc.cluster.local` es gestionado por CoreDNS, que solo está disponible dentro de los pods del clúster. El sistema operativo del nodo master usa el DNS del sistema (`127.0.0.53`), que no conoce los dominios internos de Kubernetes.

**Solución:**  
Usar `kubectl port-forward` para tunelizar el puerto 5000 del registry al `localhost` del master. Así Docker habla con `localhost:5000` (que el OS sí resuelve) y el port-forward redirige el tráfico al pod del registry dentro del clúster.

```bash
kubectl port-forward -n registry svc/registry-svc 5000:5000
docker push localhost:5000/saas-php:8.3
```

---

### ❌ Problema 3 — containerd rechaza el registry HTTP en los workers

**Descripción:**  
Aunque el push desde el master funcionó, los pods en el worker seguían en `ErrImagePull`. El error era:
```
http: server gave HTTP response to HTTPS client
```
containerd intentaba conectarse al registry por HTTPS (el protocolo por defecto), pero el registry no tiene TLS configurado.

**Causa raíz:**  
containerd requiere configuración explícita para aceptar registries HTTP (inseguros). Esta configuración se hace mediante un fichero `hosts.toml` en `/etc/containerd/certs.d/<registry>/` y requiere que `config_path` en `/etc/containerd/config.toml` apunte a ese directorio. En la instalación base, `config_path` estaba vacío (`''`).

**Solución:**  
Desplegar un DaemonSet que en cada nodo (incluyendo futuros workers) ejecute un `initContainer` que:
1. Cree el fichero `hosts.toml` con la configuración del registry HTTP
2. Modifique `config.toml` para rellenar el `config_path`

```bash
# El DaemonSet se aplica una vez y funciona para siempre, incluso en nuevos nodos
kubectl apply -f ~/saas-hosting/registry/registry-config-daemonset.yaml

# Reinicio manual de containerd en workers ya existentes (única vez)
ssh ubuntu@10.1.2.96 "sudo systemctl restart containerd"
```

> **Nota:** Se intentó usar `nsenter` para reiniciar containerd desde el DaemonSet, pero `busybox` no incluye el binario `systemctl` en su PATH. La solución fue eliminar el reinicio automático del DaemonSet, ya que containerd lee el `hosts.toml` dinámicamente en cada pull sin necesidad de reinicio.

---

### ❌ Problema 4 — 403 Forbidden: PVC vacío

**Descripción:**  
Con el pod en estado `Running`, la web devolvía `403 Forbidden`. nginx estaba operativo pero no tenía ficheros que servir.

**Causa raíz:**  
El PVC `meu-html-pvc` se crea vacío por diseño — Kubernetes no pre-rellena los volúmenes con contenido. El código PHP de la aplicación no estaba en el servidor ni en ningún repositorio Git, por lo que se perdió.

**Solución temporal:**  
Crear un `index.php` de placeholder para verificar que el stack completo funciona end-to-end (nginx → php-fpm → PVC):

```php
<?php echo "<h1>meu-project funcionando</h1>"; ?>
```

**Lección aprendida:**  
Todo el código fuente debe estar versionado en Git desde el primer día. Un PVC con `local-path` es un único punto de fallo — si el nodo worker muere o el PVC se borra accidentalmente, el código se pierde de forma permanente sin posibilidad de recuperación.

**Acción pendiente:**  
- Crear repositorio Git para el código de la aplicación
- Implementar proceso de CI/CD que haga el `kubectl cp` automáticamente en cada push a main

---

### ❌ Problema 5 — `pma.meu-project.me` inaccesible: TLS inválido + whitelist + DNS

**Descripción:**  
Al acceder a `pma.meu-project.me`, Chrome bloqueaba la conexión con `NET::ERR_CERT_AUTHORITY_INVALID` y además mencionaba HSTS, impidiendo incluso aceptar manualmente el certificado inválido.

**Causas raíz (múltiples):**

1. **Sin TLS en el Ingress de phpMyAdmin:** el Ingress solo tenía reglas HTTP, sin bloque `spec.tls` ni anotación de cert-manager. Chrome aplicaba HSTS heredado del dominio principal `meu-project.me` y forzaba HTTPS, encontrando un certificado fake de nginx.

2. **IP whitelist activa:** el Ingress tenía la anotación `nginx.ingress.kubernetes.io/whitelist-source-range: 54.163.235.144/32`, que solo permitía acceso desde la IP pública del master (la misma IP del servidor). Cualquier otra IP recibía `403 Forbidden`.

3. **A Record DNS inexistente:** el subdominio `pma.meu-project.me` no tenía registro DNS, por lo que no resolvía a ninguna IP.

**Solución:**

```bash
# 1. Añadir TLS y cert-manager al Ingress de phpMyAdmin
kubectl patch ingress phpmyadmin-ingress --type=json -p='[
  {"op":"add","path":"/spec/tls","value":[{"hosts":["pma.meu-project.me"],"secretName":"pma-project-tls"}]},
  {"op":"add","path":"/metadata/annotations/cert-manager.io~1cluster-issuer","value":"letsencrypt-production"}
]'

# 2. Eliminar el whitelist de IP
kubectl annotate ingress phpmyadmin-ingress \\
  nginx.ingress.kubernetes.io/whitelist-source-range-
```

```
# 3. A Record añadido en el proveedor DNS
Type: A Record | Host: pma | IP: 54.163.235.144 | TTL: Automatic
```

cert-manager emitió el certificado de Let's Encrypt para `pma.meu-project.me` en menos de 60 segundos.
