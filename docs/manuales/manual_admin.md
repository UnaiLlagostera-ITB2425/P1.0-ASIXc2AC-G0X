# Manual de Administración — P1.0 MEU
### Plataforma SaaS de Hosting Web sobre AWS y Kubernetes
**Versión 1.0 · Mayo 2026 · Uso interno del equipo técnico**
 
---
 
## Índice
 
1. [Visión general de la arquitectura](#1-visión-general-de-la-arquitectura)
2. [Inventario de infraestructura](#2-inventario-de-infraestructura)
3. [Acceso al clúster](#3-acceso-al-clúster)
4. [Operaciones del día a día](#4-operaciones-del-día-a-día)
5. [Gestión de clientes (aprovisionamiento)](#5-gestión-de-clientes-aprovisionamiento)
6. [Gestión de la base de datos](#6-gestión-de-la-base-de-datos)
7. [Certificados TLS y DNS](#7-certificados-tls-y-dns)
8. [Observabilidad: Grafana, Prometheus y Loki](#8-observabilidad-grafana-prometheus-y-loki)
9. [Autenticación LDAP](#9-autenticación-ldap)
10. [Seguridad](#10-seguridad)
11. [Almacenamiento persistente](#11-almacenamiento-persistente)
12. [Runbook de troubleshooting](#12-runbook-de-troubleshooting)
13. [Procedimientos de mantenimiento](#13-procedimientos-de-mantenimiento)
14. [Referencia rápida de comandos](#14-referencia-rápida-de-comandos)
---
 
## 1. Visión general de la arquitectura
 
P1.0 MEU es una plataforma SaaS de hosting web multicliente desplegada sobre Kubernetes autogestionado en AWS. Cada cliente recibe un namespace aislado, un subdominio propio (`<slug>.meu-project.me`), una base de datos MariaDB dedicada y un certificado TLS gestionado automáticamente por cert-manager.
 
### Diagrama de flujo del tráfico
 
```
Internet
    │  HTTPS/HTTP
    ▼
Elastic IP 18.235.39.46 (k8s-submaster)
    │
    ▼
ingress-nginx-controller (DaemonSet en k8s-submaster, puertos 80/443)
    │
    ├── meu-project.me            → meu-web-svc:80       (landing page)
    ├── meu-project.me/auth       → meu-api-svc:8001     (autenticación LDAP)
    ├── meu-project.me/dashboard  → meu-dashboard-svc:80 (panel admin)
    ├── api.meu-project.me        → saas-api:8001        (API de aprovisionamiento)
    ├── admin.meu-project.me      → core-dashboard-svc:80
    ├── pma.meu-project.me        → phpmyadmin-service:80
    ├── grafana.meu-project.me    → kube-prometheus-stack-grafana:80
    └── <slug>.meu-project.me     → <slug>-service:80    (sitio de cliente)
```
 
### Stack tecnológico real
 
| Capa | Tecnología | Versión |
|---|---|---|
| Orquestador | Kubernetes (kubeadm) | v1.30.14 |
| Runtime | containerd | 2.2.x |
| CNI | Calico | v3.28 |
| Ingress | ingress-nginx | DaemonSet |
| TLS | cert-manager + Let's Encrypt | letsencrypt-prod |
| Autenticación | OpenLDAP + FastAPI (meu-api) | slapd 2.6.x |
| Base de datos | MariaDB (EC2 externo) | 10.11 |
| Métricas | Prometheus (kube-prometheus-stack) | — |
| Dashboards | Grafana | — |
| Logs | Loki + Grafana Alloy | 3.6.x |
| Helm | — | v3.20.2 |
| DNS | Namecheap (wildcard *.meu-project.me → 18.235.39.46) | — |
 
---
 
## 2. Inventario de infraestructura
 
### Nodos del clúster
 
| Nombre | IP privada | Rol | OS | Runtime |
|---|---|---|---|---|
| `k8s-master` | 10.0.1.118 | control-plane | Ubuntu 24.04.4 | containerd 2.2.3 |
| `k8s-submaster` | 10.0.1.106 | ingress (worker) | Ubuntu 24.04.4 | containerd 2.2.1 |
| `cp-node-39` | 10.0.1.39 | control-plane | Ubuntu 24.04.4 | containerd 2.2.1 |
| `cp-node-82` | 10.0.1.82 | control-plane | Ubuntu 24.04.4 | containerd 2.2.1 |
| `cp1` | 10.0.1.219 | control-plane | Ubuntu 24.04.4 | containerd 2.2.1 |
| `ip-10-0-1-228` | 10.0.1.228 | worker | Ubuntu 24.04.4 | containerd 2.2.3 |
| `worker3` | 10.0.1.198 | worker | Ubuntu 26.04 | containerd 2.2.2 |
 
### Instancias EC2 externas
 
| Instancia | IP privada | Función |
|---|---|---|
| EC2 DDBB | 10.2.2.191 | MariaDB + OpenLDAP + Registry (5000) + NFS |
 
### Namespaces activos
 
| Namespace | Contenido |
|---|---|
| `meu` | Landing page, API auth, dashboard panel admin, saas-api |
| `monitoring` | Prometheus, Grafana, Loki, Alloy, Alertmanager |
| `ingress-nginx` | Ingress Controller |
| `cert-manager` | cert-manager, webhook, cainjector |
| `saas-dashboard` | Panel core-dashboard |
| `default` | phpMyAdmin, mariadb-externo (Service/Endpoints) |
| `kube-system` | Calico, CoreDNS, kube-proxy, metrics-server |
| `cliente-<slug>` | Un namespace por cliente aprovisionado |
 
### URLs de acceso a servicios
 
| Servicio | URL |
|---|---|
| Landing / Login | https://meu-project.me |
| Panel de administración | https://meu-project.me/dashboard |
| API de aprovisionamiento | https://api.meu-project.me |
| Panel core (saas-dashboard) | https://admin.meu-project.me |
| phpMyAdmin | https://pma.meu-project.me |
| Grafana | https://grafana.meu-project.me |
 
---
 
## 3. Acceso al clúster
 
### SSH al nodo master
 
```bash
ssh -i ~/.ssh/keypair-proyecto-k8s.pem meu_master@<IP_PUBLICA_MASTER>
```
 
### SSH a la EC2 DDBB
 
```bash
ssh -i ~/.ssh/Key-BD.pem meu_db1@10.2.2.191
```
 
> La EC2 DDBB no tiene IP pública. Acceder desde el master via VPC Peering.
 
### kubectl desde el master
 
El `kubeconfig` está en `~/.kube/config`. Todos los comandos `kubectl` se ejecutan desde `k8s-master`.
 
```bash
# Verificar acceso
kubectl get nodes
kubectl cluster-info
```
 
---
 
## 4. Operaciones del día a día
 
### Verificar estado general del clúster
 
```bash
# Nodos
kubectl get nodes -o wide
 
# Todos los pods (todos los namespaces)
kubectl get pods -A
 
# Pods con problemas (no Running/Completed)
kubectl get pods -A | grep -v -E 'Running|Completed'
 
# Recursos de los nodos
kubectl top nodes
kubectl top pods -A
```
 
### Estado esperado (clúster sano)
 
```
NAME            STATUS   ROLES           AGE
k8s-master      Ready    control-plane
k8s-submaster   Ready    ingress
cp-node-39      Ready    control-plane
cp-node-82      Ready    control-plane
cp1             Ready    control-plane
ip-10-0-1-228   Ready    worker
worker3         Ready    worker
```
 
Todos los nodos deben estar en estado `Ready`. Calico debe tener un pod `1/1 Running` por nodo.
 
### Verificar servicios críticos
 
```bash
# Ingress
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
 
# cert-manager
kubectl get pods -n cert-manager
 
# Certificados TLS
kubectl get certificate -A
 
# Calico (CNI)
kubectl get pods -n kube-system -l k8s-app=calico-node
 
# Aplicación principal (namespace meu)
kubectl get pods -n meu
kubectl get pods -n monitoring
```
 
### Reiniciar un deployment
 
```bash
kubectl rollout restart deployment/<nombre> -n <namespace>
 
# Ejemplos
kubectl rollout restart deployment/meu-api -n meu
kubectl rollout restart deployment/meu-dashboard -n meu
kubectl rollout restart deployment/meu-web -n meu
```
 
### Ver logs de un pod
 
```bash
kubectl logs deployment/<nombre> -n <namespace> --tail=50
kubectl logs deployment/<nombre> -n <namespace> -f   # seguimiento en tiempo real
 
# Ejemplos
kubectl logs deployment/meu-api -n meu --tail=50
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=30
```
 
---
 
## 5. Gestión de clientes (aprovisionamiento)
 
### Cómo se crea un cliente
 
El aprovisionamiento se realiza a través de la API en `https://api.meu-project.me`. El panel de administración en `https://meu-project.me/dashboard` proporciona una interfaz gráfica para este proceso.
 
**Parámetros de creación:**
 
| Campo | Descripción | Ejemplo |
|---|---|---|
| `slug` | Identificador único del cliente | `acme` |
| `title` | Título del sitio web | `Empresa ACME` |
| `theme` | Tema visual (`light`/`dark`) | `dark` |
| `plan` | Plan de hosting | `basic`, `pro`, `enterprise` |
| `version_php` | Versión de PHP | `8.3`, `8.2` |
 
**Planes disponibles:**
 
| Plan | CPU request | CPU limit | RAM request | RAM limit |
|---|---|---|---|---|
| `basic` | 5m | 25m | 32Mi | 64Mi |
| `pro` | 10m | 50m | 64Mi | 128Mi |
| `enterprise` | 20m | 100m | 128Mi | 256Mi |
 
**Via curl (API directa):**
 
```bash
curl -X POST https://api.meu-project.me/api/create \
  -H "Authorization: Bearer mi-token-prueba" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "slug=acme&title=Empresa ACME&theme=dark&plan=pro&version_php=8.3"
```
 
### Verificar cliente aprovisionado
 
```bash
# Namespace creado
kubectl get ns | grep cliente
 
# Pods del cliente
kubectl get pods -n cliente-<slug>
 
# Ingress del cliente
kubectl get ingress -n cliente-<slug>
 
# Certificado TLS
kubectl get certificate -n cliente-<slug>
 
# PVC del cliente
kubectl get pvc -n cliente-<slug>
```
 
### Eliminar un cliente
 
```bash
curl -X DELETE https://api.meu-project.me/api/delete/<slug> \
  -H "Authorization: Bearer mi-token-prueba"
```
 
O manualmente:
 
```bash
kubectl delete namespace cliente-<slug>
```
 
> **ATENCIÓN:** Eliminar el namespace destruye todos los recursos del cliente incluyendo el PVC. Si el StorageClass es `nfs-k8s` con `ReclaimPolicy: Delete`, los datos también se eliminan del NFS.
 
### Listar clientes activos
 
```bash
curl -s https://api.meu-project.me/api/sites \
  -H "Authorization: Bearer mi-token-prueba" | python3 -m json.tool
 
# O via kubectl
kubectl get ns | grep cliente
```
 
### Estructura de un cliente en el clúster
 
Cada cliente desplegado genera los siguientes recursos:
 
```
namespace: cliente-<slug>
├── Deployment: <slug>
├── Service: <slug>-service (ClusterIP:80)
├── Ingress: <slug>-ingress (host: <slug>.meu-project.me)
├── Certificate: <slug>-tls (Let's Encrypt)
├── Secret: <slug>-tls (kubernetes.io/tls)
├── Secret: <slug>-db-secret (credenciales MariaDB)
└── PVC: <slug>-pvc (1Gi, StorageClass: nfs-k8s)
```
 
---
 
## 6. Gestión de la base de datos
 
### Acceso a MariaDB
 
```bash
# Desde el master (via VPC Peering)
ssh -i ~/.ssh/Key-BD.pem meu_db1@10.2.2.191
sudo mariadb
 
# Desde un pod en el clúster
kubectl run db-test --image=mariadb:10.11 --rm -it --restart=Never -- \
  mariadb -h 10.2.2.191 -u meu_admin -p plataforma_hosting
```
 
### Acceso a phpMyAdmin
 
URL: https://pma.meu-project.me
 
Credenciales almacenadas en el Secret `mariadb-credentials` del namespace `default`:
 
```bash
kubectl get secret mariadb-credentials -n default -o jsonpath='{.data.MARIADB_ROOT_PASSWORD}' | base64 -d && echo
kubectl get secret mariadb-credentials -n default -o jsonpath='{.data.MARIADB_USER}' | base64 -d && echo
kubectl get secret mariadb-credentials -n default -o jsonpath='{.data.MARIADB_PASSWORD}' | base64 -d && echo
```
 
### Esquema de la base de datos
 
La base de datos `plataforma_hosting` contiene las tablas del sistema de control operativo:
 
| Tabla | Contenido |
|---|---|
| `clientes` | Registro de clientes con estado |
| `usuarios_panel` | Usuarios admin y de cliente con roles |
| `sitios` | Sitios web, dominio, imagen y estado |
| `bases_datos_cliente` | Credenciales de BD por sitio |
| `despliegues` | Historial de aprovisionamientos |
| `auditoria_eventos` | Log de acciones del sistema |
 
### Recuperar credenciales de BD de un cliente
 
Cada cliente tiene un Secret con sus credenciales de base de datos:
 
```bash
kubectl get secret <slug>-db-secret -n cliente-<slug> -o jsonpath='{.data}' | \
  python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k,'=',base64.b64decode(v).decode()) for k,v in d.items()]"
```
 
### Backup manual de MariaDB
 
```bash
ssh -i ~/.ssh/Key-BD.pem meu_db1@10.2.2.191
mysqldump -u meu_admin -p plataforma_hosting > /tmp/backup_$(date +%Y%m%d_%H%M%S).sql
```
 
---
 
## 7. Certificados TLS y DNS
 
### Arquitectura TLS
 
- **Emisor:** `letsencrypt-prod` (ClusterIssuer, HTTP-01)
- **Email de registro ACME:** unai.llagostera.7e8@itb.cat
- **DNS:** Namecheap — wildcard `*.meu-project.me → 18.235.39.46`
- **Certificados individuales** por dominio (HTTP-01 no soporta wildcards)
### Ver estado de todos los certificados
 
```bash
kubectl get certificate -A
```
 
Estado esperado: todos en `READY: True`.
 
### Forzar renovación de un certificado
 
```bash
# Eliminar el certificate y el secret — cert-manager los regenera solos
kubectl delete certificate <nombre-cert> -n <namespace>
kubectl delete secret <nombre-tls-secret> -n <namespace>
 
# Ejemplo para meu-project.me
kubectl delete certificate meu-project-tls -n meu
kubectl delete secret meu-project-tls -n meu
```
 
### Diagnóstico de certificado bloqueado
 
```bash
# Ver el estado del certificate
kubectl describe certificate <nombre> -n <namespace>
 
# Ver el challenge HTTP-01
kubectl get challenge -A
kubectl describe challenge <nombre-challenge> -n <namespace>
 
# Ver orden ACME
kubectl get order -A
kubectl describe order <nombre-order> -n <namespace>
 
# Ver logs de cert-manager
kubectl logs -n cert-manager deployment/cert-manager --tail=30
```
 
**Causa más común de fallo:** el DNS del dominio no apunta a 18.235.39.46 o el puerto 80 no es accesible desde Internet.
 
### Verificar certificado desde CLI
 
```bash
openssl s_client -connect meu-project.me:443 </dev/null 2>/dev/null | \
  openssl x509 -noout -subject -issuer -dates
```
 
---
 
## 8. Observabilidad: Grafana, Prometheus y Loki
 
### Acceso a Grafana
 
URL: https://grafana.meu-project.me
 
Credenciales en el Secret `kube-prometheus-stack-grafana` del namespace `monitoring`:
 
```bash
kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-user}' | base64 -d && echo
kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```
 
### Estado del stack de monitorización
 
```bash
kubectl get pods -n monitoring
```
 
Pods esperados en Running:
- `alertmanager-kube-prometheus-stack-alertmanager-0` (2/2)
- `kube-prometheus-stack-grafana-*` (3/3)
- `kube-prometheus-stack-operator-*` (1/1)
- `loki-0` (1/1)
- `prometheus-kube-prometheus-stack-prometheus-0` (2/2)
- `alloy-logs-*` (1/1 por nodo — DaemonSet)
- `kube-prometheus-stack-prometheus-node-exporter-*` (1/1 por nodo)
### Arquitectura de logs
 
```
Pods de todos los nodos
    │
    ▼ (DaemonSet)
Grafana Alloy (alloy-logs-*)
    │  discovery.kubernetes → relabeling → loki.write
    ▼
Loki (loki-0 en worker3, 10Gi local-path)
    │
    ▼
Grafana (datasource: http://loki.monitoring.svc.cluster.local:3100)
```
 
### Consultar logs desde la CLI (sin Grafana)
 
```bash
# Logs de un pod específico
kubectl logs -n <namespace> <pod-name> --tail=100
 
# Logs de un deployment
kubectl logs deployment/<nombre> -n <namespace> --tail=50 -f
 
# Logs del ingress-nginx (accesos HTTP)
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50
```
 
### PVCs del stack de monitorización
 
| PVC | Tamaño | StorageClass | Contenido |
|---|---|---|---|
| `prometheus-*` | 10Gi | local-path | Métricas (retención 10d) |
| `kube-prometheus-stack-grafana` | 10Gi | local-path | Dashboards y configuración |
| `storage-loki-0` | 10Gi | local-path | Logs (filesystem) |
| `alertmanager-*` | 2Gi | local-path | Estado del alertmanager |
 
---
 
## 9. Autenticación LDAP
 
### Arquitectura de autenticación
 
```
Navegador → POST /auth/login → meu-api (FastAPI)
                                    │
                                    │ LDAP bind
                                    ▼
                              OpenLDAP (10.2.2.191:389)
                              dc=meu,dc=local
                              ou=People
                              uid=admin / uid=demo
                                    │
                              bind exitoso → JWT cookie (meu_session)
                              bind fallido → HTTP 401
```
 
### Cómo funciona la sesión
 
1. El usuario envía `POST /auth/login` con `{ username, password }`.
2. `meu-api` realiza un bind LDAP directo con `uid=<username>,ou=People,dc=meu,dc=local`.
3. Si el bind es exitoso, genera un token HMAC-SHA256 firmado con `SESSION_KEY`.
4. El token se emite como cookie `meu_session` (`httponly`, `secure`, `samesite=strict`, 24h).
5. El Nginx del dashboard verifica la cookie vía `auth_request` → `/auth/verify` antes de servir `/dashboard`.
### Gestión de usuarios LDAP
 
```bash
# Conectar a la EC2 DDBB
ssh -i ~/.ssh/Key-BD.pem meu_db1@10.2.2.191
 
# Listar usuarios
ldapsearch -x -b "dc=meu,dc=local" "(objectClass=posixAccount)" dn
 
# Añadir un usuario nuevo (crear archivo .ldif)
cat > /tmp/nuevo_usuario.ldif << 'EOF'
dn: uid=nuevo,ou=People,dc=meu,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: Nuevo Usuario
sn: Usuario
uid: nuevo
uidNumber: 10002
gidNumber: 10002
homeDirectory: /home/nuevo
loginShell: /bin/bash
mail: nuevo@meu-project.me
userPassword: <contraseña>
EOF
 
ldapadd -x -D "cn=admin,dc=meu,dc=local" -W -f /tmp/nuevo_usuario.ldif
 
# Cambiar contraseña de un usuario
ldappasswd -x -D "cn=admin,dc=meu,dc=local" -W \
  -s "nueva_contraseña" "uid=admin,ou=People,dc=meu,dc=local"
```
 
### Usuarios existentes
 
| uid | Rol |
|---|---|
| `admin` | Administrador del panel |
| `demo` | Usuario de pruebas / acceso MariaDB via PAM |
 
### SESSION_KEY (cookie de sesión)
 
La clave de firma del token está almacenada en el Secret `meu-session-secret` del namespace `meu`. Persiste aunque el pod muera:
 
```bash
kubectl get secret meu-session-secret -n meu -o jsonpath='{.data.SESSION_KEY}' | base64 -d && echo
```
 
El código de la API (`/app/main.py`) está almacenado en el ConfigMap `meu-api-code` y se monta como volumen, por lo que persiste independientemente de la imagen:
 
```bash
kubectl get configmap meu-api-code -n meu -o jsonpath='{.data.main\.py}'
```
 
---
 
## 10. Seguridad
 
### Security Groups activos
 
El nodo `k8s-submaster` (18.235.39.46) expone públicamente:
 
| Puerto | Protocolo | Motivo |
|---|---|---|
| 80 | TCP | HTTP público (redirect HTTPS + ACME HTTP-01) |
| 443 | TCP | HTTPS público (terminación TLS en ingress-nginx) |
| 22 | TCP | SSH administración |
 
El resto de nodos solo tienen abiertos los puertos internos del clúster (6443, 10250, 179 BGP Calico).
 
### Protección del dashboard
 
El acceso a `/dashboard` está protegido mediante `auth_request` en el nginx del pod `meu-dashboard`. Sin cookie `meu_session` válida, el nginx devuelve un redirect 302 al login.
 
```bash
# Verificar protección activa
curl -sk -o /dev/null -w "%{http_code}" https://meu-project.me/dashboard
# Resultado esperado: 302
 
curl -sk -o /dev/null -w "%{http_code}" https://meu-project.me/auth/verify
# Resultado esperado: 401
```
 
### Protección de phpMyAdmin
 
El Ingress de phpMyAdmin tiene `whitelist-source-range` configurado. Si se pierde acceso:
 
```bash
# Ver whitelist actual
kubectl get ingress phpmyadmin-ingress -n default -o jsonpath='{.metadata.annotations}'
 
# Añadir IP a la whitelist
kubectl annotate ingress phpmyadmin-ingress -n default \
  nginx.ingress.kubernetes.io/whitelist-source-range="TU_IP/32" --overwrite
 
# Eliminar whitelist (acceso abierto)
kubectl annotate ingress phpmyadmin-ingress -n default \
  nginx.ingress.kubernetes.io/whitelist-source-range- 
```
 
### Token de la API de aprovisionamiento
 
El token actual es `mi-token-prueba` (configurado en el Secret `saas-api-env`). Para producción real debe rotarse:
 
```bash
kubectl edit secret saas-api-env -n meu
# Editar API_TOKEN con el nuevo valor en base64
echo -n "nuevo-token-seguro" | base64
```
 
---
 
## 11. Almacenamiento persistente
 
### StorageClasses disponibles
 
| Nombre | Provisioner | ReclaimPolicy | Binding |
|---|---|---|---|
| `local-path` (default) | rancher.io/local-path | Delete | WaitForFirstConsumer |
| `nfs-k8s` | nfs-subdir-external-provisioner | Delete | Immediate |
 
### NFS Server
 
El servidor NFS corre en la EC2 DDBB (`10.2.2.191`) y sirve `/srv/nfs/clientes`. Los clientes aprovisionados usan PVCs con `nfs-k8s` para sus datos de sitio web.
 
```bash
# Ver PVs activos
kubectl get pv
 
# Ver PVCs de todos los namespaces
kubectl get pvc -A
```
 
### PVs importantes
 
| PV | Namespace/PVC | Tamaño | StorageClass | Uso |
|---|---|---|---|---|
| auto (local-path) | monitoring/prometheus-* | 10Gi | local-path | Métricas |
| auto (local-path) | monitoring/grafana | 10Gi | local-path | Dashboards |
| auto (local-path) | monitoring/loki | 10Gi | local-path | Logs |
| auto (local-path) | monitoring/alertmanager | 2Gi | local-path | Alertas |
| auto (nfs-k8s) | cliente-*/cliente-pvc | 1Gi | nfs-k8s | Datos cliente |
 
---
 
## 12. Runbook de troubleshooting
 
### T01 — Un nodo aparece NotReady
 
**Síntomas:** `kubectl get nodes` muestra un nodo en `NotReady`.
 
**Diagnóstico:**
 
```bash
# Ver eventos del nodo
kubectl describe node <nombre-nodo>
 
# Ver logs del kubelet en el nodo afectado
ssh -i ~/.ssh/keypair-proyecto-k8s.pem meu_master@<ip-nodo> \
  "journalctl -u kubelet --tail=50"
 
# Ver estado de Calico en ese nodo
kubectl get pod -n kube-system -l k8s-app=calico-node -o wide | grep <nombre-nodo>
kubectl describe pod <calico-pod> -n kube-system
```
 
**Solución más común (CNI roto):**
 
```bash
# Si Calico está en CrashLoopBackOff o Init en ese nodo
ssh -i ~/.ssh/keypair-proyecto-k8s.pem meu_master@<ip-nodo>
sudo systemctl stop kubelet
sudo rm -rf /etc/cni/net.d/* /var/run/calico /var/lib/calico
sudo systemctl start kubelet
# En el master: forzar recreación del pod de Calico
kubectl delete pod -n kube-system <calico-pod-del-nodo>
```
 
---
 
### T02 — Pod en CrashLoopBackOff
 
**Diagnóstico:**
 
```bash
kubectl describe pod <nombre-pod> -n <namespace>
kubectl logs <nombre-pod> -n <namespace> --previous
kubectl logs <nombre-pod> -n <namespace> --tail=50
```
 
**Causas comunes y solución:**
 
| Causa | Síntoma en logs | Solución |
|---|---|---|
| Variable de entorno faltante | `KeyError: 'SESSION_KEY'` | `kubectl set env deployment/<d> --from=secret/<secret>` |
| Imagen no encontrada | `ImagePullBackOff` | Verificar registry en 10.2.2.191:5000 |
| Puerto ocupado | `address already in use` | Revisar si hay otro pod en el mismo nodo usando ese puerto |
| OOMKilled | `OOMKilled` en describe | Aumentar `resources.limits.memory` |
| ConfigMap montado incorrecto | Errores de import Python | Verificar `kubectl get cm <nombre> -n <ns> -o yaml` |
 
---
 
### T03 — Certificado TLS en estado False o bloqueado
 
**Diagnóstico:**
 
```bash
kubectl get certificate -A
kubectl describe certificate <nombre> -n <namespace>
kubectl get challenge -A
kubectl describe challenge <nombre> -n <namespace>
kubectl logs -n cert-manager deployment/cert-manager --tail=30
```
 
**Causas comunes:**
 
| Causa | Error en describe | Solución |
|---|---|---|
| DNS no apunta a 18.235.39.46 | `Timeout during connect` | Corregir registro A en Namecheap |
| Puerto 80 inaccesible | `connection refused` | Verificar Security Group del submaster |
| Challenge inválido previo | `authorization error` | `kubectl delete certificate <n> -n <ns>` para reiniciar |
| Wildcard con HTTP-01 | `pending` sin challenge | HTTP-01 no soporta wildcards; usar cert individual |
 
**Forzar recreación:**
 
```bash
kubectl delete certificate <nombre> -n <namespace>
kubectl delete secret <nombre-tls> -n <namespace>
# cert-manager recreará todo automáticamente en ~1 minuto
```
 
---
 
### T04 — El ingress no sirve tráfico / 502 Bad Gateway
 
**Diagnóstico:**
 
```bash
# Verificar que el pod de destino está Running
kubectl get pods -n <namespace>
 
# Verificar que el service tiene endpoints
kubectl get endpoints <service-name> -n <namespace>
 
# Logs del ingress-nginx
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50
 
# Ver configuración del ingress
kubectl get ingress <nombre> -n <namespace> -o yaml
```
 
**Causas comunes:**
 
| Error | Causa | Solución |
|---|---|---|
| 502 Bad Gateway | Pod del backend caído | `kubectl rollout restart deployment/<d> -n <ns>` |
| 404 Not Found | Regla de path incorrecta | Revisar `path` y `pathType` en el Ingress |
| SSL Handshake error | Secret TLS vacío o incorrecto | Regenerar certificado (ver T03) |
| No endpoints | Service sin pods activos | Verificar selector del Service y labels del pod |
 
---
 
### T05 — El dashboard muestra 302 en bucle / no se puede acceder tras login
 
**Diagnóstico:**
 
```bash
# Verificar que meu-api está Running
kubectl get pods -n meu -l app=meu-api
 
# Verificar que el endpoint /auth/verify funciona
curl -sk -o /dev/null -w "%{http_code}" https://meu-project.me/auth/verify
# Si devuelve algo distinto de 401, hay un problema con la API
 
# Ver logs de meu-api
kubectl logs deployment/meu-api -n meu --tail=30
 
# Verificar que el SESSION_KEY está inyectado
kubectl exec -n meu deployment/meu-api -- env | grep SESSION_KEY
```
 
**Si la cookie no se emite tras login correcto:**
 
```bash
# Verificar que el SESSION_KEY del pod coincide con el Secret
kubectl get secret meu-session-secret -n meu -o jsonpath='{.data.SESSION_KEY}' | base64 -d
 
# Si el pod tiene una clave diferente (reinicio sin el Secret inyectado):
kubectl set env deployment/meu-api -n meu --from=secret/meu-session-secret
kubectl rollout restart deployment/meu-api -n meu
```
 
**Si el nginx del dashboard no llama a auth/verify:**
 
```bash
kubectl get configmap meu-dashboard-nginx-conf -n meu -o yaml
# Debe contener: auth_request /auth/verify;
# Si no tiene ese bloque, el dashboard está desprotegido
```
 
---
 
### T06 — No hay conectividad entre pods (red rota)
 
**Síntomas:** Pods en Running pero sin poder comunicarse entre sí o con el API server.
 
**Diagnóstico:**
 
```bash
# Estado de Calico
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl get pods -n kube-system -l k8s-app=calico-kube-controllers
 
# Verificar BGP desde un nodo
ssh -i ~/.ssh/keypair-proyecto-k8s.pem meu_master@<ip-nodo>
sudo calicoctl node status
 
# Test de conectividad entre pods
kubectl run test-net --image=busybox --rm -it --restart=Never -- \
  ping -c 3 <ip-pod-destino>
 
# Desde el master — conectividad al API server
curl -k https://10.96.0.1:443/healthz
```
 
**Solución — Bootstrap de Calico (si el init container falla):**
 
```bash
# En el master: generar token y kubeconfig para calico-cni-plugin
kubectl create token calico-cni-plugin -n kube-system --duration=8760h > /tmp/calico-token.txt
 
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(cat /tmp/calico-token.txt)
 
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
 
# Copiar al nodo afectado
scp -i ~/.ssh/keypair-proyecto-k8s.pem /tmp/calico-kubeconfig \
  meu_master@<ip-nodo>:/tmp/
ssh -i ~/.ssh/keypair-proyecto-k8s.pem meu_master@<ip-nodo> \
  "sudo mkdir -p /etc/cni/net.d && sudo cp /tmp/calico-kubeconfig /etc/cni/net.d/calico-kubeconfig"
 
kubectl rollout restart daemonset calico-node -n kube-system
```
 
---
 
### T07 — Error de imagen (ImagePullBackOff)
 
```bash
kubectl describe pod <nombre-pod> -n <namespace> | grep -A5 Events
 
# Verificar que el registry interno está activo
ssh -i ~/.ssh/Key-BD.pem meu_db1@10.2.2.191
curl http://localhost:5000/v2/_catalog
```
 
**Si el registry está caído:**
 
```bash
# En la EC2 DDBB
sudo docker start registry 2>/dev/null || \
  sudo docker run -d -p 5000:5000 --name registry \
    -v /srv/registry:/var/lib/registry --restart=always registry:2
```
 
---
 
### T08 — LDAP no autentica
 
```bash
# En la EC2 DDBB
ssh -i ~/.ssh/Key-BD.pem meu_db1@10.2.2.191
 
# Estado del servicio
sudo systemctl status slapd
 
# Test de bind manual
ldapsearch -x -H ldap://localhost \
  -D "uid=admin,ou=People,dc=meu,dc=local" \
  -w <password> -b "dc=meu,dc=local" "(uid=admin)"
 
# Si slapd está caído
sudo systemctl restart slapd
```
 
---
 
### T09 — NFS / PVC en Pending
 
```bash
# Ver evento del PVC
kubectl describe pvc <nombre-pvc> -n <namespace>
 
# Verificar que el NFS provisioner está Running
kubectl get pods -n nfs-provisioner
 
# Si el pod del provisioner está en Unknown/Error:
kubectl delete pod -n nfs-provisioner -l app=nfs-subdir-external-provisioner
```
 
**Si el NFS server no responde:**
 
```bash
ssh -i ~/.ssh/Key-BD.pem meu_db1@10.2.2.191
sudo systemctl status nfs-kernel-server
showmount -e localhost
 
# Si está caído
sudo systemctl restart nfs-kernel-server
```
 
---
 
### T10 — Prometheus no recoge métricas / Grafana sin datos
 
```bash
# Estado del stack
kubectl get pods -n monitoring
 
# Si prometheus-0 está caído
kubectl describe pod prometheus-kube-prometheus-stack-prometheus-0 -n monitoring
 
# Acceso directo a Prometheus (port-forward)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Luego abrir http://localhost:9090 en el navegador local
 
# Acceso directo a Loki
kubectl port-forward -n monitoring svc/loki 3100:3100
curl http://localhost:3100/ready
```
 
---
 
## 13. Procedimientos de mantenimiento
 
### Actualizar el código de meu-api
 
El código está en el ConfigMap `meu-api-code`. Para actualizar:
 
```bash
# Editar el main.py localmente en el master
nano /tmp/main.py
 
# Actualizar el ConfigMap
kubectl create configmap meu-api-code \
  --from-file=main.py=/tmp/main.py \
  -n meu --dry-run=client -o yaml | kubectl apply -f -
 
# Reiniciar el pod para que tome los cambios
kubectl rollout restart deployment/meu-api -n meu
kubectl logs deployment/meu-api -n meu --tail=20
```
 
### Actualizar el contenido del dashboard
 
```bash
# Editar el HTML
nano /tmp/dashboard.html
 
# Actualizar el ConfigMap
kubectl create configmap meu-dashboard-html \
  --from-file=index.html=/tmp/dashboard.html \
  -n meu --dry-run=client -o yaml | kubectl apply -f -
 
kubectl rollout restart deployment/meu-dashboard -n meu
```
 
### Actualizar la landing page (meu-web)
 
```bash
nano /tmp/index.html
 
kubectl create configmap meu-web-html \
  --from-file=index.html=/tmp/index.html \
  -n meu --dry-run=client -o yaml | kubectl apply -f -
 
kubectl rollout restart deployment/meu-web -n meu
```
 
### Rotar el SESSION_KEY
 
> **IMPORTANTE:** Rotar el SESSION_KEY invalida todas las sesiones activas. Los usuarios tendrán que volver a hacer login.
 
```bash
# Generar nueva clave
NEW_KEY=$(openssl rand -hex 32)
 
# Actualizar el Secret
kubectl create secret generic meu-session-secret \
  --from-literal=SESSION_KEY=$NEW_KEY \
  -n meu --dry-run=client -o yaml | kubectl apply -f -
 
# Reiniciar meu-api para que tome la nueva clave
kubectl rollout restart deployment/meu-api -n meu
```
 
### Añadir un nuevo nodo worker
 
```bash
# En el master: generar token de join
kubeadm token create --print-join-command
 
# En el nuevo nodo (ejecutar el comando generado)
sudo kubeadm join <ip-master>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
 
# Etiquetar el nodo
kubectl label node <nombre-nodo> node-role.kubernetes.io/worker=worker
```
 
---
 
## 14. Referencia rápida de comandos
 
### Diagnóstico general
 
```bash
# Estado del clúster
kubectl get nodes -o wide
kubectl get pods -A | grep -v Running | grep -v Completed
kubectl top nodes
kubectl top pods -A --sort-by=memory
 
# Eventos recientes (últimos errores)
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
 
# Capacidad del clúster
kubectl describe nodes | grep -A5 "Allocated resources"
```
 
### Certificados y DNS
 
```bash
kubectl get certificate -A
kubectl get challenge -A
kubectl get clusterissuer
dig +short meu-project.me
dig +short grafana.meu-project.me
curl -sk -o /dev/null -w "%{http_code}" https://meu-project.me
```
 
### Aplicación principal
 
```bash
kubectl get all -n meu
kubectl logs deployment/meu-api -n meu --tail=30
kubectl logs deployment/meu-dashboard -n meu --tail=20
kubectl exec -n meu deployment/meu-api -- cat /app/main.py | head -5
```
 
### Clientes
 
```bash
kubectl get ns | grep cliente
kubectl get pods -A | grep cliente
kubectl get certificate -A | grep cliente
kubectl get pvc -A | grep cliente
```
 
### Monitorización
 
```bash
kubectl get pods -n monitoring
kubectl logs -n monitoring loki-0 --tail=20
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=20
kubectl get pvc -n monitoring
```
 
### Almacenamiento
 
```bash
kubectl get pv
kubectl get pvc -A
kubectl get storageclass
```
 
### Comandos de emergencia
 
```bash
# Reiniciar todos los deployments del namespace meu
kubectl rollout restart deployment -n meu
 
# Forzar eliminación de un pod bloqueado en Terminating
kubectl delete pod <nombre> -n <namespace> --grace-period=0 --force
 
# Ver todos los recursos de un namespace
kubectl get all -n <namespace>
 
# Exportar kubeconfig actual
kubectl config view --raw > kubeconfig-backup.yaml
```
 
---
