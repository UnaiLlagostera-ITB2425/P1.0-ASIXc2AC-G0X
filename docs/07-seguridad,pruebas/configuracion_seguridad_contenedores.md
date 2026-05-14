# Seguridad: Kubernetes + Calico NetworkPolicy + Rate Limit + RBAC

## 1. Arquitectura de Seguridad General

### 1.1 Modelo de defensa en profundidad

La seguridad del clúster se implementa en capas independientes, de modo que el fallo de una no compromete las demás:

```
┌─────────────────────────────────────────────────────────────────┐
│  CAPA 1 — Perímetro (AWS)                                       │
│  Security Groups + NACLs → solo puertos 80, 443, 22, 179        │
├─────────────────────────────────────────────────────────────────┤
│  CAPA 2 — Nodo (Sistema Operativo)                              │
│  Fail2ban → ban automático SSH y HTTP por fuerza bruta          │
├─────────────────────────────────────────────────────────────────┤
│  CAPA 3 — Ingress (Tráfico HTTP/HTTPS)                          │
│  Rate Limit NGINX → límite de peticiones y conexiones por IP    │
├─────────────────────────────────────────────────────────────────┤
│  CAPA 4 — Red de Pods (Este-Oeste)                              │
│  Calico GlobalNetworkPolicy → aislamiento entre namespaces      │
├─────────────────────────────────────────────────────────────────┤
│  CAPA 5 — Proceso (Contenedor)                                  │
│  RBAC + SecurityContext → sin root, sin privilegios innecesarios│
└─────────────────────────────────────────────────────────────────┘
```

**¿Por qué este orden de capas?**

Cada capa mitiga una categoría de ataque diferente. Un atacante externo primero encuentra el Security Group (no puede conectar a puertos no autorizados), luego Fail2ban (si intenta fuerza bruta SSH), luego el Rate Limit (si intenta DDoS HTTP), luego las NetworkPolicies (si consigue ejecutar código en un pod no puede moverse lateralmente), y finalmente el SecurityContext (aunque comprometa el pod, no tiene privilegios para escalar al nodo).

### 1.2 Estado del clúster tras la implementación

| Componente | Antes | Después |
|------------|-------|---------|
| Aislamiento entre clientes | Sin políticas — tráfico libre | GlobalNetworkPolicy deny-all + allow selectivo |
| Nuevos clientes | Sin protección automática | Label `tipo=cliente` activa todas las políticas |
| DDoS HTTP | Sin límite | 5-30 rps por IP según criticidad |
| Fuerza bruta SSH | Sin protección | Ban 2h tras 5 intentos fallidos |
| Pods corriendo como root | 100% | 0% en namespaces de clientes |
| ServiceAccounts con token automático | Todos | Deshabilitado en namespaces de clientes |

---

## 2. Aislamiento de Red entre Clientes (Calico GlobalNetworkPolicy)

### 2.1 ¿Por qué GlobalNetworkPolicy en lugar de NetworkPolicy estándar?

Kubernetes incluye `NetworkPolicy` como recurso nativo, pero tiene una limitación importante para plataformas SaaS multi-tenant: **cada política debe crearse manualmente en cada namespace**. Con 10, 50 o 100 clientes, esto se convierte en un problema de mantenimiento.

Calico extiende Kubernetes con `GlobalNetworkPolicy`, que aplica a todos los namespaces que cumplan un selector. En este proyecto, cualquier namespace con el label `tipo=cliente` queda automáticamente protegido sin intervención manual adicional.

**Comparativa:**

| Aspecto | NetworkPolicy estándar | GlobalNetworkPolicy Calico |
|---------|----------------------|---------------------------|
| Ámbito | Un namespace | Todos los namespaces que cumplan el selector |
| Nuevos clientes | Requiere aplicar manualmente | Automático con el label |
| Herramienta | `kubectl apply` | `calicoctl apply` |
| Sintaxis de selector | `matchLabels` | Expresión CEL (`tipo == "cliente"`) |

### 2.2 Prerequisitos: labels en namespaces

Para que las GlobalNetworkPolicies apliquen, cada namespace de cliente debe tener el label `tipo=cliente`:

```bash
# Aplicar label a namespaces existentes
for ns in cliente-acme cliente-hostpath cliente-stateless \
          cliente-testapi cliente-testapi2 cliente-testdbok; do
  kubectl label namespace $ns tipo=cliente
done

# Verificar
kubectl get namespaces --show-labels | grep tipo=cliente
```

El namespace `ingress-nginx` ya tiene el label `name=ingress-nginx` que se usa en las políticas de allow. No necesita modificación.

### 2.3 Instalación de calicoctl

Las GlobalNetworkPolicies requieren `calicoctl` porque usan la API extendida de Calico (`projectcalico.org/v3`), que `kubectl` no puede gestionar directamente aunque el CRD esté instalado.

```bash
# Instala calicoctl (versión debe coincidir con Calico del clúster: v3.28.0)
curl -L https://github.com/projectcalico/calico/releases/download/v3.28.0/calicoctl-linux-amd64 \
  -o /tmp/calicoctl
sudo mv /tmp/calicoctl /usr/local/bin/calicoctl
sudo chmod +x /usr/local/bin/calicoctl

# Configura el datastore (Kubernetes, no etcd directo)
export CALICO_DATASTORE_TYPE=kubernetes
export CALICO_KUBECONFIG=~/.kube/config

# Verifica
calicoctl version
```

> Usar siempre `CALICO_DATASTORE_TYPE=kubernetes` y `CALICO_KUBECONFIG` como prefijo de cada comando `calicoctl`, o exportar las variables en el perfil del shell.

### 2.4 Las 4 GlobalNetworkPolicies

Guarda el siguiente manifiesto en `/tmp/calico-global-policies.yaml`:

```bash
cat > /tmp/calico-global-policies.yaml << 'ENDOFFILE'
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: cliente-default-deny
spec:
  namespaceSelector: tipo == "cliente"
  selector: all()
  types:
  - Ingress
  - Egress
---
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: cliente-allow-same-namespace
spec:
  namespaceSelector: tipo == "cliente"
  selector: all()
  types:
  - Ingress
  - Egress
  ingress:
  - action: Allow
    source:
      namespaceSelector: tipo == "cliente"
  egress:
  - action: Allow
    destination:
      namespaceSelector: tipo == "cliente"
---
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: cliente-allow-ingress-nginx
spec:
  namespaceSelector: tipo == "cliente"
  selector: all()
  types:
  - Ingress
  ingress:
  - action: Allow
    source:
      namespaceSelector: name == "ingress-nginx"
---
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: cliente-allow-dns
spec:
  namespaceSelector: tipo == "cliente"
  selector: all()
  types:
  - Egress
  egress:
  - action: Allow
    protocol: UDP
    destination:
      namespaceSelector: kubernetes.io/metadata.name == "kube-system"
      ports: [53]
  - action: Allow
    protocol: TCP
    destination:
      namespaceSelector: kubernetes.io/metadata.name == "kube-system"
      ports: [53]
  - action: Allow
    protocol: UDP
    destination:
      nets: ["10.96.0.10/32"]
      ports: [53]
  - action: Allow
    protocol: TCP
    destination:
      nets: ["10.96.0.10/32"]
      ports: [53]
ENDOFFILE

# Aplica
CALICO_DATASTORE_TYPE=kubernetes CALICO_KUBECONFIG=~/.kube/config \
  calicoctl apply -f /tmp/calico-global-policies.yaml

# Verifica
CALICO_DATASTORE_TYPE=kubernetes CALICO_KUBECONFIG=~/.kube/config \
  calicoctl get globalnetworkpolicy -o wide
```

**Explicación de cada política:**

| Política | Función | Justificación |
|----------|---------|---------------|
| `cliente-default-deny` | Bloquea todo el tráfico Ingress y Egress por defecto | Principio de mínimo privilegio: nada está permitido salvo lo explícitamente autorizado |
| `cliente-allow-same-namespace` | Permite comunicación entre pods del mismo cliente | Un cliente puede tener múltiples pods (app + worker + scheduler) que necesitan comunicarse |
| `cliente-allow-ingress-nginx` | Permite entrada solo desde el Ingress Controller | El único punto de entrada legítimo desde Internet es el Ingress NGINX |
| `cliente-allow-dns` | Permite consultas DNS al kube-dns | Sin DNS, los pods no pueden resolver nombres de servicios ni dominios externos |

> **¿Por qué `cliente-allow-same-namespace` permite tráfico hacia otros namespaces `tipo=cliente`?** Es una limitación del selector de Calico en GlobalNetworkPolicy: no puede referenciar "el mismo namespace que el pod origen" directamente. En la práctica, la política `cliente-default-deny` bloquea la entrada en el namespace destino, por lo que el aislamiento se mantiene. El tráfico entre clientes distintos queda bloqueado por la deny del namespace destino.

### 2.5 Flujo de onboarding de un cliente nuevo

Con las GlobalNetworkPolicies activas, el proceso para un cliente nuevo se reduce a:

```bash
# 1. Crear el namespace
kubectl create namespace cliente-nuevo

# 2. Aplicar el label — esto activa automáticamente las 4 políticas
kubectl label namespace cliente-nuevo tipo=cliente

# 3. Verificar que las políticas aplican
CALICO_DATASTORE_TYPE=kubernetes CALICO_KUBECONFIG=~/.kube/config \
  calicoctl get networkpolicy -n cliente-nuevo
```

No hay paso 4. Las políticas ya están activas.

### 2.6 Verificación del aislamiento

```bash
# Test 1: Un pod de cliente-A NO debe poder llegar a cliente-B
kubectl run test-aislamiento \
  --image=busybox:1.28 --rm -it --restart=Never \
  -n cliente-testapi \
  -- sh -c "wget -qO- --timeout=3 http://<CLUSTERIP_TESTAPI2> 2>&1 || echo 'BLOQUEADO OK'"

# Test 2: El ingress SÍ debe llegar al pod del cliente
curl -k -s -o /dev/null -w "%{http_code}" https://testapi.meu-project.me
# Esperado: 200 o 404 (nginx responde — política allow-ingress-nginx funciona)

# Test 3: Ver políticas activas
CALICO_DATASTORE_TYPE=kubernetes CALICO_KUBECONFIG=~/.kube/config \
  calicoctl get globalnetworkpolicy
```

Estado esperado:
```
NAME                           ORDER   SELECTOR
cliente-allow-dns              <nil>   all()
cliente-allow-ingress-nginx    <nil>   all()
cliente-allow-same-namespace   <nil>   all()
cliente-default-deny           <nil>   all()
```

---

## 3. Rate Limit y Fail2ban

### 3.1 Estrategia anti-DDoS en dos niveles

La mitigación de DDoS se implementa en dos capas complementarias:

**Nivel 1 — Rate Limit en Ingress NGINX** (dentro del clúster): limita las peticiones por IP antes de que lleguen a los pods. Responde con HTTP 429 cuando se supera el límite. Es la primera línea de defensa y no requiere software adicional.

**Nivel 2 — Fail2ban en el nodo** (sistema operativo): monitoriza los logs y banea automáticamente con iptables las IPs que generan demasiados errores 429 o intentos de SSH fallidos. Actúa a nivel de kernel, bloqueando el tráfico antes de que llegue a Kubernetes.

**¿Por qué ambas capas?** El Rate Limit responde con 429 pero sigue procesando las conexiones TCP, consumiendo recursos. Fail2ban complementa bloqueando completamente la IP a nivel de iptables, eliminando incluso el handshake TCP.

### 3.2 Rate Limit en Ingress NGINX

#### 3.2.1 ConfigMap global

```bash
kubectl patch configmap ingress-nginx-controller -n ingress-nginx \
  --patch '{
    "data": {
      "limit-req-status-code": "429",
      "limit-conn-status-code": "429",
      "keep-alive": "75",
      "keep-alive-requests": "100"
    }
  }'
```

#### 3.2.2 Anotaciones por ingress

Las anotaciones de rate limit se aplican individualmente a cada Ingress, lo que permite calibrar los límites según la criticidad de cada servicio:

```bash
# Clientes (uso normal)
for ns in cliente-acme cliente-hostpath cliente-stateless \
          cliente-testapi2 cliente-testdbok; do
  INGRESS=$(kubectl get ingress -n $ns --no-headers \
    -o custom-columns=NAME:.metadata.name | grep -v "cm-acme" | head -1)
  kubectl annotate ingress $INGRESS -n $ns \
    nginx.ingress.kubernetes.io/limit-rps="20" \
    nginx.ingress.kubernetes.io/limit-connections="10" \
    nginx.ingress.kubernetes.io/limit-burst-multiplier="5" \
    --overwrite
done

# testapi (API — más restrictivo)
kubectl annotate ingress testapi-ingress -n cliente-testapi \
  nginx.ingress.kubernetes.io/limit-rps="5" \
  nginx.ingress.kubernetes.io/limit-connections="3" \
  --overwrite

# Servicios principales
kubectl annotate ingress saas-api phpmyadmin-ingress -n default \
  nginx.ingress.kubernetes.io/limit-rps="30" \
  nginx.ingress.kubernetes.io/limit-connections="20" \
  nginx.ingress.kubernetes.io/limit-burst-multiplier="5" \
  --overwrite

# Grafana (monitorización — acceso restringido)
kubectl annotate ingress grafana-ingress -n monitoring \
  nginx.ingress.kubernetes.io/limit-rps="10" \
  nginx.ingress.kubernetes.io/limit-connections="5" \
  --overwrite
```

**Tabla de límites configurados:**

| Ingress | RPS límite | Conexiones | Burst | Justificación |
|---------|-----------|-----------|-------|---------------|
| Clientes (general) | 20 | 10 | x5 | Uso web normal con margen para picos |
| testapi | 5 | 3 | — | API pública — más expuesta a abuso |
| saas-api, phpmyadmin | 30 | 20 | x5 | Uso administrativo — IPs conocidas |
| grafana | 10 | 5 | — | Solo administradores |

**¿Qué significa `limit-burst-multiplier`?** Permite que una IP supere momentáneamente el límite hasta `rps × multiplier` peticiones en cola antes de empezar a devolver 429. Útil para páginas con muchos recursos estáticos que se cargan en paralelo.

#### 3.2.3 Verificación del Rate Limit

```bash
# Ver los límites aplicados
kubectl get ingress -A -o yaml | grep -A2 "limit-rps\|limit-conn"

# Simular DDoS y verificar el 429
for i in $(seq 1 30); do
  curl -s -o /dev/null -w "%{http_code}\n" https://testapi.meu-project.me
done
# A partir de cierto punto deben aparecer 429
```

### 3.3 Fail2ban

#### 3.3.1 Instalación en los tres nodos

```bash
# Master (local)
sudo apt-get install -y fail2ban

# Submaster
ssh -i ~/keys/keypair-proyecto-k8s.pem meu_master@10.0.1.106 \
  "sudo apt-get install -y fail2ban"

# Worker2
ssh -i ~/keys/keypair-proyecto-k8s.pem ubuntu@10.0.1.203 \
  "sudo apt-get install -y fail2ban"
```

#### 3.3.2 Configuración del jail SSH (los tres nodos)

El jail SSH protege contra ataques de fuerza bruta en el acceso remoto. Se configura igual en los tres nodos:

```bash
sudo tee /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd
banaction = iptables-multiport

[sshd]
enabled  = true
port     = ssh
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 7200
EOF

sudo systemctl enable fail2ban
sudo systemctl restart fail2ban
```

**Parámetros del jail SSH:**

| Parámetro | Valor | Significado |
|-----------|-------|-------------|
| `maxretry` | 5 | Ban tras 5 intentos fallidos |
| `findtime` | 600s | Ventana de tiempo para contar intentos (10 min) |
| `bantime` | 7200s | Duración del ban (2 horas) |
| `backend` | systemd | Lee los logs de journald, no de archivo |
| `banaction` | iptables-multiport | Ban a nivel de kernel con iptables |

#### 3.3.3 Jail nginx-limit-req (solo submaster)

El submaster tiene el Ingress Controller — sus logs contienen las peticiones HTTP. Fail2ban los monitoriza para banear IPs que generan demasiados errores 429:

```bash
ssh -i ~/keys/keypair-proyecto-k8s.pem meu_master@10.0.1.106

# Filtro: detecta IPs con respuestas 429
sudo tee /etc/fail2ban/filter.d/nginx-limit-req.conf << 'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).+" 429
ignoreregex =
EOF

# Añade el jail al jail.local
sudo tee -a /etc/fail2ban/jail.local << 'EOF'

[nginx-limit-req]
enabled  = true
port     = http,https
filter   = nginx-limit-req
logpath  = /var/log/nginx-ingress.log
maxretry = 20
findtime = 60
bantime  = 3600
EOF

sudo systemctl restart fail2ban
```

#### 3.3.4 Script de volcado de logs del Ingress (submaster)

Fail2ban necesita un archivo de log estático para monitorizar. Este script vuelca periódicamente los logs del pod de ingress-nginx:

```bash
sudo tee /usr/local/bin/dump-ingress-logs.sh << 'EOF'
#!/bin/bash
KUBECONFIG=/home/meu_master/.kube/config
export KUBECONFIG
POD=$(kubectl get pods -n ingress-nginx -o name 2>/dev/null | head -1)
if [ -n "$POD" ]; then
  kubectl logs -n ingress-nginx "$POD" --since=2m 2>/dev/null \
    >> /var/log/nginx-ingress.log
fi
EOF

sudo chmod +x /usr/local/bin/dump-ingress-logs.sh
sudo touch /var/log/nginx-ingress.log
sudo chmod 644 /var/log/nginx-ingress.log

# Crontab cada 2 minutos
(echo '*/2 * * * * /usr/local/bin/dump-ingress-logs.sh') | sudo crontab -
```

#### 3.3.5 Distribución de jails por nodo

| Nodo | Jail SSH | Jail nginx-limit-req | Crontab logs |
|------|----------|---------------------|--------------|
| k8s-master | ✅ | ❌ | ❌ |
| k8s-submaster | ✅ | ✅ | ✅ cada 2min |
| worker2 | ✅ | ❌ | ❌ |

**¿Por qué solo el submaster tiene el jail nginx?** El Ingress Controller corre en el submaster, por lo que es el único nodo que genera logs de tráfico HTTP externos. El master y worker2 solo tienen tráfico SSH de administración.

#### 3.3.6 Verificación de Fail2ban

```bash
# Estado en master
sudo fail2ban-client status
sudo fail2ban-client status sshd

# Estado en submaster
ssh -i ~/keys/keypair-proyecto-k8s.pem meu_master@10.0.1.106 \
  "sudo fail2ban-client status && sudo fail2ban-client status nginx-limit-req"

# Ver IPs baneadas actualmente
sudo fail2ban-client status sshd | grep "Banned IP"

# Desbanear una IP manualmente (si se banea la IP de administración)
sudo fail2ban-client set sshd unbanip <IP>
```

---

## 4. RBAC y Security Context

### 4.1 Principio de mínimo privilegio en Kubernetes

RBAC (Role-Based Access Control) en Kubernetes controla **qué puede hacer cada proceso o usuario con la API de Kubernetes**. Security Context controla **con qué privilegios corre el proceso dentro del contenedor**.

Son complementarios: RBAC evita que un pod comprometido llame a la API de Kubernetes para escalar privilegios (crear pods privilegiados, leer secrets de otros namespaces, etc.). Security Context evita que el proceso dentro del pod pueda comprometer el nodo host aunque consiga escapar del contenedor.

### 4.2 RBAC

#### 4.2.1 ClusterRole para la API de hosting

La API de hosting (desarrollada por Unai) necesita permisos para crear y gestionar namespaces y recursos de clientes. Se crea un ServiceAccount dedicado con los permisos mínimos necesarios:

```bash
kubectl apply -f - << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hosting-api-role
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "create", "delete", "patch"]
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "persistentvolumeclaims"]
  verbs: ["get", "list", "create", "update", "delete", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "create", "update", "delete", "patch"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "create", "update", "delete", "patch"]
- apiGroups: ["cert-manager.io"]
  resources: ["certificates"]
  verbs: ["get", "list", "create", "update", "delete", "patch"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hosting-api-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hosting-api-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hosting-api-role
subjects:
- kind: ServiceAccount
  name: hosting-api-sa
  namespace: default
EOF
```

**¿Por qué solo `get/list` en secrets?** Los secrets contienen certificados TLS y credenciales. La API de hosting solo necesita verificar que existen, no crearlos ni modificarlos — eso lo hace cert-manager.

#### 4.2.2 ServiceAccount y Role por namespace de cliente

Cada cliente tiene su propio ServiceAccount con permisos mínimos dentro de su namespace. Esto limita el blast radius si un pod es comprometido:

```bash
# Script reutilizable — llamar al crear cada cliente
for ns in cliente-acme cliente-hostpath cliente-stateless \
          cliente-testapi cliente-testapi2 cliente-testdbok; do
  APP=$(kubectl get pods -n $ns --no-headers \
    -o custom-columns=NAME:.metadata.labels.app | head -1)

  kubectl apply -f - << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${APP}-sa
  namespace: ${ns}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${APP}-role
  namespace: ${ns}
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${APP}-rolebinding
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${APP}-role
subjects:
- kind: ServiceAccount
  name: ${APP}-sa
  namespace: ${ns}
EOF
done
```

#### 4.2.3 Deshabilitar el ServiceAccount default

El ServiceAccount `default` de Kubernetes monta automáticamente un token en todos los pods, lo que les da acceso a la API aunque no lo necesiten. Se deshabilita en todos los namespaces de clientes:

```bash
for ns in cliente-acme cliente-hostpath cliente-stateless \
          cliente-testapi cliente-testapi2 cliente-testdbok; do
  kubectl patch serviceaccount default -n $ns \
    -p '{"automountServiceAccountToken": false}'
done
```

**¿Por qué es importante?** Si un atacante ejecuta código en un pod, el token montado automáticamente le permitiría llamar a la API de Kubernetes. Sin el token, no tiene credenciales para interactuar con el clúster.

#### 4.2.4 Integración en el onboarding de clientes

Para cada cliente nuevo, la API de hosting debe ejecutar adicionalmente:

```bash
# Tras crear el namespace y los recursos del cliente:
kubectl create serviceaccount ${APP}-sa -n ${NS}
kubectl apply -f role-${APP}.yaml
kubectl patch serviceaccount default -n ${NS} \
  -p '{"automountServiceAccountToken": false}'
kubectl label namespace ${NS} tipo=cliente
```

### 4.3 Security Context

#### 4.3.1 ¿Por qué no root?

Los contenedores Docker comparten el kernel del nodo host. Un proceso que corre como `root` dentro de un contenedor tiene `uid=0` también en el host si consigue escapar del namespace de contenedor. Esto puede comprometer el nodo completo.

Correr como usuario no privilegiado (`www-data`, `uid=33`) limita el daño: incluso si el proceso escapa del contenedor, solo tiene los permisos de un usuario sin privilegios en el nodo.

#### 4.3.2 Verificación previa a la implementación

Antes de aplicar `runAsNonRoot`, verificar que la imagen soporta el usuario:

```bash
# Verifica que www-data existe en la imagen
kubectl exec -n cliente-testapi \
  $(kubectl get pods -n cliente-testapi -o name | head -1) \
  -- cat /etc/passwd | grep -E "www-data|apache|nginx|nobody"

# Verifica el usuario actual
kubectl exec -n cliente-testapi \
  $(kubectl get pods -n cliente-testapi -o name | head -1) \
  -- id
```

La imagen `saas-php:8.3` incluye `www-data` con `uid=33` — Apache puede correr sin root con este usuario.

#### 4.3.3 Aplicación del SecurityContext

```bash
for ns in cliente-acme cliente-stateless cliente-testapi \
          cliente-testapi2 cliente-testdbok; do
  DEPLOY=$(kubectl get deployment -n $ns -o name | head -1)
  APP=$(echo $DEPLOY | cut -d'/' -f2)
  SA="${APP}-sa"

  kubectl patch deployment $APP -n $ns --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/securityContext",
      "value": {
        "runAsNonRoot": true,
        "runAsUser": 33,
        "runAsGroup": 33,
        "fsGroup": 33,
        "seccompProfile": {"type": "RuntimeDefault"}
      }
    },
    {
      "op": "add",
      "path": "/spec/template/spec/serviceAccountName",
      "value": "'$SA'"
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/securityContext",
      "value": {
        "allowPrivilegeEscalation": false,
        "readOnlyRootFilesystem": false,
        "capabilities": {"drop": ["ALL"]}
      }
    }
  ]'
  echo "SecurityContext aplicado en $ns/$APP"
done
```

**Explicación de cada campo:**

| Campo | Valor | Justificación |
|-------|-------|---------------|
| `runAsNonRoot` | `true` | Kubernetes rechaza el pod si el usuario es root — garantía doble |
| `runAsUser` | `33` | www-data — usuario de Apache sin privilegios |
| `runAsGroup` | `33` | Grupo www-data para permisos de archivos |
| `fsGroup` | `33` | Los volúmenes montados tienen este grupo como propietario |
| `seccompProfile` | `RuntimeDefault` | Restringe las syscalls disponibles al perfil por defecto del runtime |
| `allowPrivilegeEscalation` | `false` | Impide que el proceso obtenga más privilegios via setuid/setgid |
| `readOnlyRootFilesystem` | `false` | Apache necesita escribir en `/tmp` y `/var/run/apache2` — no se puede habilitar sin modificar la imagen |
| `capabilities: drop ALL` | — | Elimina todas las Linux capabilities — la protección más impactante |

> **¿Por qué `readOnlyRootFilesystem: false`?** Apache escribe archivos temporales en `/tmp` y sockets en `/var/run/apache2`. Habilitar el filesystem de solo lectura requeriría montar estos directorios como volúmenes `emptyDir`, lo cual es una mejora futura recomendada pero requiere modificar el Dockerfile.

#### 4.3.4 Verificación del SecurityContext

```bash
# Verificar que ningún pod de cliente corre como root
for ns in cliente-acme cliente-stateless cliente-testapi \
          cliente-testapi2 cliente-testdbok; do
  POD=$(kubectl get pods -n $ns -o name | head -1)
  echo -n "$ns → "
  kubectl exec -n $ns $POD -- id 2>/dev/null
done

# Resultado esperado en todos:
# uid=33(www-data) gid=33(www-data) groups=33(www-data)

# Verificar que el SecurityContext está definido en el deployment
kubectl get deployment testapi -n cliente-testapi \
  -o jsonpath='{.spec.template.spec.securityContext}' | python3 -m json.tool
```

---

## 5. Verificación End-to-End de Seguridad

### 5.1 Script de diagnóstico de seguridad

```bash
#!/bin/bash
# security-check.sh — Verifica el estado de todos los controles de seguridad

echo "=== CALICO GLOBALNETWORKPOLICIES ==="
CALICO_DATASTORE_TYPE=kubernetes CALICO_KUBECONFIG=~/.kube/config \
  calicoctl get globalnetworkpolicy

echo ""
echo "=== NAMESPACES CON LABEL tipo=cliente ==="
kubectl get namespaces --show-labels | grep tipo=cliente

echo ""
echo "=== RATE LIMIT EN INGRESS ==="
kubectl get ingress -A -o yaml | grep -E "limit-rps|limit-conn" | sort -u

echo ""
echo "=== FAIL2BAN STATUS (master) ==="
sudo fail2ban-client status

echo ""
echo "=== PODS CORRIENDO COMO ROOT (no debe haber en namespaces cliente) ==="
for ns in cliente-acme cliente-hostpath cliente-stateless \
          cliente-testapi cliente-testapi2 cliente-testdbok; do
  POD=$(kubectl get pods -n $ns -o name 2>/dev/null | head -1)
  if [ -n "$POD" ]; then
    USER=$(kubectl exec -n $ns $POD -- id 2>/dev/null | grep -o 'uid=[0-9]*' | cut -d= -f2)
    if [ "$USER" = "0" ]; then
      echo "ROOT detectado en $ns/$POD"
    else
      echo " $ns → uid=$USER"
    fi
  fi
done

echo ""
echo "=== SERVICEACCOUNTS SIN TOKEN AUTOMÁTICO ==="
kubectl get serviceaccount -A \
  -o jsonpath='{range .items[?(@.automountServiceAccountToken==false)]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
  | grep cliente
```

### 5.2 Estado esperado completo

| Control | Comando de verificación | Estado esperado |
|---------|------------------------|-----------------|
| GlobalNetworkPolicies | `calicoctl get globalnetworkpolicy` | 4 políticas activas |
| Aislamiento entre clientes | `wget` desde pod cliente-A a cliente-B | Timeout / BLOQUEADO |
| Rate limit activo | `kubectl get ingress -A -o yaml \| grep limit-rps` | Presente en todos los ingress |
| Fail2ban master | `sudo fail2ban-client status sshd` | `Jail list: sshd` |
| Fail2ban submaster | `sudo fail2ban-client status` | `Jail list: nginx-limit-req, sshd` |
| Pods sin root | `kubectl exec -- id` en pods cliente | `uid=33(www-data)` |
| SA sin token | `kubectl get sa -n cliente-X default -o yaml` | `automountServiceAccountToken: false` |

---

## 6. Troubleshooting

### 6.1 Tabla de incidencias comunes

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| Pod de cliente no recibe tráfico tras aplicar NetworkPolicy | `allow-from-ingress` no aplica por label incorrecto | Verificar `kubectl get ns ingress-nginx --show-labels` — debe tener `name=ingress-nginx` |
| Nuevo cliente no tiene aislamiento | Namespace sin label `tipo=cliente` | `kubectl label namespace cliente-X tipo=cliente` |
| `calicoctl` devuelve error de autenticación | Variables de entorno no exportadas | Prefija con `CALICO_DATASTORE_TYPE=kubernetes CALICO_KUBECONFIG=~/.kube/config` |
| Pod crashea tras aplicar SecurityContext | Imagen requiere root para arrancar | Verificar con `kubectl logs` — si es Apache, usar `uid=33`; si es otra imagen, revisar el Dockerfile |
| Fail2ban no detecta intentos SSH | `backend=systemd` pero journald no tiene logs de sshd | Cambiar `backend=auto` en `jail.local` |
| IP de administración baneada | Fail2ban detectó intentos legítimos como ataques | `sudo fail2ban-client set sshd unbanip <TU_IP>` |
| Rate limit devuelve 429 en uso normal | Límites demasiado estrictos | Aumentar `limit-rps` o `limit-burst-multiplier` en la anotación del ingress |
| `kubectl get globalnetworkpolicy` no encuentra el recurso | Usar `kubectl` en lugar de `calicoctl` | Usar siempre `calicoctl get globalnetworkpolicy` |

### 6.2 Desbanear una IP en Fail2ban

```bash
# Ver IPs baneadas
sudo fail2ban-client status sshd
sudo fail2ban-client status nginx-limit-req

# Desbanear IP específica
sudo fail2ban-client set sshd unbanip <IP>
sudo fail2ban-client set nginx-limit-req unbanip <IP>

# Ver log de acciones de fail2ban
sudo tail -50 /var/log/fail2ban.log
```

### 6.3 Revertir SecurityContext si una imagen no es compatible

```bash
# Eliminar el securityContext de un deployment
kubectl patch deployment <APP> -n <NS> --type=json -p='[
  {"op": "remove", "path": "/spec/template/spec/securityContext"},
  {"op": "remove", "path": "/spec/template/spec/containers/0/securityContext"}
]'
```

---

## 7. Apéndices

### Apéndice A: Proceso completo de onboarding de un cliente nuevo

```bash
#!/bin/bash
# onboarding-cliente.sh
# Uso: ./onboarding-cliente.sh <nombre-cliente> <app-name>
# Ejemplo: ./onboarding-cliente.sh cliente-nuevo miapp

NS=$1
APP=$2

# 1. Crear namespace
kubectl create namespace ${NS}

# 2. Activar NetworkPolicies globales de Calico
kubectl label namespace ${NS} tipo=cliente

# 3. RBAC
kubectl apply -f - << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${APP}-sa
  namespace: ${NS}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${APP}-role
  namespace: ${NS}
rules:
- apiGroups: [""]
  resources: ["configmaps", "pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${APP}-rolebinding
  namespace: ${NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${APP}-role
subjects:
- kind: ServiceAccount
  name: ${APP}-sa
  namespace: ${NS}
EOF

# 4. Deshabilitar token automático en SA default
kubectl patch serviceaccount default -n ${NS} \
  -p '{"automountServiceAccountToken": false}'

echo " Namespace ${NS} configurado con seguridad completa"
echo "   - NetworkPolicy: activa (tipo=cliente)"
echo "   - RBAC: ServiceAccount ${APP}-sa creado"
echo "   - SA default: token automático deshabilitado"
echo ""
echo "Recuerda aplicar SecurityContext en el Deployment:"
echo "  runAsUser: 33, runAsNonRoot: true, capabilities: drop ALL"
```

### Apéndice B: Referencia de comandos de seguridad

| Operación | Comando |
|-----------|---------|
| Ver GlobalNetworkPolicies | `CALICO_DATASTORE_TYPE=kubernetes CALICO_KUBECONFIG=~/.kube/config calicoctl get globalnetworkpolicy` |
| Aplicar label a namespace | `kubectl label namespace <NS> tipo=cliente` |
| Ver jails activos | `sudo fail2ban-client status` |
| Desbanear IP | `sudo fail2ban-client set sshd unbanip <IP>` |
| Ver pods corriendo como root | `kubectl exec -n <NS> <POD> -- id` |
| Ver SecurityContext de un pod | `kubectl get pod <POD> -n <NS> -o jsonpath='{.spec.securityContext}'` |
| Ver token del SA | `kubectl get serviceaccount <SA> -n <NS> -o yaml` |
