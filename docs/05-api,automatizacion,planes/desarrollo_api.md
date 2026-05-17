# Desarrollo de la API de Hosting SaaS

## 1. Objetivo del sistema

El objetivo de esta solución es automatizar por completo el aprovisionamiento de un nuevo cliente SaaS, reduciendo un proceso manual de aproximadamente 15 minutos a una operación automatizada de menos de 2 segundos.

Antes de esta implementación, el alta de un cliente implicaba editar manifiestos de Kubernetes manualmente, crear recursos con `kubectl`, preparar la base de datos externa, configurar DNS y esperar la emisión del certificado TLS. Ese flujo era costoso, frágil y dependía de intervención técnica continua.

La API implementada elimina esa dependencia operativa y convierte el alta de cliente en una acción única y reproducible mediante HTTP: `POST /api/create`.

---

## 2. Criterios de diseño

Se eligió **FastAPI** como capa de exposición HTTP porque ofrece validación nativa con Pydantic y generación automática de documentación OpenAPI/Swagger. En un sistema de aprovisionamiento, la validación de estructura es crítica: la API recibe datos de cliente, imagen, base de datos y almacenamiento que deben ser consistentes desde el primer momento.

Para la capa de orquestación interna se adoptó un modelo híbrido: Python para la lógica de negocio y herramientas nativas de Kubernetes para las operaciones de infraestructura. Esta decisión evita reimplementar en Python la lógica de idempotencia, renderizado y aplicación de recursos que ya resuelven bien `kubectl apply`, y mantiene trazabilidad clara durante el diagnóstico operativo.

| Decisión | Justificación |
|----------|---------------|
| **FastAPI + Pydantic** | Validación de entrada, documentación automática, tipado fuerte |
| **Plantilla YAML + `kubectl apply`** | Repetible, auditable, fácil de extender |
| **Namespace por cliente** | Aislamiento total: un cliente no puede ver ni afectar a otro |
| **IngressClassName: nginx** | Evita que el controlador sirva el certificado fake por defecto |
| **ClusterIP para el Service** | El pod no se expone directamente; todo pasa por el Ingress |
| **Resource requests/limits** | Evita que un cliente consuma toda la CPU/RAM del nodo |
| **cert-manager + letsencrypt-prod** | TLS automático sin intervención manual |
| **ServiceAccount propia para saas-api** | La API necesita permisos RBAC explícitos en namespaces de clientes |

---

## 3. Arquitectura funcional

La arquitectura final queda organizada en cuatro bloques:

- **API FastAPI**: recibe el `POST /api/create`, valida la petición y orquesta el flujo.
- **Orquestación Kubernetes**: renderiza plantilla YAML y lanza `kubectl apply`.
- **Ingress + cert-manager**: publica el servicio por HTTPS con certificado gestionado automáticamente.
- **Dashboard**: interfaz HTML que consume la API y muestra el estado de los tenants.

La separación de responsabilidades es clave: la API crea y controla los recursos de ciclo de vida del cliente; Kubernetes mantiene el estado deseado.

```text
Internet
   ↓ HTTPS :443
[ingress-nginx — k8s-submaster]
   ↓ HTTP :80
[Service: <cliente>-service — ClusterIP]
   ↓
[Pod: <cliente>-deployment]
  └─ Nginx + PHP-FPM :80
  └─ /var/www/html/ (contenido inyectado vía ConfigMap)
```

---

## 4. Imagen Docker

La imagen Docker es el artefacto base sobre el que corre cada cliente. Contiene el servidor web, PHP-FPM y la configuración de Nginx, de forma que Kubernetes no tenga que instalar dependencias en cada despliegue.

### Por qué imagen propia

- **Portabilidad**: el mismo artefacto funciona en cualquier nodo del clúster.
- **Reproducibilidad**: código, dependencias y runtime quedan fijados en una versión concreta.
- **Rapidez**: Kubernetes solo descarga y arranca; no compila ni instala al vuelo.

### Construcción y publicación

```bash
cd ~/saas-hosting
docker build -f apps/php/Dockerfile -t 10.2.2.191:5000/saas-php:8.3 apps/php
docker push 10.2.2.191:5000/saas-php:8.3
```

El `Deployment` de cada cliente apunta a esa etiqueta concreta del registry interno. Si cambias la imagen base, el flujo es: **build → push → rollout restart** del deployment afectado.

### Reconstrucción de `saas-api`

Cuando cambias código Python de la API:

```bash
cd ~/saas-hosting
docker build --no-cache -f apps/api/Dockerfile -t 10.2.2.191:5000/saas-api:latest .
docker push 10.2.2.191:5000/saas-api:latest
kubectl -n meu rollout restart deployment saas-api-saas-api
kubectl -n meu rollout status deployment saas-api-saas-api
```

> Usar `--no-cache` evita que Docker reutilice capas antiguas que no reflejen los cambios recientes del código.

---

## 5. Flujo de aprovisionamiento

El flujo operativo validado fue el siguiente:

```text
T+0.00s  Ingress recibe la petición HTTPS.
T+0.10s  FastAPI valida el token y los parámetros del formulario.
T+0.20s  Se crea la base de datos y el usuario.
T+0.35s  Se renderiza la plantilla YAML con los valores del cliente.
T+0.50s  El YAML renderizado se guarda en disco para auditoría.
T+0.60s  kubectl apply -f - aplica el manifiesto completo.
T+0.90s  Kubernetes crea Namespace, ConfigMap, Deployment, Service, Ingress.
T+1.10s  El pod arranca con la imagen saas-php.
T+1.35s  cert-manager detecta el Ingress y solicita el certificado TLS.
T+1.80s  La API responde 303 → redirige al dominio del cliente.
T+30-60s El certificado Let's Encrypt queda emitido y el HTTPS activo.
```

---

## 6. Estructura del repositorio

```text
saas-hosting/
├── apps/
│   ├── api/
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   ├── templates/
│   │   │   └── cliente-template.yaml   ← plantilla YAML con placeholders
│   │   └── app/
│   │       ├── main.py
│   │       ├── settings.py
│   │       ├── auth.py
│   │       ├── db.py
│   │       ├── renderer.py
│   │       └── routers/
│   │           └── deploy.py
│   └── php/
│       └── Dockerfile                  ← imagen base para los clientes
└── web-content/
    └── meu-dashboard/
        └── dashboard.html              ← interfaz de gestión
```

---

## 7. Plantilla YAML del cliente

La plantilla vive en `apps/api/templates/cliente-template.yaml` y contiene placeholders que `renderer.py` sustituye antes de llamar a `kubectl apply`.

### Placeholders que deben sustituirse

| Placeholder | Fuente |
|-------------|--------|
| `__CLIENTE__` | slug normalizado |
| `__NAMESPACE__` | `{prefix}-{cliente}` |
| `__DOMAIN__` | `{cliente}.meu-project.me` |
| `__IMAGE__` | `{registry}/saas-php:{version}` |
| `__TITLE__` | campo `title` del formulario |
| `__THEME__` | campo `theme` del formulario |
| `__CPU_REQ__` | según plan (ej. `100m`) |
| `__CPU_LIM__` | según plan (ej. `500m`) |
| `__MEM_REQ__` | según plan (ej. `128Mi`) |
| `__MEM_LIM__` | según plan (ej. `256Mi`) |
| `__PVC_SIZE__` | según plan (ej. `1Gi`) |

> Los valores de CPU y memoria deben respetar el formato de `resource.Quantity`: `100m`, `128Mi`, `1Gi`. Un valor mal escrito genera el error `quantities must match the regular expression`.

### Recursos que genera la plantilla

- `Namespace`: aísla todos los recursos del cliente.
- `ConfigMap`: inyecta el `index.php` de bienvenida en el pod.
- `Deployment`: ejecuta el contenedor con la imagen PHP y monta el ConfigMap.
- `Service` (ClusterIP): expone el pod internamente en el puerto 80.
- `Ingress`: enruta el dominio del cliente con TLS automático via cert-manager.

### Manifiestos de referencia

#### Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: __CLIENTE__-ingress
  namespace: __NAMESPACE__
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - __DOMAIN__
    secretName: __CLIENTE__-tls
  rules:
  - host: __DOMAIN__
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: __CLIENTE__-service
            port:
              number: 80
```

> `ingressClassName: nginx` es obligatorio. Sin él, el controlador puede ignorar el recurso y servir el certificado fake por defecto.

#### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: __CLIENTE__-service
  namespace: __NAMESPACE__
spec:
  selector:
    app: __CLIENTE__
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: ClusterIP
```

#### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: __CLIENTE__
  namespace: __NAMESPACE__
spec:
  replicas: 1
  selector:
    matchLabels:
      app: __CLIENTE__
  template:
    metadata:
      labels:
        app: __CLIENTE__
    spec:
      nodeSelector:
        role: apps
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: __CLIENTE__
        image: __IMAGE__
        ports:
        - containerPort: 80
        env:
        - name: SITE_TITLE
          value: "__TITLE__"
        - name: SITE_THEME
          value: "__THEME__"
        volumeMounts:
        - name: default-web
          mountPath: /var/www/html/index.php
          subPath: index.php
        resources:
          requests:
            cpu: __CPU_REQ__
            memory: __MEM_REQ__
          limits:
            cpu: __CPU_LIM__
            memory: __MEM_LIM__
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 15
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
      volumes:
      - name: default-web
        configMap:
          name: __CLIENTE__-default-web
```

---

## 8. Código de la API

### `app/renderer.py`

```python
from pathlib import Path
from app.settings import get_settings

settings = get_settings()


def render_template(cliente: str, namespace: str, domain: str, image: str, title: str, theme: str, plan_values: dict) -> str:
    template_path = Path(settings.templates_dir) / "cliente-template.yaml"
    template = template_path.read_text(encoding="utf-8")
    return (
        template
        .replace("__CLIENTE__", cliente)
        .replace("__NAMESPACE__", namespace)
        .replace("__DOMAIN__", domain)
        .replace("__IMAGE__", image)
        .replace("__TITLE__", title)
        .replace("__THEME__", theme)
        .replace("__CPU_REQ__", plan_values["cpureq"])
        .replace("__CPU_LIM__", plan_values["cpulim"])
        .replace("__MEM_REQ__", plan_values["memreq"])
        .replace("__MEM_LIM__", plan_values["memlim"])
        .replace("__PVC_SIZE__", plan_values["pvcsize"])
    )


def write_log(cliente: str, text: str) -> str:
    log_path = Path(settings.logs_dir)
    log_path.mkdir(parents=True, exist_ok=True)
    file_path = log_path / f"{cliente}.log"
    file_path.write_text(text, encoding="utf-8")
    return str(file_path)
```

### `app/routers/deploy.py`

```python
from fastapi import APIRouter, Form, status, Depends, HTTPException
from fastapi.responses import RedirectResponse
from pathlib import Path
import subprocess

from app.auth import verify_api_token
from app.db import create_db_and_user, gen_password, PLANES
from app.renderer import render_template, write_log
from app.settings import get_settings

settings = get_settings()
router = APIRouter(prefix="/api")


def kubectl_apply(manifest: str) -> tuple[int, str, str]:
    result = subprocess.run(
        ["kubectl", "apply", "-f", "-"],
        input=manifest,
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout, result.stderr


def dump_manifest(cliente: str, manifest: str) -> str:
    out_dir = Path(settings.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{cliente}.yaml"
    path.write_text(manifest, encoding="utf-8")
    return str(path)


@router.post("/create")
async def create_site(
    slug: str = Form(...),
    title: str = Form(""),
    theme: str = Form("light"),
    plan: str = Form("basic"),
    version_php: str = Form("8.3"),
    token: str = Depends(verify_api_token),
):
    cliente = slug.strip().lower().replace(" ", "-")
    namespace = f"{settings.kube_namespace_prefix}-{cliente}"
    domain = f"{cliente}.{settings.base_domain}"
    image = f"{settings.registry_url}/saas-php:{version_php}"

    if plan not in PLANES:
        raise HTTPException(status_code=400, detail=f"Plan inválido: {plan}. Usa basic, pro o premium.")

    plan_values = PLANES[plan]
    dbname = f"{cliente}_db"
    dbuser = f"{cliente}_user"
    dbpass = gen_password()

    try:
        create_db_and_user(dbname, dbuser, dbpass)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error creando BD: {e}")

    manifest = render_template(
        cliente=cliente,
        namespace=namespace,
        domain=domain,
        image=image,
        title=title or cliente,
        theme=theme,
        plan_values=plan_values,
    )

    manifest_path = dump_manifest(cliente, manifest)
    returncode, stdout, stderr = kubectl_apply(manifest)
    write_log(cliente, f"manifest={manifest_path}\nstdout={stdout}\nstderr={stderr}\n")

    if returncode != 0:
        raise HTTPException(status_code=500, detail=f"Error aplicando manifest: {stderr}")

    return RedirectResponse(url=f"https://{domain}", status_code=status.HTTP_303_SEE_OTHER)


@router.get("/sites")
async def list_sites(token: str = Depends(verify_api_token)):
    result = subprocess.run(
        ["kubectl", "get", "namespaces", "-l", f"managed-by=saas-api", "-o", "jsonpath={.items[*].metadata.name}"],
        capture_output=True, text=True,
    )
    namespaces = result.stdout.split()
    prefix = settings.kube_namespace_prefix + "-"
    slugs = [ns.removeprefix(prefix) for ns in namespaces if ns.startswith(prefix)]
    return {"sites": slugs}


@router.delete("/delete/{slug}")
async def delete_site(slug: str, token: str = Depends(verify_api_token)):
    from app.db import drop_db_and_user
    cliente = slug.strip().lower()
    namespace = f"{settings.kube_namespace_prefix}-{cliente}"
    dbname = f"{cliente}_db"
    dbuser = f"{cliente}_user"

    subprocess.run(["kubectl", "delete", "namespace", namespace], capture_output=True)

    try:
        drop_db_and_user(dbname, dbuser)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error eliminando BD: {e}")

    return {"status": "deleted", "cliente": cliente}
```

---

## 9. Seguridad y RBAC

`saas-api` no debe correr con la `default` ServiceAccount. Necesita una cuenta propia con permisos explícitos para crear y gestionar los recursos de cada namespace de cliente.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: saas-api-sa
  namespace: meu
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: saas-api-role
rules:
- apiGroups: [""]
  resources: ["namespaces", "configmaps", "secrets", "services", "persistentvolumeclaims", "pods"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: saas-api-rb
subjects:
- kind: ServiceAccount
  name: saas-api-sa
  namespace: meu
roleRef:
  kind: ClusterRole
  name: saas-api-role
  apiGroup: rbac.authorization.k8s.io
EOF
```

Y en el `Deployment` de `saas-api-saas-api`:

```yaml
spec:
  template:
    spec:
      serviceAccountName: saas-api-sa
```

---

## 10. TLS y cert-manager

La publicación externa se realiza con `ingress-nginx` y `cert-manager` mediante ACME HTTP-01. El `ClusterIssuer` `letsencrypt-prod` gestiona la emisión automática y el `Ingress` referencia ese issuer con la anotación `cert-manager.io/cluster-issuer`.

El certificado puede tardar entre 30 y 60 segundos en emitirse la primera vez. Durante ese tiempo el navegador puede mostrar un aviso TLS, que desaparece al completarse el `Certificate` en estado `Ready: True`.

### Limpieza de emisión atascada

Si el certificado queda bloqueado en `Ready: False`:

```bash
kubectl delete certificate,certificaterequest,order,challenge \
  -n cliente-<slug> --all
```

Esto fuerza a cert-manager a reconstruir el flujo de emisión desde cero.

---

## 11. Dashboard

El dashboard es una interfaz HTML estática que consume la API directamente desde el navegador. Está montado como un ConfigMap en el namespace `meu`.

### Funcionalidades

- Formulario de alta de cliente con slug, título, tema, plan y versión PHP.
- Lista de tenants activos consultando `GET /api/sites`.
- Botón de eliminación por tenant via `DELETE /api/delete/{slug}`.
- Overlay de progreso animado durante el despliegue.

### Actualización del ConfigMap

```bash
kubectl create configmap meu-dashboard-html \
  --from-file=index.html=/home/meu_master/saas-hosting/web-content/meu-dashboard/dashboard.html \
  -n meu --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment meu-dashboard -n meu
```

> Nota: `kubectl` no expande `~` en rutas de archivos. Usa siempre la ruta absoluta con `/home/meu_master/...`.

---

## 12. Troubleshooting y lecciones aprendidas

Durante el desarrollo se identificaron y resolvieron los siguientes incidentes:

### 12.1. ImportError en la API al arrancar

**Causa**: el router importaba `write_rendered` desde `app.renderer`, pero esa función no existía en la versión que se estaba usando en la imagen.

**Solución**: quitar `write_rendered` del import y del router. La función equivalente es `dump_manifest()` definida directamente en `deploy.py`.

### 12.2. Ruta de build incorrecta en Docker

**Causa**: al hacer `docker build`, la ruta del contexto no coincidía con las rutas `COPY` del Dockerfile. Si el contexto es `apps/api`, el Dockerfile debe usar `COPY app ./app`, no `COPY apps/api/app ./app`.

**Solución**: lanzar el build desde la raíz del repo con `-f apps/api/Dockerfile` y usar rutas relativas en el Dockerfile.

### 12.3. Namespace inválido en kubectl apply

**Causa**: los placeholders `__NAMESPACE__`, `__CPU_REQ__` y similares no se estaban sustituyendo antes del `kubectl apply`. Kubernetes devuelve `invalid metadata.name` o `quantities must match the regular expression`.

**Solución**: asegurar que `render_template()` sustituye todos los placeholders antes de pasar el YAML a `kubectl_apply()`. Guardar el YAML renderizado en disco permite inspeccionarlo antes del apply.

### 12.4. Certificado fake en lugar del TLS real

**Causa**: el Ingress no tenía `ingressClassName: nginx`. Sin esa clase, el controlador no asociaba el recurso al host esperado y servía el certificado por defecto del controlador (`Kubernetes Ingress Controller Fake Certificate`).

**Verificación**:
```bash
openssl s_client -connect <dominio>:443 -servername <dominio> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

**Solución**: añadir `ingressClassName: nginx` al `spec` del Ingress.

### 12.5. 502 Bad Gateway

**Causa**: el `containerPort` del Deployment y el `targetPort` del Service no coincidían. El contenedor escucha en `80`, pero el Service apuntaba a `8080`.

**Solución**: unificar todo en `80`: `containerPort: 80`, `port: 80`, `targetPort: 80`, `livenessProbe` y `readinessProbe` sobre `80`.

### 12.6. Forbidden en configmaps

**Causa**: `saas-api` corría con la `default` ServiceAccount, que no tiene permisos para hacer `get/create/update` sobre recursos en namespaces de clientes.

**Solución**: crear una `ServiceAccount` propia con `ClusterRole` y `ClusterRoleBinding`, y asignarla al `Deployment` de `saas-api`.

---

## 13. Verificación operativa

```bash
# Estado general de la API
kubectl -n meu get pods
kubectl -n meu logs deploy/saas-api-saas-api --tail=100

# ServiceAccount en uso
kubectl -n meu get deploy saas-api-saas-api -o yaml | grep serviceAccountName

# Estado del cliente recién creado
kubectl -n cliente-<slug> get all
kubectl -n cliente-<slug> get certificate
kubectl -n cliente-<slug> describe ingress

# Verificar TLS emitido
openssl s_client -connect <slug>.meu-project.me:443 \
  -servername <slug>.meu-project.me </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# Ver YAML renderizado del último cliente
cat /mnt/saas/output/<slug>.yaml
```

---

## 14. Diagrama de flujo completo

```text
POST /api/create  (slug, title, theme, plan, version_php, token)
   ↓
Validación de token
   ↓
Normalización del slug → cliente, namespace, domain, image
   ↓
Validación del plan (basic | pro | premium)
   ↓
Creación de BD y usuario en MariaDB
   ↓
render_template() → YAML completo con todos los placeholders sustituidos
   ↓
dump_manifest() → guarda YAML en /mnt/saas/output/{cliente}.yaml
   ↓
kubectl apply -f -
   ↓
Kubernetes crea:
  ├── Namespace: {prefix}-{cliente}
  ├── ConfigMap: {cliente}-default-web  (index.php de bienvenida)
  ├── Deployment: {cliente}             (saas-php:{version})
  ├── Service: {cliente}-service        (ClusterIP :80)
  └── Ingress: {cliente}-ingress        ({cliente}.meu-project.me → TLS)
           ↓
      cert-manager detecta el Ingress
           ↓
      ACME HTTP-01 → Let's Encrypt
           ↓
      Certificate Ready: True
           ↓
      303 → https://{cliente}.meu-project.me
```
