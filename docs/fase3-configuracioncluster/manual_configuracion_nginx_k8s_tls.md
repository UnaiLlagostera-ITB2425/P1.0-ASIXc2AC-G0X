# Manual de Configuración: Proxy NGINX Docker + Kubernetes + Certificado TLS

## 1. Arquitectura General

El stack completo implementa el siguiente flujo de tráfico, desde el usuario final hasta la aplicación desplegada en Kubernetes:

```
Usuario (Internet)
        │
        ▼  Puerto 80 / 443
┌────────────────────────────────────────┐
│  AWS EC2 — IP pública                  │
│  54.163.235.144                        │
│                                        │
│  ┌──────────────────────────────────┐  │
│  │  Docker: nginx-proxy             │  │  ← Termina TLS · Proxy inverso
│  │  Puerto 80  → Redirige a HTTPS   │  │
│  │            → ACME challenge pass │  │
│  │  Puerto 443 → proxy_pass HTTP    │  │
│  └──────────────┬───────────────────┘  │
└─────────────────┼──────────────────────┘
                  │ HTTP interno (red privada AWS)
                  ▼
┌────────────────────────────────────────┐
│  Nodo Worker — 10.1.2.96               │
│                                        │
│  Kubernetes Ingress Controller         │
│  NodePort 30080  → Tráfico aplicación  │
│  NodePort 31967  → ACME challenge      │
└───────────────┬────────────────────────┘
                │
                ▼
┌────────────────────────────────────────┐
│  Kubernetes Service                    │
│  → Pod (Aplicación)                    │
└────────────────────────────────────────┘
```

### Roles de cada nodo

| Nodo | IP Privada | Rol | Componentes |
|------|-----------|-----|-------------|
| k8s-master | 10.0.1.136 | Control Plane | API Server, etcd, scheduler, controller-manager |
| k8s-worker | 10.1.2.96 | Worker | Pods de la aplicación, Ingress Controller |

### Decisión de diseño: ¿Por qué un NGINX Docker externo?

El Docker NGINX actúa como **punto de entrada público** porque:
- El clúster Kubernetes corre en una red privada de AWS sin IP pública directa en los workers.
- Centraliza la terminación TLS en un único punto controlado.
- Permite gestionar el tráfico ACME de cert-manager sin modificar reglas del Ingress en cada renovación.

> 📸 **[CAPTURA SUGERIDA]** Diagrama de red completo de la infraestructura AWS mostrando ambas instancias EC2, sus IPs públicas/privadas y el flujo de tráfico. Puede usarse el fichero `Diagrama-Completo-Red-V1.0.0.jpg` del proyecto.

---

## 2. Proxy Inverso NGINX con Docker

### 2.1 Estructura de directorios

```
~/nginx-docker/
├── docker-compose.yml        ← Definición del servicio Docker
├── conf/
│   └── nginx.conf            ← Configuración del servidor NGINX
└── certs/
    ├── tls.crt               ← Certificado TLS (extraído del Secret de K8s)
    └── tls.key               ← Clave privada TLS (extraída del Secret de K8s)
```

> ⚠️ El directorio `certs/` y sus ficheros deben existir **antes** de arrancar el contenedor.
> Si no existen, NGINX falla con `[emerg] cannot load certificate` y entra en `CrashLoopBackOff`.

### 2.2 docker-compose.yml

```yaml
services:
  nginx-proxy:
    image: nginx:alpine
    container_name: nginx-proxy
    ports:
      - "80:80"       # HTTP público
      - "443:443"     # HTTPS público
    volumes:
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro   # Configuración NGINX
      - ./certs:/etc/nginx/certs:ro                  # Certificados TLS
    networks:
      - nginx-net
    restart: unless-stopped

networks:
  nginx-net:
    driver: bridge
```

**Notas del Compose:**

| Campo | Valor | Descripción |
|-------|-------|-------------|
| `image` | `nginx:alpine` | Imagen oficial NGINX en Alpine Linux (imagen ligera ~25 MB) |
| `ports` | `80:80`, `443:443` | Mapea puertos del host al contenedor |
| `volumes` | `./conf`, `./certs` | Montados en modo `:ro` (solo lectura) por seguridad |
| `restart` | `unless-stopped` | Reinicio automático salvo parada manual explícita |

### 2.3 nginx.conf

```nginx
events {
    worker_connections 1024;
}

http {
    # Logging
    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    # Timeouts y buffers del proxy
    proxy_connect_timeout   60s;
    proxy_send_timeout      60s;
    proxy_read_timeout      60s;
    proxy_buffer_size       4k;
    proxy_buffers           4 32k;
    proxy_busy_buffers_size 64k;

    # ── Bloque HTTP (puerto 80) ──────────────────────────────────────────────
    server {
        listen 80;
        server_name meu-project.me;

        # EXCEPCIÓN: el challenge ACME de cert-manager pasa sin redirigir
        # Apunta al NodePort 31967 del Ingress Controller en el Worker
        location /.well-known/acme-challenge/ {
            proxy_pass http://10.1.2.96:31967;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        }

        # Todo lo demás → redirección permanente a HTTPS
        location / {
            return 301 https://$host$request_uri;
        }
    }

    # ── Bloque HTTPS (puerto 443) ────────────────────────────────────────────
    server {
        listen 443 ssl;
        server_name meu-project.me;

        # Certificado TLS (montado desde ~/nginx-docker/certs/)
        ssl_certificate     /etc/nginx/certs/tls.crt;
        ssl_certificate_key /etc/nginx/certs/tls.key;

        # Protocolo y cifrados seguros
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;

        # Proxy al Ingress Controller del Worker (NodePort 30080)
        location / {
            proxy_pass http://10.1.2.96:30080;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
        }
    }
}
```

**Explicación de los dos bloques:**

| Bloque | Puerto | Comportamiento |
|--------|--------|----------------|
| HTTP | 80 | `/.well-known/acme-challenge/` → proxy al NodePort 31967; resto → `301 HTTPS` |
| HTTPS | 443 | Termina TLS con el certificado Let's Encrypt; proxy al NodePort 30080 |

> ⚠️ La cabecera `X-Forwarded-Proto: https` es crítica: informa a la aplicación y al Ingress que la conexión original era segura, evitando bucles de redirección internos cuando el Ingress tiene `ssl-redirect: true`.

### 2.4 Gestión del contenedor

```bash
# Arrancar en segundo plano
cd ~/nginx-docker
docker compose up -d

# Parar y eliminar el contenedor y la red
docker compose down

# Eliminar contenedores huérfanos de versiones anteriores
docker compose down --remove-orphans
docker rm -f nginx-proxy   # si persiste un contenedor con ese nombre

# Ver el estado y los puertos expuestos
docker ps

# Ver los logs en tiempo real
docker logs nginx-proxy -f

# Ver los últimos 20 logs
docker logs nginx-proxy --tail 20

# Verificar la sintaxis del nginx.conf SIN reiniciar
docker exec nginx-proxy nginx -t

# Recargar la configuración SIN downtime (sin parar el contenedor)
docker exec nginx-proxy nginx -s reload

# Inspeccionar los volúmenes montados (verificar que certs está montado)
docker inspect nginx-proxy | grep -A 10 '"Mounts"'
```

> 📸 **[CAPTURA SUGERIDA]** Output de `docker ps` mostrando el contenedor `nginx-proxy` en estado `Up` con los puertos `0.0.0.0:80->80/tcp` y `0.0.0.0:443->443/tcp` correctamente mapeados.

---

## 3. Clúster Kubernetes con kubeadm

### 3.1 Descripción del clúster

El clúster se despliega con **kubeadm** sobre dos instancias EC2 de AWS con Ubuntu. La topología es la mínima recomendada para entornos de desarrollo/staging:

- **1 nodo Master (Control Plane):** gestiona el estado del clúster a través de la API de Kubernetes.
- **1 nodo Worker:** ejecuta los pods de la aplicación y el Ingress Controller.

### 3.2 Verificación del estado del clúster

```bash
# Estado de todos los nodos — deben estar en Ready
kubectl get nodes -o wide

# Pods del sistema — todos deben estar Running o Completed
kubectl get pods -n kube-system

# Todos los recursos de la aplicación en default
kubectl get all -n default
```

Salida esperada de `kubectl get nodes -o wide`:

```
NAME         STATUS   ROLES           AGE   VERSION   INTERNAL-IP   OS-IMAGE
k8s-master   Ready    control-plane   Xd    v1.x.x    10.0.1.136    Ubuntu 22.04
k8s-worker   Ready    <none>          Xd    v1.x.x    10.1.2.96     Ubuntu 22.04
```

> 📸 **[CAPTURA SUGERIDA]** Output de `kubectl get nodes -o wide` con ambos nodos en estado `Ready`, mostrando sus IPs internas y la versión de Kubernetes instalada.

### 3.3 Recursos de la aplicación

La aplicación se expone mediante tres recursos principales de Kubernetes:

| Recurso | Tipo | Función |
|---------|------|---------|
| `Deployment` | apps/v1 | Gestiona las réplicas de pods de la aplicación |
| `Service` | NodePort | Expone los pods internamente y como NodePort en el Worker |
| `Ingress` | networking.k8s.io/v1 | Enruta el tráfico HTTP/HTTPS al Service correcto según el Host |

```bash
# Ver los Deployments
kubectl get deployments -n default

# Ver los Services y sus NodePorts
kubectl get services -n default

# Ver en qué nodo corre cada pod
kubectl get pods -n default -o wide
```

> 📸 **[CAPTURA SUGERIDA]** Output de `kubectl get services -n default` mostrando el servicio de la aplicación con los NodePorts asignados (30080 para tráfico de app, 31967 para ACME challenge).

---

## 4. Ingress Controller

El **Ingress Controller de NGINX** gestiona el enrutamiento del tráfico HTTP/HTTPS entrante dentro del clúster Kubernetes. Corre como un pod en el nodo Worker y se expone al exterior mediante NodePorts.

### 4.1 Verificación del Ingress Controller

```bash
# Pods del Ingress Controller — deben estar Running
kubectl get pods -n ingress-nginx -o wide

# Service del Ingress — muestra los NodePorts asignados
kubectl get svc -n ingress-nginx

# Logs recientes del Ingress Controller
kubectl logs -n ingress-nginx \
  $(kubectl get pods -n ingress-nginx -o name | head -1) --tail 20
```

Los NodePorts utilizados en este proyecto:

| NodePort | Protocolo | Uso |
|----------|-----------|-----|
| **31967** | HTTP | Recibe el tráfico del challenge ACME de cert-manager |
| **30080** | HTTP | Recibe el tráfico de la aplicación desde el proxy NGINX Docker |

### 4.2 Recurso Ingress de la aplicación

El recurso Ingress define las reglas de enrutamiento y la referencia al certificado TLS:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: meu-project-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - meu-project.me
    secretName: meu-project-tls      # Secret creado por cert-manager
  rules:
  - host: meu-project.me
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: <nombre-del-service>
            port:
              number: 80
```

### 4.3 Anotaciones del Ingress y su impacto

| Anotación | Valor | Descripción |
|-----------|-------|-------------|
| `ssl-redirect` | `"true"` | Redirige HTTP → HTTPS automáticamente dentro del clúster |
| `force-ssl-redirect` | `"false"` | No fuerza la redirección cuando el tráfico ya viene del proxy NGINX con `X-Forwarded-Proto: https` |

### 4.4 Gestión temporal del ssl-redirect durante el challenge

> ⚠️ **Problema conocido:** Con `ssl-redirect: true` activo, el Ingress redirige la petición HTTP-01 de Let's Encrypt (que llega por el puerto 80) a HTTPS antes de que el certificado exista. Esto rompe el proceso de validación y el challenge falla.

**Solución: desactivar temporalmente durante la emisión inicial del certificado:**

```bash
# Paso 1 — Desactivar ssl-redirect ANTES de crear el Certificate
kubectl annotate ingress meu-project-ingress -n default \
  "nginx.ingress.kubernetes.io/ssl-redirect=false" --overwrite
kubectl annotate ingress meu-project-ingress -n default \
  "nginx.ingress.kubernetes.io/force-ssl-redirect=false" --overwrite

# Paso 2 — Esperar a que el certificado esté READY: True
kubectl get certificate -n default -w

# Paso 3 — Reactivar ssl-redirect una vez el certificado está emitido
kubectl annotate ingress meu-project-ingress -n default \
  "nginx.ingress.kubernetes.io/ssl-redirect=true" --overwrite
```

```bash
# Verificar el estado actual del Ingress
kubectl get ingress -n default
kubectl describe ingress meu-project-ingress -n default
```

> 📸 **[CAPTURA SUGERIDA]** Output de `kubectl describe ingress meu-project-ingress` mostrando las anotaciones aplicadas, las reglas de enrutamiento para `meu-project.me` y el TLS configurado con el secret `meu-project-tls`.

---

## 5. Certificado TLS con cert-manager y Let's Encrypt

**cert-manager** es el operador de Kubernetes encargado de automatizar todo el ciclo de vida de los certificados TLS: solicitud, validación del dominio, emisión y renovación automática.

### 5.1 Verificación de cert-manager

```bash
# Pods de cert-manager — todos deben estar Running
kubectl get pods -n cert-manager

# CRDs instalados por cert-manager
kubectl get crds | grep cert-manager.io

# Versión instalada
kubectl -n cert-manager get deployment cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Pods esperados en el namespace `cert-manager`:

| Pod | Función |
|-----|---------|
| `cert-manager-*` | Controlador principal — gestiona el ciclo de vida de los certificados |
| `cert-manager-cainjector-*` | Inyector de CA — inyecta datos de la CA en los webhooks |
| `cert-manager-webhook-*` | Webhook de validación — valida los recursos CRD de cert-manager |

> 📸 **[CAPTURA SUGERIDA]** Output de `kubectl get pods -n cert-manager` con los tres pods en estado `Running 1/1`.

### 5.2 ClusterIssuer — Let's Encrypt Producción

El `ClusterIssuer` define la autoridad certificadora (Let's Encrypt) y el método de validación del dominio. Se usa `ClusterIssuer` (en lugar de `Issuer`) para que sea válido en todos los namespaces del clúster.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    # Servidor ACME de producción de Let's Encrypt
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email para notificaciones de expiración
    email: <tu-email@dominio.com>
    # Secret donde se almacena la clave privada de la cuenta ACME
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    # Método de validación: HTTP-01 (verifica el dominio via HTTP)
    - http01:
        ingress:
          class: nginx
```

```bash
# Aplicar el ClusterIssuer
kubectl apply -f clusterissuer.yaml

# Verificar que está listo (READY debe ser True)
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-prod | grep -A 5 "Conditions"
```

### 5.3 Recurso Certificate

El recurso `Certificate` le indica a cert-manager qué dominio certificar, con qué issuer y en qué Secret guardar el resultado:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: meu-project-tls
  namespace: default
spec:
  secretName: meu-project-tls      # Secret donde se almacenará tls.crt y tls.key
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - meu-project.me
```

```bash
# Aplicar el Certificate
kubectl apply -f certificate.yaml

# Monitorizar el proceso de emisión en tiempo real
kubectl get certificate -n default -w

# Ver todos los recursos relacionados
kubectl get certificate,certificaterequest,order,challenge -n default
```

### 5.4 Flujo completo del challenge HTTP-01

Cuando se crea el recurso `Certificate`, cert-manager ejecuta automáticamente el siguiente proceso:

```
┌─────────────────────────────────────────────────────────────────┐
│                  FLUJO DE EMISIÓN DEL CERTIFICADO               │
│                                                                 │
│  1. Certificate (recurso creado con kubectl apply)             │
│           │                                                     │
│           ▼                                                     │
│  2. CertificateRequest (cert-manager genera CSR)               │
│           │                                                     │
│           ▼                                                     │
│  3. Order (petición ACME a Let's Encrypt)                      │
│           │                                                     │
│           ▼                                                     │
│  4. Challenge HTTP-01                                           │
│     cert-manager despliega un pod temporal que sirve el token  │
│                                                                 │
│     Ruta de verificación:                                       │
│     Let's Encrypt                                               │
│       → GET http://meu-project.me/.well-known/acme-challenge/  │
│       → Docker NGINX (proxy_pass NodePort 31967)               │
│       → Ingress Controller (NodePort 31967)                    │
│       → Pod temporal de cert-manager                           │
│       → Responde con el token de validación ✓                  │
│           │                                                     │
│           ▼                                                     │
│  5. Let's Encrypt valida el token → Certificado emitido        │
│           │                                                     │
│           ▼                                                     │
│  6. Secret "meu-project-tls" creado en Kubernetes             │
│     Contiene: tls.crt y tls.key en base64                      │
└─────────────────────────────────────────────────────────────────┘
```

```bash
# Ver el progreso del challenge
kubectl get challenges -n default
kubectl describe challenge -n default

# Una vez completado (no deben quedar challenges pendientes)
kubectl get challenges -n default
# Resultado esperado: "No resources found in default namespace."

# Verificar el Certificate y el Secret resultante
kubectl get certificate -n default
kubectl get secret meu-project-tls -n default
```

Estado final esperado:
```
NAME              READY   SECRET            AGE
meu-project-tls   True    meu-project-tls   Xm
```

> 📸 **[CAPTURA SUGERIDA]** Output de `kubectl get certificate` con `READY: True` y `kubectl describe certificate meu-project-tls` mostrando las condiciones `Certificate is up to date and has not expired` con las fechas de emisión y expiración.

### 5.5 Renovación automática

Los certificados de Let's Encrypt tienen una **validez de 90 días**. cert-manager los renueva automáticamente cuando quedan **30 días para la expiración**.

```bash
# Ver la fecha de expiración del certificado actual
kubectl get certificate meu-project-tls -n default \
  -o jsonpath='{.status.notAfter}' && echo

# Estado detallado con fechas
kubectl describe certificate meu-project-tls -n default | grep -E "Not After|Renewal|Ready"

# Forzar una renovación manual (si fuera necesario)
kubectl delete certificaterequest -n default \
  $(kubectl get certificaterequest -n default -o name)
```

> ⚠️ **Tarea pendiente de automatización:** Tras cada renovación automática cert-manager actualiza el Secret de Kubernetes, pero los ficheros `tls.crt` y `tls.key` del directorio `~/nginx-docker/certs/` **no se actualizan automáticamente**. Es necesario volver a ejecutar el proceso de extracción (Sección 6) y recargar NGINX. Se recomienda automatizar esto con un CronJob de Kubernetes o un script en el host.

---

## 6. Integración del Certificado en NGINX Docker

Una vez que cert-manager ha emitido el certificado y lo ha guardado en el Secret de Kubernetes (`meu-project-tls`), hay que extraerlo y proporcionárselo al contenedor NGINX Docker.

### 6.1 Extracción del certificado del Secret de Kubernetes

```bash
# Crear el directorio de certificados (si no existe)
mkdir -p ~/nginx-docker/certs

# Extraer el certificado público (tls.crt)
kubectl get secret meu-project-tls -n default \
  -o jsonpath='{.data.tls\.crt}' | base64 --decode > ~/nginx-docker/certs/tls.crt

# Extraer la clave privada (tls.key)
kubectl get secret meu-project-tls -n default \
  -o jsonpath='{.data.tls\.key}' | base64 --decode > ~/nginx-docker/certs/tls.key

# Verificar que los ficheros se crearon con contenido
ls -la ~/nginx-docker/certs/
```

> ⚠️ Usar siempre `base64 --decode` (flag larga). La flag corta `base64 -d` en algunas versiones de Ubuntu puede procesar incorrectamente los saltos de línea y generar ficheros corruptos que NGINX no puede cargar.

### 6.2 Verificación de integridad del certificado

Antes de reiniciar el contenedor, verificar que los ficheros son válidos y que certificado y clave hacen pareja:

```bash
# Ver los detalles del certificado (dominio y fechas de validez)
openssl x509 -in ~/nginx-docker/certs/tls.crt -noout -subject -issuer -dates

# Verificar que cert y key son una pareja válida
# ⚠️ Los dos hashes md5sum DEBEN SER IDÉNTICOS
openssl x509 -noout -modulus -in ~/nginx-docker/certs/tls.crt | md5sum
openssl rsa  -noout -modulus -in ~/nginx-docker/certs/tls.key | md5sum
```

Salida esperada:
```
subject=CN=meu-project.me
issuer=C=US, O=Let's Encrypt, CN=R12
notBefore=Apr 21 16:29:52 2026 GMT
notAfter =Jul 20 16:29:51 2026 GMT

6b09d94b54346aaed31bbaf7dfe8cde5  -   ← hash del certificado
6b09d94b54346aaed31bbaf7dfe8cde5  -   ← hash de la clave (deben ser iguales ✓)
```

Si los hashes son distintos, la extracción falló y hay que repetir el paso 6.1.

> 📸 **[CAPTURA SUGERIDA]** Output del `openssl x509` mostrando `CN=meu-project.me`, el emisor `Let's Encrypt` y las fechas de validez, junto con los dos `md5sum` idénticos.

### 6.3 Arranque del contenedor con los certificados

```bash
cd ~/nginx-docker

# Primera vez o tras cambiar el docker-compose.yml: arranque completo
docker compose down --remove-orphans && docker compose up -d

# Solo recarga de configuración (sin cambiar certs): sin downtime
docker exec nginx-proxy nginx -s reload

# Verificar que arrancó sin errores
# Los logs NO deben contener [emerg] ni [crit]
docker logs nginx-proxy --tail 10

# Confirmar que escucha en los dos puertos
docker ps
```

Logs esperados tras un arranque limpio:
```
/docker-entrypoint.sh: Configuration complete; ready for start up
```

---

## 7. Verificación End-to-End

### 7.1 Comprobaciones del stack completo

```bash
# ── HTTP debe redirigir a HTTPS ───────────────────────────────────────────
curl -s -o /dev/null -w "HTTP status: %{http_code}\n" http://meu-project.me/
# Esperado: HTTP status: 301

# ── HTTPS debe responder con 200 ─────────────────────────────────────────
curl -s -o /dev/null -w "HTTPS status: %{http_code}\n" https://meu-project.me/
# Esperado: HTTPS status: 200

# ── Detalles del certificado SSL en producción ────────────────────────────
echo | openssl s_client -connect meu-project.me:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# ── Prueba verbose completa (muestra handshake TLS y headers HTTP) ────────
curl -v https://meu-project.me/ 2>&1 | grep -E "subject|issuer|< HTTP|SSL connection"
```

### 7.2 Estado esperado de todos los componentes

| Componente | Comando de verificación | Estado esperado |
|------------|------------------------|-----------------|
| Docker NGINX | `docker ps` | `Up`, puertos `0.0.0.0:80->80` y `0.0.0.0:443->443` |
| Nodos K8s | `kubectl get nodes` | Todos `Ready` |
| Ingress Controller | `kubectl get pods -n ingress-nginx` | Pods `Running 1/1` |
| cert-manager | `kubectl get pods -n cert-manager` | 3 pods `Running 1/1` |
| ClusterIssuer | `kubectl get clusterissuer` | `READY: True` |
| Certificate | `kubectl get certificate -n default` | `READY: True` |
| Secret TLS | `kubectl get secret meu-project-tls -n default` | Tipo `kubernetes.io/tls`, `DATA: 2` |
| HTTP redirect | `curl -I http://meu-project.me/` | `301 Moved Permanently` |
| HTTPS respuesta | `curl -I https://meu-project.me/` | `200 OK` |

> 📸 **[CAPTURA SUGERIDA]** Navegador mostrando `https://meu-project.me/` con el candado verde activado y, al hacer clic en él, los detalles del certificado TLS: emisor `Let's Encrypt`, dominio `meu-project.me` y fecha de expiración.

---

## 8. Apéndices

### Apéndice A: Resolución de problemas comunes

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| `[emerg] cannot load certificate` | Ficheros `tls.crt`/`tls.key` no existen o el volumen `certs` no está montado en el Compose | Verificar que `~/nginx-docker/certs/` existe con los ficheros; revisar el `docker-compose.yml` con `docker inspect nginx-proxy \| grep Mounts` |
| `308 Permanent Redirect` en el challenge | `ssl-redirect: true` en el Ingress redirige el tráfico HTTP-01 antes de que exista el cert | Desactivar temporalmente: `kubectl annotate ingress ... ssl-redirect=false` |
| `Connection refused` en puerto 443 desde fuera | Puerto 443 bloqueado en el Security Group de AWS o contenedor NGINX caído | Añadir regla HTTPS (443) Inbound en el SG de AWS; verificar `docker ps` |
| Los dos `md5sum` de cert y key son distintos | Extracción corrupta del Secret (uso de `base64 -d` con saltos de línea) | Re-extraer usando `base64 --decode` (flag larga) |
| `proxy_pass` con URLs corruptas `[http://...]` | El markdown escapa los corchetes al copiar comandos `sed` | Editar el fichero directamente con `python3` o `cat > fichero << 'EOF'` |
| Contenedor en `CrashLoopBackOff` | Error de sintaxis en `nginx.conf` | Verificar con `docker exec nginx-proxy nginx -t` antes de reiniciar |
| Certificate en estado `False` indefinidamente | El challenge HTTP-01 no llega al pod de cert-manager | Verificar que el `proxy_pass` en NGINX apunta al Worker (`10.1.2.96`), no al Master (`10.0.1.136`); y que el NodePort 31967 es accesible |
| `Conflict: container name nginx-proxy already in use` | Contenedor huérfano de un compose anterior | `docker rm -f nginx-proxy && docker compose up -d` |

### Apéndice B: Referencia de puertos

| Puerto | Protocolo | Componente | Descripción |
|--------|-----------|------------|-------------|
| **80** | TCP | Docker NGINX | HTTP público; redirige a HTTPS excepto ruta ACME |
| **443** | TCP | Docker NGINX | HTTPS público; termina TLS con cert Let's Encrypt |
| **6443** | TCP | kube-apiserver | API de Kubernetes (control plane) |
| **10250** | TCP | kubelet | Comunicación interna entre nodos del clúster |
| **30080** | TCP (NodePort) | Ingress Controller | Tráfico HTTP de la aplicación desde el proxy NGINX |
| **31967** | TCP (NodePort) | Ingress Controller | Tráfico ACME challenge HTTP-01 de cert-manager |

### Apéndice C: Ficheros de configuración clave

| Fichero | Ruta en el host | Descripción |
|---------|----------------|-------------|
| `docker-compose.yml` | `~/nginx-docker/docker-compose.yml` | Definición del servicio Docker NGINX |
| `nginx.conf` | `~/nginx-docker/conf/nginx.conf` | Configuración del proxy NGINX (HTTP + HTTPS) |
| `tls.crt` | `~/nginx-docker/certs/tls.crt` | Certificado TLS público emitido por Let's Encrypt |
| `tls.key` | `~/nginx-docker/certs/tls.key` | Clave privada TLS (no compartir ni versionar) |

### Apéndice D: Script de diagnóstico rápido

```bash
#!/bin/bash
# diagnostico-stack.sh — Verifica el estado de todos los componentes del stack

echo "=== DOCKER NGINX ==="
docker ps | grep nginx-proxy
docker logs nginx-proxy --tail 3

echo ""
echo "=== KUBERNETES NODOS ==="
kubectl get nodes -o wide

echo ""
echo "=== KUBERNETES PODS (todos los namespaces) ==="
kubectl get pods -A | grep -v "Running\|Completed"   # Muestra solo los que NO están bien

echo ""
echo "=== CERTIFICADO TLS ==="
kubectl get certificate,secret -n default | grep meu-project

echo ""
echo "=== CONECTIVIDAD ==="
echo -n "HTTP  (esperado 301): "; curl -s -o /dev/null -w "%{http_code}\n" http://meu-project.me/
echo -n "HTTPS (esperado 200): "; curl -s -o /dev/null -w "%{http_code}\n" https://meu-project.me/

echo ""
echo "=== CERTIFICADO SSL EN PRODUCCIÓN ==="
echo | openssl s_client -connect meu-project.me:443 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

---