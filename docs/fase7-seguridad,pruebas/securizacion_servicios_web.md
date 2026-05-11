# Manual de Seguridad: NGINX Docker + Kubernetes Ingress + Aplicaciones

## 1. Visión General de la Seguridad

Este documento describe las capas de seguridad implementadas en el stack de la aplicación `meu-project.me`, desplegado sobre Kubernetes (kubeadm) en AWS. La seguridad se aplica en múltiples niveles complementarios:

```
Internet
   │
   ▼
[AWS Security Groups]       ← Capa 1: Firewall de red (AWS)
   │
   ▼
[NGINX Docker + ModSecurity] ← Capa 2: WAF + TLS termination (EC2 Master)
   │
   ▼
[Ingress NGINX Controller]  ← Capa 3: Routing, SSL-redirect, whitelist IP
   │
   ▼
[Kubernetes Services/Pods]  ← Capa 4: Aislamiento de red (Calico CNI)
   │
   ▼
[Aplicación (PHP/Laravel)]  ← Capa 5: Seguridad de aplicación
```

---

## 2. Seguridad en AWS: Security Groups

Los Security Groups de AWS actúan como **firewall stateful** a nivel de instancia EC2. Solo los puertos estrictamente necesarios están abiertos.

### 2.1 Security Group — k8s-master (EC2 pública)

| Puerto | Protocolo | Origen | Propósito |
|--------|-----------|--------|-----------|
| 22 | TCP | IP admin/VPN | SSH de administración |
| 80 | TCP | 0.0.0.0/0 | HTTP público (redirige a HTTPS) |
| 443 | TCP | 0.0.0.0/0 | HTTPS público (terminación TLS) |
| 6443 | TCP | 10.1.2.96/32 | Kubernetes API Server (solo desde Worker) |
| 10250 | TCP | 10.1.2.96/32 | kubelet (solo desde Worker) |
| ICMP | — | 10.0.0.0/8 | Ping interno entre nodos |

### 2.2 Security Group — k8s-worker (EC2 privada)

| Puerto | Protocolo | Origen | Propósito |
|--------|-----------|--------|-----------|
| 22 | TCP | 10.0.1.136/32 | SSH solo desde el Master |
| 30080 | TCP | 10.0.1.136/32 | NodePort Ingress — tráfico de aplicación (solo desde Master) |
| 31967 | TCP | 10.0.1.136/32 | NodePort ACME challenge (solo desde Master) |
| 10250 | TCP | 10.0.1.136/32 | kubelet (solo desde Master) |
| 179 | TCP | 10.0.1.136/32 | BGP Calico (solo desde Master) |
| 4789 | UDP | 10.0.1.136/32 | VXLAN Calico (solo desde Master) |

> **Principio de mínimo privilegio:** Los NodePorts del Worker (30080, 31967) **no están abiertos a Internet**. Solo el Master, que tiene NGINX Docker, puede acceder a ellos. Esto evita que un atacante externo acceda directamente al Ingress Controller.

---

## 3. NGINX Docker — Hardening y TLS

### 3.1 Imagen base y opciones de seguridad

Se usa la imagen oficial `nginx:alpine` (imagen mínima, sin shell por defecto), con los volúmenes de configuración y certificados montados en **modo solo lectura** (`:ro`).

```yaml
services:
  nginx-proxy:
    image: nginx:alpine
    container_name: nginx-proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro   # :ro → solo lectura
      - ./certs:/etc/nginx/certs:ro                  # :ro → solo lectura
    networks:
      - nginx-net
    restart: unless-stopped
    # Sin privilegios extras: no cap_add, no privileged
```

### 3.2 Configuración TLS segura

Los protocolos y cifrados están restringidos a las versiones modernas:

```nginx
# Solo TLS 1.2 y 1.3 — SSLv3, TLS 1.0 y TLS 1.1 desactivados
ssl_protocols       TLSv1.2 TLSv1.3;

# Cifrados fuertes — se excluyen aNULL (sin autenticación) y MD5 (débil)
ssl_ciphers         HIGH:!aNULL:!MD5;

# Caché de sesiones TLS compartida entre workers de NGINX
ssl_session_cache   shared:SSL:10m;
ssl_session_timeout 10m;
```

| Directiva | Valor | Motivo de seguridad |
|-----------|-------|---------------------|
| `ssl_protocols` | `TLSv1.2 TLSv1.3` | Elimina protocolos vulnerables (POODLE, BEAST) |
| `ssl_ciphers` | `HIGH:!aNULL:!MD5` | Evita cifrados sin autenticación y hashes débiles |
| `ssl_session_cache` | `shared:SSL:10m` | Mejora rendimiento evitando handshakes innecesarios |

### 3.3 Headers de seguridad HTTP

Añadir las siguientes cabeceras en el bloque `server` HTTPS del `nginx.conf`:

```nginx
server {
    listen 443 ssl;
    server_name meu-project.me;

    # ... configuración TLS ...

    # ── Headers de seguridad ──────────────────────────────────────────────
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Ocultar la versión de NGINX en respuestas de error
    server_tokens off;

    # ... proxy_pass ...
}
```

| Header | Valor | Protección |
|--------|-------|-----------|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` | Fuerza HTTPS durante 1 año (HSTS) |
| `X-Frame-Options` | `SAMEORIGIN` | Previene clickjacking — solo permite iframes del mismo origen |
| `X-Content-Type-Options` | `nosniff` | Evita MIME-sniffing de contenido |
| `X-XSS-Protection` | `1; mode=block` | Activa el filtro XSS de navegadores legacy |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | Controla la información del Referer enviada |
| `server_tokens off` | — | Oculta la versión exacta de NGINX en respuestas de error |

### 3.4 Limitación de métodos HTTP

Para restringir los métodos HTTP permitidos (solo GET, HEAD, POST):

```nginx
location / {
    # Solo permite métodos estándar de la aplicación
    limit_except GET HEAD POST {
        deny all;
    }

    proxy_pass http://10.1.2.96:30080;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
}
```

### 3.5 Rate limiting (protección DoS básica)

```nginx
http {
    # Zona de rate limiting: 10 MB de memoria, 10 req/s por IP
    limit_req_zone $binary_remote_addr zone=req_limit:10m rate=10r/s;
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    server {
        listen 443 ssl;
        # ...

        location / {
            # Burst de 20 peticiones, sin delay
            limit_req zone=req_limit burst=20 nodelay;
            # Máximo 10 conexiones simultáneas por IP
            limit_conn conn_limit 10;

            proxy_pass http://10.1.2.96:30080;
            # ...
        }
    }
}
```

### 3.6 ModSecurity WAF (OWASP CRS)

En sesiones anteriores se detectó que el contenedor estaba usando la imagen `owasp/modsecurity-crs:nginx-alpine`, que integra el WAF ModSecurity con el ruleset OWASP Core Rule Set (CRS). El error `Read-only file system` al arrancar se producía porque la imagen intenta escribir en `/etc/nginx/nginx.conf`, que estaba montado como `:ro`.

**Solución para imagen ModSecurity + nginx:**

```yaml
services:
  nginx-proxy:
    image: owasp/modsecurity-crs:nginx-alpine
    container_name: nginx-proxy
    ports:
      - "80:80"
      - "443:443"
    environment:
      # Modo de ModSecurity: DetectionOnly (solo log) o On (bloqueo activo)
      MODSEC_RULE_ENGINE: "On"
      # Paranoia level: 1 (bajo FP) a 4 (máxima seguridad, más FP)
      PARANOIA: "1"
      # Servidor backend al que el contenedor hace proxy
      BACKEND: "http://10.1.2.96:30080"
      BACKEND_WS: "ws://10.1.2.96:30080"
    volumes:
      # No montar nginx.conf como :ro — la imagen lo gestiona con envsubst
      - ./certs:/etc/nginx/certs:ro
    networks:
      - nginx-net
    restart: unless-stopped
```

> **Diferencia clave respecto a `nginx:alpine`:** La imagen `owasp/modsecurity-crs:nginx-alpine` utiliza variables de entorno y templates para generar su configuración en tiempo de arranque. Si se monta `nginx.conf` como `:ro`, el script `20-envsubst-on-templates.sh` no puede escribir el fichero final y el contenedor entra en `CrashLoopBackOff`. La solución es usar las variables de entorno en lugar de un `nginx.conf` personalizado, o usar `nginx:alpine` sin ModSecurity y configurar las reglas manualmente.

**Comandos de verificación ModSecurity:**

```bash
# Ver si ModSecurity está activo y en qué modo
docker exec nginx-proxy nginx -T | grep -i modsec

# Logs de auditoría de ModSecurity (detecciones y bloqueos)
docker exec nginx-proxy tail -f /var/log/modsec_audit.log

# Logs de nginx con eventos de ModSecurity
docker logs nginx-proxy 2>&1 | grep -i "modsec\|blocked\|detected"
```

---

## 4. Seguridad en el Ingress NGINX Controller

### 4.1 Anotaciones de seguridad del Ingress

Las anotaciones del Ingress permiten aplicar políticas de seguridad específicas por recurso sin modificar la configuración global del Ingress Controller.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: meu-project-ingress
  namespace: default
  annotations:
    # ── TLS y redirecciones ──────────────────────────────────────────────
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "false"

    # ── Rate limiting en el Ingress ──────────────────────────────────────
    nginx.ingress.kubernetes.io/limit-rps: "20"
    nginx.ingress.kubernetes.io/limit-connections: "10"

    # ── Headers de seguridad (propagados al cliente final) ───────────────
    nginx.ingress.kubernetes.io/configuration-snippet: |
      add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
      add_header X-Frame-Options "SAMEORIGIN" always;
      add_header X-Content-Type-Options "nosniff" always;
      more_clear_headers "Server";

    # ── Tamaño máximo de body (protección contra uploads masivos) ────────
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"

    # ── Timeouts ─────────────────────────────────────────────────────────
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "60"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - meu-project.me
    secretName: meu-project-tls
  rules:
  - host: meu-project.me
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: meu-svc
            port:
              number: 80
```

### 4.2 Whitelist de IPs por Ingress

La anotación `whitelist-source-range` restringe el acceso a un Ingress concreto a un rango de IPs. Se usa en phpMyAdmin para que solo la IP del administrador pueda acceder.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: phpmyadmin-ingress
  namespace: default
  annotations:
    # Solo la IP pública del administrador puede acceder
    nginx.ingress.kubernetes.io/whitelist-source-range: "54.163.235.144/32"
spec:
  ingressClassName: nginx
  rules:
  - host: pma.meu-project.me
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: phpmyadmin-service
            port:
              number: 80
```

```bash
# Verificar la anotación activa
kubectl describe ingress phpmyadmin-ingress -n default | grep whitelist

# Actualizar la IP cuando cambia (AWS Academy reinicia las IPs públicas)
kubectl annotate ingress phpmyadmin-ingress \
  nginx.ingress.kubernetes.io/whitelist-source-range="NUEVA_IP/32" \
  --overwrite

# Probar que el acceso desde una IP no autorizada devuelve 403
curl -H "Host: pma.meu-project.me" http://<IP_WORKER>:30080/
# Esperado: 403 Forbidden
```

> Las IPs de pods de Calico (`192.168.x.x`) son IPs internas del clúster y **no** están sujetas al whitelist del Ingress. Las peticiones desde pods internos al Ingress se consideran tráfico de confianza — comportamiento esperado y correcto en este diseño.

### 4.3 Tabla de anotaciones de seguridad del Ingress

| Anotación | Descripción | Valor recomendado |
|-----------|-------------|-------------------|
| `ssl-redirect` | Redirige HTTP → HTTPS | `"true"` |
| `force-ssl-redirect` | Fuerza redirección ignorando X-Forwarded-Proto | `"false"` (con proxy externo) |
| `whitelist-source-range` | Restringe acceso a IPs/CIDRs | `"IP/32"` |
| `limit-rps` | Rate limit en peticiones por segundo | `"20# Manual de Configuración: Proxy NGINX Docker + Kubernetes + Certificado TLS

## 1. Arquitectura General

El flujo de tráfico externo es:

```
Internet → DNS (*.meu-project.me) → IP pública ec2-master
         → NGINX Docker (puerto 80/443)
         → Ingress NGINX Controller (NodePort)
         → Services y Pods de Kubernetes
```

Con la migración completa a Kubernetes, el **Ingress NGINX Controller** gestiona el tráfico directamente. El proxy Docker actúa como capa de entrada opcional para redirigir al NodePort del Ingress.

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

---

## 2. Proxy Inverso NGINX con Docker

### 2.1 Estructura de directorios

```
~/nginx-docker/
├── docker-compose.yml
├── conf/
│   └── nginx.conf
├── certs/
│   ├── fullchain.pem
│   └── privkey.pem
└── html/
    └── index.html
```

> El directorio `certs/` y sus ficheros deben existir **antes** de arrancar el contenedor.
> Si no existen, NGINX falla con `[emerg] cannot load certificate` y entra en `CrashLoopBackOff`.

### 2.2 docker-compose.yml

```yaml
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

**Comandos de gestión:**

```bash
# Levantar el proxy
cd ~/nginx-docker
docker compose up -d

# Ver estado y logs
docker compose ps
docker compose logs -f

# Recargar configuración sin reiniciar
docker compose exec nginx-proxy nginx -s reload

# Parar
docker compose down
```

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

> La cabecera `X-Forwarded-Proto: https` es crítica: informa a la aplicación y al Ingress que la conexión original era segura, evitando bucles de redirección internos cuando el Ingress tiene `ssl-redirect: true`.

### 2.4 Gestión del contenedor

<div align="center">
  <img src="../../media/docker_ps_nginx.png" alt="Outpout de docker ps" />
</div>

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

<div align="center">
  <img src="../../media/kubectl_get_nodes_wide.png" alt="Outpout de kubectl nodes" />
</div>


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

<div align="center">
  <img src="../../media/kubectl_services_view.png" alt="Outpout de kubectl services" />
</div>

---

## 4. Ingress Controller

El **Ingress Controller de NGINX** gestiona el enrutamiento del tráfico HTTP/HTTPS entrante dentro del clúster Kubernetes. Corre como un pod en el nodo Worker y se expone al exterior mediante NodePorts.

### Verificar estado

```bash
kubectl get svc -n ingress-nginx
kubectl get pods -n ingress-nginx -o wide
```

Salida esperada:
```
NAME                       TYPE       CLUSTER-IP     PORT(S)
ingress-nginx-controller   NodePort   10.105.105.1   80:31967/TCP,443:30601/TCP
```

### Mover el Ingress al Master (recomendado)

Por defecto Kubernetes puede programar el pod del Ingress en cualquier nodo. Para garantizar estabilidad, forzarlo al Master:

```bash
kubectl patch deployment ingress-nginx-controller   -n ingress-nginx   --type=json   -p='[
    {"op":"add","path":"/spec/template/spec/tolerations","value":[
      {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}
    ]},
    {"op":"add","path":"/spec/template/spec/nodeSelector","value":{
      "kubernetes.io/hostname":"k8s-master"
    }}
  ]'

# Verificar que está en el Master
kubectl get pods -n ingress-nginx -o wide
```

> La misma técnica aplica a cualquier deployment crítico (phpMyAdmin, cert-manager) que deba ejecutarse en el Master.

---

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

> **Problema conocido:** Con `ssl-redirect: true` activo, el Ingress redirige la petición HTTP-01 de Let's Encrypt (que llega por el puerto 80) a HTTPS antes de que el certificado exista. Esto rompe el proceso de validación y el challenge falla.

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

<div align="center">
  <img src="../../media/kubectl_describe_ingress.png" alt="Outpout de kubectl certificates" />
</div>

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

<div align="center">
  <img src="../../media/kubectl_describe_ingress.png" alt="Outpout de kubectl services" />
</div>

### 5.2 ClusterIssuer — Let's Encrypt Producción

El `ClusterIssuer` define la autoridad certificadora (Let's Encrypt) y el método de validación del dominio. Se usa `ClusterIssuer` (en lugar de `Issuer`) para que sea válido en todos los namespaces del clúster.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: tu@email.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
```

```bash
kubectl apply -f k8s/letsencrypt-issuer.yaml

# Verificar
kubectl get clusterissuer
# letsencrypt-prod   True
```

Con el ClusterIssuer activo, cert-manager obtiene y renueva los certificados automáticamente mediante el challenge HTTP-01.

**Ejemplo:** `k8s/ingress-principal.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: meu-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - meu-project.me
    - www.meu-project.me
    secretName: meu-project-tls
  rules:
  - host: meu-project.me
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: meu-svc
            port:
              number: 80
  - host: www.meu-project.me
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: meu-svc
            port:
              number: 80
```

```bash
kubectl apply -f k8s/ingress-principal.yaml

# Seguir el estado del certificado
kubectl get certificate
kubectl describe certificate meu-project-tls
# Status: Ready = True  (puede tardar 1-2 minutos)
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

> Usar siempre `base64 --decode` (flag larga). La flag corta `base64 -d` en algunas versiones de Ubuntu puede procesar incorrectamente los saltos de línea y generar ficheros corruptos que NGINX no puede cargar.

### 6.2 Verificación de integridad del certificado

Antes de reiniciar el contenedor, verificar que los ficheros son válidos y que certificado y clave hacen pareja:

```bash
# Ver los detalles del certificado (dominio y fechas de validez)
openssl x509 -in ~/nginx-docker/certs/tls.crt -noout -subject -issuer -dates

# Verificar que cert y key son una pareja válida
# Los dos hashes md5sum DEBEN SER IDÉNTICOS
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

## 8. phpMyAdmin con whitelist IP

El acceso a phpMyAdmin se restringe por IP pública mediante la anotación `whitelist-source-range`.

**Archivo:** `k8s/phpmyadmin/phpmyadmin-ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: phpmyadmin-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "54.163.235.144/32"
spec:
  ingressClassName: nginx
  rules:
  - host: pma.meu-project.me
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: phpmyadmin-service
            port:
              number: 80
```

```bash
kubectl apply -f k8s/phpmyadmin/phpmyadmin-ingress.yaml

# Actualizar la IP si cambia (AWS Academy reinicia las IPs)
kubectl annotate ingress phpmyadmin-ingress   nginx.ingress.kubernetes.io/whitelist-source-range="NUEVA_IP/32"   --overwrite
```

> Las IPs de Calico (`192.168.x.x`) son IPs internas de pods y bypasan el whitelist — es comportamiento esperado dentro del clúster.

## 9. Apéndices

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

## 9. Troubleshooting

### 9.1 502 Bad Gateway en la web

**Síntoma:** La web devuelve `502 Bad Gateway` al acceder via HTTPS.

**Diagnóstico:**
```bash
# Comprobar si el Ingress del Worker responde
curl -v http://<IP_WORKER>:30080/

# Comprobar estado de los nodos
kubectl get nodes

# Comprobar estado de los pods
kubectl get pods -A
```

**Causas posibles:**
- API Server caído → ver sección 9.2
- Ingress Controller no responde → ver sección 9.3
- NGINX Docker mal configurado → ver sección 9.4

---

### 9.2 API Server caído — `connection refused` en puerto 6443

**Síntoma:**
```
The connection to the server 10.0.1.X:6443 was refused
```

**Diagnóstico:**
```bash
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 30 --no-pager | grep -E "error|Error|failed|Failed"
```

#### 9.2.1 `config.yaml` del kubelet no existe

**Error en logs:**
```
failed to load kubelet config file /var/lib/kubelet/config.yaml: no such file or directory
```

**Solución:**
```bash
sudo kubeadm init phase kubelet-start
sudo systemctl restart kubelet
sleep 15
kubectl get nodes
```

---

#### 9.2.2 `kubelet-client-current.pem` no existe

**Error en logs:**
```
unable to read client-cert /var/lib/kubelet/pki/kubelet-client-current.pem:
no such file or directory
```

**Solución:**
```bash
# Verificar que los certificados del clúster existen
ls -la /etc/kubernetes/pki/apiserver-kubelet-client.*

# Regenerar el PEM combinando certificado + clave
sudo bash -c 'cat /etc/kubernetes/pki/apiserver-kubelet-client.crt \
                  /etc/kubernetes/pki/apiserver-kubelet-client.key \
              > /var/lib/kubelet/pki/kubelet-client-current.pem'

sudo chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem

# Verificar que contiene ambos bloques
sudo grep "BEGIN" /var/lib/kubelet/pki/kubelet-client-current.pem

# Reiniciar el kubelet
sudo systemctl restart kubelet
sleep 15
kubectl get nodes
```

> 📸 **[CAPTURA SUGERIDA]:** Output de `kubectl get nodes` con ambos nodos en estado `Ready`.

---

#### 9.2.3 Prevención — servicio de recuperación automática

Para evitar que el `kubelet-client-current.pem` desaparezca tras un reinicio
de la instancia EC2, instalar el siguiente servicio systemd:

```bash
# Crear el script de recuperación
sudo tee /usr/local/bin/kubelet-pki-restore.sh << 'EOF'
#!/bin/bash
PKI_FILE="/var/lib/kubelet/pki/kubelet-client-current.pem"
CRT="/etc/kubernetes/pki/apiserver-kubelet-client.crt"
KEY="/etc/kubernetes/pki/apiserver-kubelet-client.key"

if [ ! -f "$PKI_FILE" ] && [ -f "$CRT" ] && [ -f "$KEY" ]; then
  mkdir -p /var/lib/kubelet/pki
  cat "$CRT" "$KEY" > "$PKI_FILE"
  chmod 600 "$PKI_FILE"
fi
EOF

sudo chmod +x /usr/local/bin/kubelet-pki-restore.sh

# Crear el servicio systemd
sudo tee /etc/systemd/system/kubelet-pki-restore.service << 'EOF'
[Unit]
Description=Restore kubelet client PKI if missing
Before=kubelet.service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kubelet-pki-restore.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable kubelet-pki-restore.service
```

---

### 9.3 Ingress Controller no responde

**Síntoma:** `curl http://<IP_WORKER>:30080/` devuelve `Connection refused`.

**Diagnóstico:**
```bash
# Estado del pod del Ingress Controller
kubectl get pods -n ingress-nginx

# Logs del Ingress Controller
kubectl logs -n ingress-nginx \
  $(kubectl get pods -n ingress-nginx -o name | head -1) --tail 30

# Verificar endpoints del servicio de la aplicación
kubectl get endpoints -n default
```

**Solución más común:** El API Server estaba caído y el pod del Ingress quedó
en estado `Pending` o `CrashLoopBackOff`. Una vez recuperado el API Server
(ver 9.2), el pod se recupera automáticamente en ~1 minuto.

```bash
# Forzar recreación del pod si no se recupera solo
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
kubectl get pods -n ingress-nginx -w
```

---

### 9.4 NGINX Docker — `proxy_pass` no enruta correctamente

**Síntoma:** El Ingress responde bien en el puerto 30080 pero la web sigue
dando 502.

**Diagnóstico:**
```bash
# Logs de errores del contenedor NGINX
docker logs nginx-proxy --tail 50 2>&1 | grep -E "error|502|upstream|failed"

# Ver el fichero de configuración activo
docker exec nginx-proxy nginx -T | grep -A5 "upstream\|proxy_pass"
```

**Verificación del proxy_pass:**
```bash
# La IP del proxy_pass debe apuntar al Worker, no al Master
# Correcto:   proxy_pass http://10.1.2.96:30080;
# Incorrecto: proxy_pass http://10.0.1.136:30080;

# Recargar configuración tras corregir
docker exec nginx-proxy nginx -s reload
```

---

### 9.5 Certificado TLS — web no carga en HTTPS

**Síntoma:** El navegador muestra error de certificado o la web no carga en HTTPS.

**Diagnóstico:**
```bash
# Estado del certificado de cert-manager
kubectl get certificate -n default
kubectl describe certificate meu-project-tls -n default

# Estado del challenge ACME
kubectl get challenges -n default
kubectl get orders -n default
```

**Problema frecuente — ssl-redirect bloquea el challenge HTTP-01:**

Si el challenge queda en estado `pending`, desactivar temporalmente el
redirect SSL durante la emisión:

```bash
# Desactivar redirect SSL temporalmente
kubectl annotate ingress <nombre-ingress> \
  "nginx.ingress.kubernetes.io/ssl-redirect=false" --overwrite

# Esperar a que el certificado esté Ready
kubectl get certificate -w

# Reactivar redirect SSL
kubectl annotate ingress <nombre-ingress> \
  "nginx.ingress.kubernetes.io/ssl-redirect=true" --overwrite
```

> **Estado esperado tras resolución:**
> ```
> NAME              READY   SECRET            AGE
> meu-project-tls   True    meu-project-tls   Xm
> ```

---

### 9.6 Tabla resumen de incidencias

| Error | Causa raíz | Comando de diagnóstico | Solución rápida |
|-------|-----------|----------------------|-----------------|
| `502 Bad Gateway` | API Server caído | `kubectl get nodes` | Ver 9.2 |
| `config.yaml not found` | Reboot EC2 borró el fichero | `journalctl -u kubelet` | `kubeadm init phase kubelet-start` |
| `kubelet-client-current.pem not found` | Directorio PKI vacío | `ls /var/lib/kubelet/pki/` | Regenerar PEM con `cat crt + key` |
| `Connection refused :30080` | Pod Ingress caído | `kubectl get pods -n ingress-nginx` | `kubectl rollout restart` |
| Challenge ACME pendiente | ssl-redirect activo | `kubectl get challenges` | Anotar `ssl-redirect=false` |
| `proxy_pass` incorrecto | IP apunta al Master | `docker exec nginx-proxy nginx -T` | Corregir IP al Worker |
```"` |
| `limit-connections` | Conexiones simultáneas máximas por IP | `"10"` |
| `proxy-body-size` | Tamaño máximo del cuerpo de la petición | `"10m"` |
| `configuration-snippet` | Bloque nginx custom a nivel de location | Headers de seguridad |
| `server-snippet` | Bloque nginx custom a nivel de server | server_tokens off |

---

## 5. Seguridad en cert-manager y TLS

### 5.1 Ciclo de vida seguro del certificado

Los certificados TLS de Let's Encrypt tienen **validez de 90 días** y son renovados automáticamente por cert-manager cuando quedan **30 días** para la expiración. La clave privada nunca sale del clúster: se almacena en un Secret de tipo `kubernetes.io/tls`, que solo los Pods y recursos con permisos explícitos pueden leer.

```bash
# Verificar que el Secret TLS existe y tiene los campos correctos
kubectl get secret meu-project-tls -n default -o jsonpath='{.type}'
# Esperado: kubernetes.io/tls

# Verificar que DATA contiene exactamente 2 campos (tls.crt y tls.key)
kubectl get secret meu-project-tls -n default
# NAME              TYPE                DATA   AGE
# meu-project-tls   kubernetes.io/tls   2      Xd

# Ver la fecha de expiración del certificado
kubectl get certificate meu-project-tls -n default \
  -o jsonpath='{.status.notAfter}' && echo

# Verificar que el certificado no está expirado y el emisor es correcto
echo | openssl s_client -connect meu-project.me:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

### 5.2 Protección de la clave privada extraída

Cuando se extrae el certificado del Secret de Kubernetes para el contenedor NGINX Docker, hay que proteger el fichero `tls.key`:

```bash
# Extraer certificado y clave
kubectl get secret meu-project-tls -n default \
  -o jsonpath='{.data.tls\.crt}' | base64 --decode > ~/nginx-docker/certs/tls.crt

kubectl get secret meu-project-tls -n default \
  -o jsonpath='{.data.tls\.key}' | base64 --decode > ~/nginx-docker/certs/tls.key

# Permisos restrictivos sobre la clave privada
chmod 600 ~/nginx-docker/certs/tls.key
chmod 644 ~/nginx-docker/certs/tls.crt

# Verificar propietario y permisos
ls -la ~/nginx-docker/certs/
# -rw-r--r-- 1 ubuntu ubuntu  4096 ... tls.crt
# -rw------- 1 ubuntu ubuntu  1679 ... tls.key
```

> **La clave privada (`tls.key`) no debe versionarse nunca en Git.** Añadir al `.gitignore` del proyecto:
> ```
> nginx-docker/certs/
> *.key
> *.pem
> ```

### 5.3 Verificación de integridad del par certificado/clave

Antes de reiniciar el contenedor NGINX tras extraer los certificados, verificar que el certificado y la clave son un par válido:

```bash
# Los dos md5sum DEBEN ser idénticos para ser un par válido
openssl x509 -noout -modulus -in ~/nginx-docker/certs/tls.crt | md5sum
openssl rsa  -noout -modulus -in ~/nginx-docker/certs/tls.key | md5sum

# Salida esperada (hashes idénticos):
# 6b09d94b54346aaed31bbaf7dfe8cde5  -
# 6b09d94b54346aaed31bbaf7dfe8cde5  -
```

---

## 6. Seguridad en la Aplicación (PHP/Laravel)

### 6.1 Variables de entorno y Secrets de Kubernetes

Las credenciales de la aplicación (contraseñas de BD, API keys) **nunca** se incluyen en el código ni en las imágenes Docker. Se gestionan como Secrets de Kubernetes:

```bash
# Crear un Secret para las credenciales de la aplicación
kubectl create secret generic app-secrets \
  --from-literal=DB_PASSWORD='contraseña-segura' \
  --from-literal=APP_KEY='base64:...' \
  -n default

# Verificar que el secret existe (no muestra los valores)
kubectl get secret app-secrets -n default
```

```yaml
# Referencia al Secret en el Deployment de la aplicación
apiVersion: apps/v1
kind: Deployment
metadata:
  name: meu-app-deployment
  namespace: default
spec:
  template:
    spec:
      containers:
      - name: meu-app
        image: <imagen-app>
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: DB_PASSWORD
        - name: APP_KEY
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: APP_KEY
```

### 6.2 Acceso seguro a phpMyAdmin

phpMyAdmin es una interfaz crítica que da acceso directo a la base de datos. Las medidas de seguridad aplicadas son:

- **Whitelist IP** en el Ingress (ver sección 4.2) — solo la IP del administrador.
- **Sin exposición directa de puertos**: el Service de phpMyAdmin es de tipo `ClusterIP`, no `NodePort`. Solo el Ingress puede enrutarle tráfico.
- **Sin TLS en el servicio interno**: el TLS termina en el Ingress; la comunicación interna del clúster va cifrada por la red Calico (IPsec en IPIP mode).

```bash
# Verificar que phpMyAdmin tiene Service ClusterIP (no NodePort)
kubectl get svc phpmyadmin-service -n default
# TYPE: ClusterIP ← correcto; NodePort sería un riesgo

# Probar que la IP no autorizada recibe 403
curl -k -H "X-Forwarded-For: 1.2.3.4" https://pma.meu-project.me/
# Esperado: 403 Forbidden
```

### 6.3 Headers del proxy hacia la aplicación

La cadena de headers que transporta información de seguridad desde el cliente hasta la aplicación:

```nginx
# En nginx.conf (bloque HTTPS)
location / {
    proxy_pass http://10.1.2.96:30080;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;       # IP real del cliente
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;              # Indica que la conexión original era HTTPS
}
```

> La cabecera `X-Forwarded-Proto: https` es crítica para que Laravel u otras aplicaciones no generen URLs HTTP internas cuando detectan que la petición llegó "sin SSL" (porque el TLS terminó en NGINX antes de llegar al pod).

En **Laravel**, asegurarse de que el `AppServiceProvider` o `TrustedProxies` está correctamente configurado:

```php
// app/Http/Middleware/TrustProxies.php
protected $proxies = '*';  // Confía en todos los proxies (ajustar en producción)
protected $headers = Request::HEADER_X_FORWARDED_FOR |
                     Request::HEADER_X_FORWARDED_HOST |
                     Request::HEADER_X_FORWARDED_PORT |
                     Request::HEADER_X_FORWARDED_PROTO;
```

---

## 7. Seguridad de Red con Calico CNI

Calico es el plugin CNI del clúster y actúa como **firewall interno** entre pods mediante `NetworkPolicies`. Por defecto, todos los pods pueden comunicarse entre sí (`defaultEndpointToHostAction: ACCEPT`).

### 7.1 NetworkPolicy — Denegar todo por defecto (recomendado)

```yaml
# Política de "deny-all" — denegar todo el tráfico entrante por defecto
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: default
spec:
  podSelector: {}    # Aplica a todos los pods del namespace
  policyTypes:
  - Ingress
```

```yaml
# Permitir tráfico solo desde el Ingress Controller
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ingress
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: meu-app    # Solo los pods de la aplicación
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

```bash
# Aplicar las políticas
kubectl apply -f k8s/network-policies/default-deny.yaml
kubectl apply -f k8s/network-policies/allow-from-ingress.yaml

# Verificar las políticas activas
kubectl get networkpolicies -n default
```

### 7.2 Configuración de Calico relevante para seguridad

| Parámetro | Valor en el clúster | Impacto de seguridad |
|-----------|---------------------|----------------------|
| `defaultEndpointToHostAction` | `ACCEPT` | Los pods pueden comunicarse con el host (necesario para DNS y API) |
| `IPIPMode` | `Always` | El tráfico entre nodos va encapsulado en IP-in-IP |
| `IPV6Support` | `false` | IPv6 desactivado, reduce superficie de ataque |
| `WireguardEnabled` | `false` | No hay cifrado Wireguard entre nodos (para activarlo: `calicoctl patch felixconfiguration...`) |

---

## 8. Checklist de Seguridad

### 8.1 Verificación rápida del estado de seguridad

```bash
#!/bin/bash
# security-check.sh — Verifica el estado de seguridad del stack

echo "=== [1] TLS — Certificado y protocolos ==="
echo | openssl s_client -connect meu-project.me:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
echo ""
echo -n "Protocolo TLS en uso: "
echo | openssl s_client -connect meu-project.me:443 2>/dev/null | grep "Protocol"

echo ""
echo "=== [2] Headers de seguridad ==="
curl -s -I https://meu-project.me/ | grep -E "Strict-Transport|X-Frame|X-Content-Type|X-XSS|Server:"

echo ""
echo "=== [3] Redirección HTTP → HTTPS ==="
echo -n "HTTP status (esperado 301): "
curl -s -o /dev/null -w "%{http_code}\n" http://meu-project.me/

echo ""
echo "=== [4] Whitelist phpMyAdmin ==="
echo -n "Acceso desde IP no autorizada (esperado 403): "
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: pma.meu-project.me" http://1.2.3.4/

echo ""
echo "=== [5] Certificado Kubernetes ==="
kubectl get certificate -n default
kubectl get secret meu-project-tls -n default

echo ""
echo "=== [6] NetworkPolicies activas ==="
kubectl get networkpolicies -n default

echo ""
echo "=== [7] Secrets de aplicación (sin mostrar valores) ==="
kubectl get secrets -n default | grep -v "kubernetes.io/service-account-token"

echo ""
echo "=== [8] Permisos de la clave privada ==="
ls -la ~/nginx-docker/certs/tls.key
```

### 8.2 Tabla de estado esperado

| Control de seguridad | Comando | Estado esperado |
|----------------------|---------|-----------------|
| TLS activo (Let's Encrypt) | `kubectl get certificate` | `READY: True` |
| Solo TLS 1.2/1.3 | `openssl s_client -connect ... \| grep Protocol` | `TLSv1.3` o `TLSv1.2` |
| HTTP redirige a HTTPS | `curl -I http://meu-project.me/` | `301 Moved Permanently` |
| phpMyAdmin con whitelist | `kubectl describe ingress phpmyadmin-ingress` | Anotación `whitelist-source-range` visible |
| Clave privada protegida | `ls -la ~/nginx-docker/certs/tls.key` | Permisos `600` |
| Secrets como K8s Secrets | `kubectl get secrets -n default` | `app-secrets` existe, tipo `Opaque` |
| NodePorts no expuestos a Internet | AWS Console → SG Worker | Reglas de entrada solo desde `10.0.1.136/32` |

---

## 9. Apéndice: Problemas de Seguridad Conocidos y Soluciones

| Problema | Riesgo | Solución |
|----------|--------|----------|
| `nginx.conf` montado `:ro` con imagen `owasp/modsecurity-crs` | `CrashLoopBackOff` — el WAF no arranca | Usar variables de entorno `BACKEND`, `MODSEC_RULE_ENGINE` en lugar de montar `nginx.conf` |
| `tls.key` con permisos 644 | La clave privada es legible por todos los usuarios del sistema | `chmod 600 ~/nginx-docker/certs/tls.key` |
| `ssl-redirect: true` durante emisión de certificado | El challenge HTTP-01 de Let's Encrypt falla (308 redirect) | Desactivar temporalmente con `kubectl annotate ingress ... ssl-redirect=false` |
| NodePorts (30080, 31967) abiertos a `0.0.0.0/0` en SG | Expone el Ingress Controller directamente a Internet sin pasar por NGINX | Restringir reglas de entrada del SG del Worker solo a la IP privada del Master (`10.0.1.136/32`) |
| phpMyAdmin sin whitelist IP | Acceso a la BD desde cualquier IP en Internet | Aplicar anotación `whitelist-source-range` en el Ingress de phpMyAdmin |
| Credenciales en variables de entorno en el Deployment YAML | Secretos visibles en el manifiesto versionado en Git | Usar `secretKeyRef` apuntando a un `Secret` de Kubernetes |
| `base64 -d` en lugar de `base64 --decode` al extraer certs | Extracción corrupta del certificado, NGINX no puede cargar TLS | Siempre usar `base64 --decode` (flag larga) en Ubuntu |