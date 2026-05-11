# Configuración: Kubernetes + Calico + Ingress NGINX + Certificados TLS

## 1. Arquitectura General

Con la migración completa a Kubernetes, el **Ingress NGINX Controller** gestiona el tráfico directamente desde Internet sin necesidad de un proxy Docker externo. El flujo de tráfico es:

```
Internet → DNS (*.meu-project.me → 18.235.39.46)
         → IP pública k8s-submaster (Elastic IP AWS)
         → Ingress NGINX Controller (puertos 80/443 directos)
         → Services y Pods de Kubernetes
```

**¿Por qué esta arquitectura?**

En la arquitectura anterior existía un proxy NGINX Docker en el master que recibía el tráfico externo y lo reenviaba al Ingress Controller del worker mediante NodePorts (30080/31967). Esta capa adicional introducía complejidad operativa y un punto de fallo extra. Con la migración, se elimina ese intermediario y el Ingress Controller escucha directamente en los puertos estándar 80 y 443, simplificando el stack y reduciendo la latencia.

La razón por la que el tráfico entra por el **submaster** y no por el master es que Kubernetes programa el pod de `ingress-nginx-controller` en el nodo con más recursos disponibles. El submaster tiene la Elastic IP `18.235.39.46` y el pod de ingress corre ahí, por lo que todo el DNS de `*.meu-project.me` apunta a esa IP.

### 1.1 Roles de cada nodo

| Nodo | IP Privada | IP Pública | Rol | Componentes principales |
|------|-----------|------------|-----|------------------------|
| k8s-master | 10.0.1.118 | 54.144.217.31 | Control Plane | API Server, etcd, scheduler, controller-manager |
| k8s-submaster | 10.0.1.106 | 18.235.39.46 | Worker + Ingress | Ingress NGINX Controller, pods de aplicación |
| worker | 10.0.1.x | — | Worker | Pods de aplicación |

---

## 2. Red de Pods: Calico CNI

### 2.1 ¿Qué es Calico y por qué se usa?

Calico es el plugin CNI (Container Network Interface) que proporciona conectividad de red entre pods en el clúster. Sin un CNI activo, los pods no pueden comunicarse entre sí ni con los servicios del cluster, incluido el propio kube-apiserver.

Calico utiliza **BGP (Border Gateway Protocol)** para distribuir las rutas de red entre nodos, y **IP-in-IP** como modo de encapsulación para el tráfico entre subredes distintas (como ocurre en AWS, donde cada nodo está en una subred separada).

**¿Por qué IP-in-IP CrossSubnet en AWS?**

En AWS, los nodos de distintas subredes no pueden enrutarse directamente sin encapsulación porque la VPC no conoce las rutas de los pods. El modo `CrossSubnet` aplica encapsulación IP-in-IP solo cuando el tráfico cruza subredes (overlay selectivo), manteniendo el tráfico dentro de la misma subred sin encapsular para mayor rendimiento.

### 2.2 Configuración crítica: MTU en AWS

AWS utiliza instancias con MTU de red de 9001 bytes (Jumbo Frames). Al usar IP-in-IP, cada paquete añade 20 bytes de overhead de encapsulación, por lo que la MTU de los pods debe ser:

```
MTU Calico = MTU red AWS - overhead IP-in-IP = 9001 - 50 = 8951
```

Si la MTU no está ajustada correctamente, los paquetes grandes se fragmentan, causando degradación del rendimiento o pérdida de conectividad intermitente.

### 2.3 Problema conocido: bootstrap en entornos sin CNI

Existe un círculo vicioso documentado al inicializar Calico en un clúster donde el CNI no está activo:

```
Sin CNI → pods init no tienen red → init-cni no puede crear token
       → token no creado → CNI no se instala → sin CNI
```

El init container `install-cni` de calico-node usa `inClusterConfig` para obtener un token del ServiceAccount `calico-cni-plugin` mediante la API de Kubernetes (`10.96.0.1:443`). Aunque el nodo host sí tiene conectividad, el pod init corre en un network namespace sin interfaz de red funcional hasta que el CNI esté instalado.

**Solución aplicada:** pre-crear el kubeconfig de `calico-cni-plugin` manualmente en todos los nodos antes de que Calico arranque, evitando que el init container necesite contactar la API durante la fase de bootstrap.

```bash
# Genera un token de larga duración
kubectl create token calico-cni-plugin -n kube-system --duration=8760h > /tmp/calico-cni-token.txt

# Obtén los datos del cluster
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(cat /tmp/calico-cni-token.txt)

# Construye el kubeconfig
cat > /tmp/calico-kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: kubernetes
  cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${APISERVER}
contexts:
- name: calico-cni-plugin@kubernetes
  context:
    cluster: kubernetes
    user: calico-cni-plugin
current-context: calico-cni-plugin@kubernetes
users:
- name: calico-cni-plugin
  user:
    token: ${TOKEN}
EOF

# Distribuye a todos los nodos
sudo cp /tmp/calico-kubeconfig /etc/cni/net.d/calico-kubeconfig

# Workers (con clave PEM)
scp -i ~/.ssh/keypair-proyecto-k8s.pem /tmp/calico-kubeconfig meu_master@k8s-submaster:/tmp/
ssh -i ~/.ssh/keypair-proyecto-k8s.pem meu_master@k8s-submaster \
  "sudo mkdir -p /etc/cni/net.d && sudo cp /tmp/calico-kubeconfig /etc/cni/net.d/calico-kubeconfig"

scp -i ~/.ssh/keypair-proyecto-k8s.pem /tmp/calico-kubeconfig ubuntu@<IP_WORKER2>:/tmp/
ssh -i ~/.ssh/keypair-proyecto-k8s.pem ubuntu@<IP_WORKER2> \
  "sudo mkdir -p /etc/cni/net.d && sudo cp /tmp/calico-kubeconfig /etc/cni/net.d/calico-kubeconfig"
```

### 2.4 Verificación del estado de Calico

```bash
# Estado de los pods (deben estar 1/1 Running en todos los nodos)
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide

# Verificar BGP establecido
kubectl exec -n kube-system \
  $(kubectl get pod -n kube-system -l k8s-app=calico-node --field-selector spec.nodeName=k8s-master -o name) \
  -- calico-node -bird-live

# Logs de BGP
kubectl logs -n kube-system -l k8s-app=calico-node --prefix=true \
  | grep -i "bgp\|bird\|established" | tail -20
```

Estado esperado:
```
NAME                READY   STATUS    RESTARTS   AGE
calico-node-c8w78   1/1     Running   0          Xm
calico-node-dt4lj   1/1     Running   0          Xm
calico-node-swvrd   1/1     Running   0          Xm
```

### 2.5 Puerto BGP en AWS Security Groups

Calico usa **TCP puerto 179** para establecer sesiones BGP entre nodos. Este puerto debe estar abierto en las reglas de entrada (Inbound) del Security Group entre todos los nodos del clúster:

```
Inbound Rules → Add Rule:
  Type:       Custom TCP
  Protocol:   TCP
  Port:       179
  Source:     [SG de los nodos / CIDR de la subred privada]
```

Sin esta regla, BIRD (el demonio BGP de Calico) nunca establece las sesiones y los pods quedan en `0/1` indefinidamente.

---

## 3. Clúster Kubernetes con kubeadm

### 3.1 Descripción del clúster

El clúster se despliega con **kubeadm** sobre tres instancias EC2 de AWS con Ubuntu. La topología es:

- **1 nodo Master (Control Plane):** gestiona el estado del clúster a través de la API de Kubernetes.
- **1 nodo Submaster:** ejecuta pods de aplicación e Ingress Controller; tiene Elastic IP pública.
- **1 nodo Worker2:** ejecuta pods de aplicación adicionales.

### 3.2 Rango de NodePorts ampliado

Por defecto, Kubernetes solo permite NodePorts en el rango `30000-32767`. Para que el Ingress Controller escuche directamente en los puertos estándar 80 y 443, es necesario ampliar este rango en el kube-apiserver.

**¿Por qué usar puertos 80/443 directamente en lugar de NodePorts altos?**

Con puertos altos como 32690/30694, el tráfico de Internet que llega al puerto 80/443 (estándar HTTP/HTTPS) no se reenvía automáticamente. La solución con iptables DNAT o REDIRECT no funciona de forma fiable en AWS debido a cómo la infraestructura gestiona las Elastic IPs: el NAT 1:1 de AWS ocurre en la infraestructura de red antes de que el paquete llegue al kernel del nodo, por lo que el paquete ya llega con la IP privada como destino y las reglas PREROUTING no tienen el efecto esperado.

La solución definitiva es ampliar el rango de NodePorts para incluir el 80 y el 443:

```bash
# Editar el manifiesto del apiserver (static pod)
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml

# Añadir el argumento (debe quedar con el formato de lista YAML correcto):
#    - --service-node-port-range=80-32767
#    - --service-cluster-ip-range=10.96.0.0/12   ← asegurarse de que el "- " esté presente
```

> El `sed` puede corromper el formato YAML si no se aplica con cuidado. Verificar siempre con `sudo grep -A3 'node-port-range' /etc/kubernetes/manifests/kube-apiserver.yaml` que ambas líneas tienen el prefijo `    - `.

El apiserver es un static pod gestionado por kubelet — se reinicia automáticamente al detectar el cambio en el manifiesto. Esperar ~30 segundos y verificar:

```bash
watch sudo crictl ps | grep apiserver
kubectl get nodes
```

Una vez que el apiserver vuelve, cambiar los NodePorts del servicio de ingress-nginx:

```bash
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type='json' -p='[
  {"op": "replace", "path": "/spec/ports/0/nodePort", "value": 80},
  {"op": "replace", "path": "/spec/ports/1/nodePort", "value": 443}
]'

kubectl get svc -n ingress-nginx
# Resultado esperado: 80:80/TCP,443:443/TCP
```

### 3.3 Verificación del estado del clúster

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
NAME            STATUS   ROLES           AGE    VERSION    INTERNAL-IP
k8s-master      Ready    control-plane   Xd     v1.30.14   10.0.1.118
k8s-submaster   Ready    <none>          Xd     v1.30.14   10.0.1.106
worker2         Ready    <none>          Xd     v1.30.14   10.0.1.x
```

<div align="center">
  <img src="../../media/kubectl_get_nodes_wide.png" alt="Output de kubectl nodes" />
</div>

---

## 4. Ingress Controller

El **Ingress Controller de NGINX** gestiona el enrutamiento del tráfico HTTP/HTTPS entrante dentro del clúster. Corre como un pod en el nodo submaster y escucha directamente en los puertos 80 y 443.

### 4.1 Tipo de servicio: NodePort

El servicio de ingress-nginx usa tipo `NodePort` (no `LoadBalancer`) porque en AWS sin el AWS Load Balancer Controller instalado, un servicio de tipo `LoadBalancer` queda en estado `EXTERNAL-IP: <pending>` indefinidamente — nunca obtiene una IP externa asignada automáticamente.

```bash
kubectl get svc -n ingress-nginx
# NAME                       TYPE       CLUSTER-IP      PORT(S)
# ingress-nginx-controller   NodePort   10.102.169.15   80:80/TCP,443:443/TCP
```

### 4.2 Verificar estado

```bash
kubectl get pods -n ingress-nginx -o wide
kubectl get svc -n ingress-nginx
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --tail=20
```

### 4.3 Recurso Ingress de la aplicación

El recurso Ingress define las reglas de enrutamiento y la referencia al certificado TLS:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: meu-project-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-cookie-flags: "~ Secure;SameSite=None"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Ssl on;
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
            name: <nombre-del-service>
            port:
              number: 80
```

### 4.4 Anotaciones del Ingress y su impacto

| Anotación | Valor | Justificación |
|-----------|-------|---------------|
| `cert-manager.io/cluster-issuer` | `letsencrypt-prod` | Indica a cert-manager que gestione el certificado automáticamente |
| `ssl-redirect` | `"true"` | Redirige HTTP → HTTPS automáticamente |
| `proxy-cookie-flags` | `~ Secure;SameSite=None` | Necesario para apps como phpMyAdmin que usan cookies de sesión; sin esto aparece el error "Failed to set session cookie" |
| `configuration-snippet` | `X-Forwarded-Proto: https` | Informa al backend que la conexión original era HTTPS, evitando que phpMyAdmin y otras apps detecten que llegan por HTTP y rechacen las cookies |

**¿Por qué son necesarios los headers X-Forwarded?**

El Ingress Controller termina el TLS y reenvía el tráfico al pod en HTTP plano. Aplicaciones como phpMyAdmin detectan que el protocolo es HTTP y configuran las cookies sin el flag `Secure`, lo que provoca el error "Failed to set session cookie. Maybe you are using HTTP instead of HTTPS". Los headers `X-Forwarded-Proto` y `X-Forwarded-Ssl` le informan a la aplicación que el cliente original usó HTTPS.

<div align="center">
  <img src="../../media/kubectl_describe_ingress.png" alt="Output de kubectl describe ingress" />
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
kubectl -n cert-manager get deployment cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Pods esperados en el namespace `cert-manager`:

| Pod | Función |
|-----|---------|
| `cert-manager-*` | Controlador principal — gestiona el ciclo de vida de los certificados |
| `cert-manager-cainjector-*` | Inyector de CA — inyecta datos de la CA en los webhooks |
| `cert-manager-webhook-*` | Webhook de validación — valida los recursos CRD de cert-manager |

### 5.2 ClusterIssuer — Let's Encrypt Producción

El `ClusterIssuer` define la autoridad certificadora (Let's Encrypt) y el método de validación del dominio. Se usa `ClusterIssuer` (en lugar de `Issuer`) para que sea válido en todos los namespaces del clúster, lo cual es esencial en una plataforma SaaS multi-tenant donde cada cliente tiene su propio namespace.

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

### 5.3 Limitación crítica: wildcards requieren DNS-01

El método HTTP-01 **no puede validar certificados wildcard** (`*.meu-project.me`). Esta es una restricción del protocolo ACME de Let's Encrypt, no una limitación de cert-manager.

Para certificados wildcard se requiere el método **DNS-01**, que valida la propiedad del dominio creando un registro TXT en el DNS en lugar de servir un token HTTP. DNS-01 requiere que cert-manager tenga acceso a la API del proveedor DNS (Route53, Cloudflare, Namecheap, etc.) para crear y eliminar registros automáticamente.

**Estrategia actual:** cada subdominio de cliente usa su propio `Certificate` individual con HTTP-01. Esto funciona correctamente y escala bien para la plataforma SaaS actual.

### 5.4 DNS: registro wildcard en Namecheap

Para que todos los subdominios de clientes resuelvan a la IP del submaster, se configura un único registro wildcard en Namecheap Advanced DNS:

```
Type: A Record
Host: *
Value: 18.235.39.46
TTL: Automatic
```

Este registro cubre `*.meu-project.me`, por lo que cualquier subdominio nuevo de cliente resolverá automáticamente sin necesidad de añadir registros individuales. El registro raíz `meu-project.me` tiene también su propio registro A apuntando a `18.235.39.46`.

> El registro `meu-project.me` (raíz) debe apuntar a `18.235.39.46` (submaster, donde corre ingress-nginx), NO a `54.144.217.31` (master). Si el dominio raíz apunta al master, Let's Encrypt intentará validar el challenge HTTP-01 contra el master, que no tiene el Ingress Controller, y el certificado fallará con error de timeout.

### 5.5 Recurso Certificate por cliente

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: testapi-tls
  namespace: cliente-testapi
spec:
  secretName: testapi-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - testapi.meu-project.me
```

```bash
# Monitorizar el proceso de emisión en tiempo real
kubectl get certificate -A -w

# Ver todos los recursos relacionados
kubectl get certificate,certificaterequest,order,challenge -A
```

### 5.6 Flujo completo del challenge HTTP-01

Cuando se crea el recurso `Certificate`, cert-manager ejecuta automáticamente el siguiente proceso:

```
┌─────────────────────────────────────────────────────────────────┐
│                  FLUJO DE EMISIÓN DEL CERTIFICADO               │
│                                                                 │
│  1. Certificate (recurso creado con kubectl apply)              │
│           │                                                     │
│           ▼                                                     │
│  2. CertificateRequest (cert-manager genera CSR)                │
│           │                                                     │
│           ▼                                                     │
│  3. Order (petición ACME a Let's Encrypt)                       │
│           │                                                     │
│           ▼                                                     │
│  4. Challenge HTTP-01                                           │
│     cert-manager despliega un pod temporal que sirve el token   │
│                                                                 │
│     Ruta de verificación:                                       │
│     Let's Encrypt                                               │
│       → GET http://<dominio>/.well-known/acme-challenge/<token> │
│       → IP pública submaster (18.235.39.46) puerto 80           │
│       → Ingress NGINX Controller                                │
│       → Pod temporal de cert-manager                            │
│       → Responde con el token de validación                     │
│           │                                                     │
│           ▼                                                     │
│  5. Let's Encrypt valida el token → Certificado emitido         │
│           │                                                     │
│           ▼                                                     │
│  6. Secret "<nombre>-tls" creado en Kubernetes                  │
│     Contiene: tls.crt y tls.key en base64                       │
└─────────────────────────────────────────────────────────────────┘
```

```bash
# Ver el progreso del challenge
kubectl get challenge -A
kubectl describe challenge -n <namespace> <nombre-challenge>

# Una vez completado (no deben quedar challenges pendientes)
kubectl get challenge -A
# Resultado esperado: todos en estado "valid" o sin recursos

# Verificar el Certificate y el Secret resultante
kubectl get certificate -A
kubectl get secret <nombre>-tls -n <namespace>
```

Estado final esperado:
```
NAMESPACE        NAME           READY   SECRET         AGE
cliente-testapi  testapi-tls    True    testapi-tls    Xm
```

### 5.7 Renovación automática

Los certificados de Let's Encrypt tienen una **validez de 90 días**. cert-manager los renueva automáticamente cuando quedan **30 días para la expiración**.

```bash
# Ver la fecha de expiración del certificado actual
kubectl get certificate meu-project-tls -n default \
  -o jsonpath='{.status.notAfter}' && echo

# Estado detallado con fechas
kubectl describe certificate meu-project-tls -n default \
  | grep -E "Not After|Renewal|Ready"

# Forzar una renovación manual (si fuera necesario)
kubectl delete certificaterequest -n default \
  $(kubectl get certificaterequest -n default -o name)
```

---

## 6. phpMyAdmin

phpMyAdmin se despliega en el namespace `default` y se expone mediante un Ingress con restricción de acceso por IP y soporte HTTPS completo.

### 6.1 Configuración del Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: phpmyadmin-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-cookie-flags: "~ Secure;SameSite=None"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Ssl on;
    # Opcional: restringir acceso por IP
    # nginx.ingress.kubernetes.io/whitelist-source-range: "TU_IP/32"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - pma.meu-project.me
    secretName: pma-tls
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

**¿Por qué son necesarias las anotaciones de cookie?**

phpMyAdmin requiere cookies de sesión con el flag `Secure` para funcionar sobre HTTPS. Como el Ingress termina el TLS y reenvía HTTP al pod, phpMyAdmin detecta que la conexión entrante es HTTP y no establece el flag `Secure` en las cookies, produciendo el error "Failed to set session cookie". Las anotaciones `proxy-cookie-flags` y `configuration-snippet` corrigen este comportamiento.

### 6.2 Whitelist por IP (opcional)

Para restringir el acceso a phpMyAdmin solo desde IPs de administración:

```bash
# Añadir restricción por IP
kubectl annotate ingress phpmyadmin-ingress -n default \
  nginx.ingress.kubernetes.io/whitelist-source-range="TU_IP/32" \
  --overwrite

# Eliminar restricción (acceso abierto)
kubectl annotate ingress phpmyadmin-ingress -n default \
  nginx.ingress.kubernetes.io/whitelist-source-range- 

# Actualizar IP si cambia (AWS Academy reinicia las IPs)
kubectl annotate ingress phpmyadmin-ingress -n default \
  nginx.ingress.kubernetes.io/whitelist-source-range="NUEVA_IP/32" \
  --overwrite
```

> En AWS Academy, la IP pública del master puede cambiar en cada sesión. Verificar la IP actual antes de añadir la whitelist con `curl -s https://checkip.amazonaws.com` desde el nodo master.

### 6.3 Recuperar credenciales de MariaDB

```bash
kubectl get secret mariadb-credentials -n default \
  -o jsonpath='{.data.MARIADB_ROOT_PASSWORD}' | base64 -d && echo ""
kubectl get secret mariadb-credentials -n default \
  -o jsonpath='{.data.MARIADB_USER}' | base64 -d && echo ""
kubectl get secret mariadb-credentials -n default \
  -o jsonpath='{.data.MARIADB_PASSWORD}' | base64 -d && echo ""
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
| Nodos K8s | `kubectl get nodes` | Todos `Ready` |
| Calico | `kubectl get pods -n kube-system -l k8s-app=calico-node` | `1/1 Running` en cada nodo |
| Ingress Controller | `kubectl get pods -n ingress-nginx` | `1/1 Running` |
| Servicio Ingress | `kubectl get svc -n ingress-nginx` | `NodePort 80:80/TCP,443:443/TCP` |
| cert-manager | `kubectl get pods -n cert-manager` | 3 pods `1/1 Running` |
| ClusterIssuer | `kubectl get clusterissuer` | `READY: True` |
| Certificates | `kubectl get certificate -A` | Todos `READY: True` |
| HTTP redirect | `curl -I http://meu-project.me/` | `301 Moved Permanently` |
| HTTPS respuesta | `curl -I https://meu-project.me/` | `200 OK` |

> 📸 **[CAPTURA SUGERIDA]** Navegador mostrando `https://meu-project.me/` con el candado verde activado y, al hacer clic en él, los detalles del certificado TLS: emisor `Let's Encrypt`, dominio `meu-project.me` y fecha de expiración.

---

## 8. Recuperación de credenciales

### 8.1 MariaDB

```bash
# Ver las keys disponibles
kubectl describe secret mariadb-credentials -n default

# Extraer credenciales
kubectl get secret mariadb-credentials -n default \
  -o jsonpath='{.data.MARIADB_ROOT_PASSWORD}' | base64 -d && echo ""
kubectl get secret mariadb-credentials -n default \
  -o jsonpath='{.data.MARIADB_USER}' | base64 -d && echo ""
kubectl get secret mariadb-credentials -n default \
  -o jsonpath='{.data.MARIADB_PASSWORD}' | base64 -d && echo ""
```

### 8.2 Grafana

```bash
# Ver las keys disponibles
kubectl describe secret grafana -n monitoring

# Extraer credenciales
kubectl get secret grafana -n monitoring \
  -o jsonpath='{.data.admin-user}' | base64 -d && echo ""
kubectl get secret grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo ""
```

---

## 9. Troubleshooting

### 9.1 Tabla resumen de incidencias

| Síntoma | Causa probable | Diagnóstico | Solución |
|---------|---------------|-------------|----------|
| Calico en `Init:CrashLoopBackOff` | Init container no alcanza API (sin CNI activo) | `kubectl logs -n kube-system <pod> -c install-cni` | Pre-crear kubeconfig en `/etc/cni/net.d/calico-kubeconfig` |
| Calico en `0/1` tras 90s | BGP no establecido / puerto 179 bloqueado | `kubectl logs -n kube-system <pod> -c calico-node` | Abrir TCP 179 en Security Group entre nodos |
| `connection refused` en puerto 80 desde Internet | Puertos 80/443 no en NodePort range | `curl http://18.235.39.46:32690` | Ampliar `--service-node-port-range=80-32767` en kube-apiserver |
| `EXTERNAL-IP: <pending>` en ingress-nginx | LoadBalancer sin AWS LB Controller | `kubectl get svc -n ingress-nginx` | Cambiar tipo a `NodePort` |
| Challenge HTTP-01 en `invalid` | DNS apunta a IP incorrecta / puerto 80 no accesible | `kubectl describe challenge -n <ns> <name>` | Corregir DNS y verificar acceso al puerto 80 |
| Challenge wildcard en `pending` indefinido | HTTP-01 no soporta wildcards | `kubectl describe order -n default` | Usar certificados individuales por dominio |
| `403 Forbidden` en phpMyAdmin | Whitelist IP activa con IP diferente | `kubectl get ingress phpmyadmin-ingress -n default -o yaml` | Actualizar o eliminar `whitelist-source-range` |
| `Failed to set session cookie` en phpMyAdmin | Falta `X-Forwarded-Proto` header | Logs del pod phpMyAdmin | Añadir anotaciones `proxy-cookie-flags` y `configuration-snippet` |
| `ERR_CERT_AUTHORITY_INVALID` | Secret con certificado autofirmado antiguo | `kubectl get secret <tls-secret> -o yaml \| grep tls.crt \| base64 -d \| openssl x509 -noout -issuer` | Borrar secret y certificate para regenerar |
| API Server caído tras editar kube-apiserver.yaml | Error de sintaxis YAML en el manifiesto | `sudo crictl ps \| grep apiserver` | Verificar formato YAML con `sudo grep -A3 'node-port' /etc/kubernetes/manifests/kube-apiserver.yaml` |

### 9.2 API Server caído — `connection refused` en puerto 6443

**Síntoma:**
```
The connection to the server 10.0.1.118:6443 was refused
```

**Diagnóstico:**
```bash
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 30 --no-pager | grep -E "error|Error|failed|Failed"
sudo crictl ps | grep apiserver
```

#### 9.2.1 Error de formato en kube-apiserver.yaml

**Causa:** El `sed` para añadir `--service-node-port-range` corrompe el formato YAML eliminando el prefijo `- ` de la línea siguiente.

**Verificación:**
```bash
sudo grep -A3 'node-port-range' /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Debe verse:**
```yaml
    - --service-node-port-range=80-32767
    - --service-cluster-ip-range=10.96.0.0/12
```

**Corrección si falta el `- `:**
```bash
sudo sed -i 's/^    --service-cluster-ip-range/    - --service-cluster-ip-range/' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

#### 9.2.2 `kubelet-client-current.pem` no existe

**Error en logs:**
```
unable to read client-cert /var/lib/kubelet/pki/kubelet-client-current.pem
```

**Solución:**
```bash
sudo bash -c 'cat /etc/kubernetes/pki/apiserver-kubelet-client.crt \
                  /etc/kubernetes/pki/apiserver-kubelet-client.key \
              > /var/lib/kubelet/pki/kubelet-client-current.pem'
sudo chmod 600 /var/lib/kubelet/pki/kubelet-client-current.pem
sudo systemctl restart kubelet
sleep 15
kubectl get nodes
```

#### 9.2.3 Prevención — servicio de recuperación automática

```bash
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

### 9.3 Ingress Controller no responde

```bash
kubectl get pods -n ingress-nginx -o wide
kubectl logs -n ingress-nginx \
  $(kubectl get pods -n ingress-nginx -o name | head -1) --tail 30
kubectl get endpoints -n default
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
kubectl get pods -n ingress-nginx -w
```

### 9.4 Certificado TLS — `ERR_CERT_AUTHORITY_INVALID`

**Causa:** El Secret TLS contiene un certificado autofirmado antiguo en lugar del de Let's Encrypt.

**Diagnóstico:**
```bash
kubectl get secret meu-project-tls -n default \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates -issuer
# El issuer debe decir "Let's Encrypt", no "kubernetes" ni una CA propia
```

**Solución:**
```bash
kubectl delete secret meu-project-tls -n default
kubectl delete certificate meu-project-tls -n default
# cert-manager lo regenera automáticamente en ~1 minuto
```

Limpiar caché del navegador con `Ctrl+Shift+R` o verificar en incógnito.

---

## 10. Apéndices

### Apéndice A: Referencia de puertos

| Puerto | Protocolo | Componente | Descripción |
|--------|-----------|------------|-------------|
| **80** | TCP | Ingress NGINX (NodePort) | HTTP público; redirige a HTTPS excepto ruta ACME |
| **443** | TCP | Ingress NGINX (NodePort) | HTTPS público; termina TLS con cert Let's Encrypt |
| **179** | TCP | Calico BGP | Sesiones BGP entre nodos (debe estar abierto en SG) |
| **6443** | TCP | kube-apiserver | API de Kubernetes (control plane) |
| **10250** | TCP | kubelet | Comunicación interna entre nodos del clúster |

### Apéndice B: Script de diagnóstico rápido

```bash
#!/bin/bash
# diagnostico-stack.sh — Verifica el estado de todos los componentes del stack

echo "=== KUBERNETES NODOS ==="
kubectl get nodes -o wide

echo ""
echo "=== CALICO CNI ==="
kubectl get pods -n kube-system -l k8s-app=calico-node

echo ""
echo "=== INGRESS NGINX ==="
kubectl get pods -n ingress-nginx -o wide
kubectl get svc -n ingress-nginx

echo ""
echo "=== CERT-MANAGER ==="
kubectl get pods -n cert-manager
kubectl get clusterissuer

echo ""
echo "=== CERTIFICADOS (solo los no Ready) ==="
kubectl get certificate -A | grep -v "True"

echo ""
echo "=== CHALLENGES PENDIENTES ==="
kubectl get challenge -A

echo ""
echo "=== CONECTIVIDAD ==="
echo -n "HTTP  (esperado 301): "; curl -s -o /dev/null -w "%{http_code}\n" http://meu-project.me/
echo -n "HTTPS (esperado 200): "; curl -s -o /dev/null -w "%{http_code}\n" https://meu-project.me/

echo ""
echo "=== CERTIFICADO SSL EN PRODUCCIÓN ==="
echo | openssl s_client -connect meu-project.me:443 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

### Apéndice C: Ficheros de configuración clave

| Recurso | Namespace | Descripción |
|---------|-----------|-------------|
| `calico-kubeconfig` | `/etc/cni/net.d/` (en cada nodo) | Kubeconfig para el init container de Calico |
| `kube-apiserver.yaml` | `/etc/kubernetes/manifests/` | Manifiesto del static pod del API Server |
| `mariadb-credentials` | `default` | Secret con credenciales de MariaDB |
| `grafana` | `monitoring` | Secret con credenciales de Grafana |
| `letsencrypt-prod` | ClusterIssuer | Configuración del emisor ACME |
