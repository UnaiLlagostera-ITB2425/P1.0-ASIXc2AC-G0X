# Frontend & Autenticación LDAP

---

## 1 — Visión general del sistema

`meu-project` es una plataforma SaaS de hosting gestionado multi-tenant sobre Kubernetes. El acceso al panel de administración está protegido por autenticación centralizada vía OpenLDAP.

### Arquitectura de autenticación

```
Usuario (navegador)
        │
        │  HTTPS  →  meu-project.me
        ▼
┌─────────────────────────────────────┐
│         Nginx Ingress Controller    │
│         (namespace: ingress-nginx)  │
│                                     │
│  /auth/*     → meu-api-svc:8001     │
│  /dashboard  → meu-dashboard-svc:80 │
│  /           → meu-web-svc:80       │
└────────────────┬────────────────────┘
                 │
       ┌─────────┴──────────┐
       │                    │
       ▼                    ▼
┌─────────────┐    ┌──────────────────┐
│  meu-web    │    │    meu-api       │
│  nginx:alp  │    │  FastAPI :8001   │
│  (landing)  │    │  (auth + API)    │
└─────────────┘    └────────┬─────────┘
                            │  LDAP bind
                            ▼
                   ┌──────────────────┐
                   │   OpenLDAP       │
                   │  10.2.2.191:389  │
                   │  dc=meu,dc=local │
                   └──────────────────┘
```


## 2 — Infraestructura Kubernetes — namespace `meu`

### 2.1 Pods en ejecución

```
NAME                             READY  STATUS   NODE
meu-api-6f57ddbcf-b48xd          1/1    Running  worker3         (10.244.182.58)
meu-dashboard-6cb7464c5f-k22j6   1/1    Running  k8s-submaster   (10.244.147.22)
meu-web-6cbb9b9f-rlmlr           1/1    Running  ip-10-0-1-228   (10.244.43.75)
```

### 2.2 Services y endpoints

| Service | ClusterIP | Puerto | Selector | Endpoint real |
|---|---|---|---|---|
| `meu-web-svc` | 10.102.243.154 | 80 | `app=meu-web` | 10.244.43.75:80 |
| `meu-api-svc` | 10.104.60.1 | 8001 | `app=meu-api` | 10.244.182.58:8001 |
| `meu-dashboard-svc` | 10.99.109.19 | 80 | `app=meu-dashboard` | 10.244.147.22:80 |

Todos los Services son de tipo `ClusterIP` — solo accesibles internamente, expuestos al exterior únicamente a través del Ingress.

### 2.3 Deployment `meu-web`

Sirve el frontend estático (`index.html`) desde un `nginx:alpine`. El HTML se inyecta vía ConfigMap montado como volumen:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: meu-web
  namespace: meu
spec:
  replicas: 1
  selector:
    matchLabels:
      app: meu-web
  template:
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
          resources:
            limits:
              cpu: "100m"
              memory: "128Mi"
      volumes:
        - name: html
          configMap:
            name: meu-web-html
```

El ConfigMap `meu-web-html` contiene la clave `index.html` con el contenido completo de la landing. Para actualizar la web:

```bash
# Recrear el ConfigMap con el HTML nuevo
kubectl create configmap meu-web-html \
  --from-file=index.html=/ruta/al/index.html \
  -n meu --dry-run=client -o yaml | kubectl apply -f -

# Forzar recarga del pod
kubectl rollout restart deployment/meu-web -n meu
```

### 2.4 Deployment `meu-api`

Contiene la lógica de autenticación LDAP y la API REST. La imagen se obtiene del registry interno del clúster:

```
Imagen: 10.2.2.191:5000/meu-api:latest
Puerto: 8001
```

Para publicar una nueva versión de la imagen:

```bash
# En la máquina de build
docker build -t 10.2.2.191:5000/meu-api:latest .
docker push 10.2.2.191:5000/meu-api:latest

# En el master, forzar pull de la nueva imagen
kubectl rollout restart deployment/meu-api -n meu
```

### 2.5 ConfigMap `meu-web-html`

Almacena el `index.html` completo de la landing. Verificado que está correctamente montado:

```
Volumen tipo: ConfigMap
Clave: index.html
Punto de montaje: /usr/share/nginx/html
```

Comprobación directa del contenido:

```bash
kubectl describe configmap meu-web-html -n meu | head -20
```

---

## 3 — Directorio OpenLDAP

### 3.1 Servidor

| Parámetro | Valor |
|---|---|
| Host | `10.2.2.191` (privado, no expuesto a internet) |
| Puerto | `389` (LDAP plano, solo red interna) |
| Base DN | `dc=meu,dc=local` |
| Sistema operativo | Ubuntu 24.04.4 LTS |

### 3.2 Árbol de directorio

```
dc=meu,dc=local
└── ou=People,dc=meu,dc=local
    ├── uid=admin,ou=People,dc=meu,dc=local
    └── uid=demo,ou=People,dc=meu,dc=local
```

Verificado con:

```bash
ldapsearch -x -H ldap://localhost \
  -D "uid=admin,ou=People,dc=meu,dc=local" \
  -w <password> \
  -b "dc=meu,dc=local" | grep "dn:"
```

Resultado esperado y confirmado:

```
dn: dc=meu,dc=local
dn: ou=People,dc=meu,dc=local
dn: uid=demo,ou=People,dc=meu,dc=local
dn: uid=admin,ou=People,dc=meu,dc=local
```

### 3.3 Usuarios

| uid | DN completo | Rol |
|---|---|---|
| `admin` | `uid=admin,ou=People,dc=meu,dc=local` | Administrador con acceso al panel |
| `demo` | `uid=demo,ou=People,dc=meu,dc=local` | Usuario de pruebas |

> **Nota:** El bind manager `cn=admin,dc=meu,dc=local` tiene contraseña distinta a la instalación por defecto (`admin123`). Este DN **no se usa** en el flujo de autenticación de usuarios y puede ignorarse. El flujo usa bind directo con el DN del usuario.

### 3.4 Patrón de bind para autenticación

El backend construye el DN dinámicamente a partir del `username` recibido en el body del POST:

```
uid=<username>,ou=People,dc=meu,dc=local
```

Ejemplo para el usuario `admin`:

```
uid=admin,ou=People,dc=meu,dc=local
```

El bind LDAP funciona como mecanismo de autenticación: si el servidor acepta el bind con ese DN y esa contraseña, las credenciales son válidas. No se requiere ninguna búsqueda adicional.

### 3.5 Verificación manual del LDAP desde el master

```bash
ssh -i ~/.ssh/Key-BD.pem meu_db1@10.2.2.191

ldapsearch -x -H ldap://localhost \
  -D "uid=admin,ou=People,dc=meu,dc=local" \
  -w <password> \
  -b "dc=meu,dc=local"
```

> ⚠️ **Error documentado:** Durante el desarrollo inicial se intentó usar `dc=meu-project,dc=me` como base DN. Este árbol **no existe** en el servidor. El árbol correcto y único es `dc=meu,dc=local`. Cualquier referencia a `dc=meu-project,dc=me` en el código es incorrecta y debe ser eliminada.

---

## 4 — Frontend — Landing page (`index.html`)

### 4.1 Descripción

El frontend es una página HTML5 autocontenida en un único archivo `index.html`. No tiene dependencias de build, framework JavaScript ni empaquetador. Se sirve directamente desde `nginx:alpine` a través del ConfigMap.

### 4.2 Estructura del documento

```
index.html
├── <head>
│   ├── Metaetiquetas (charset, viewport)
│   ├── Google Fonts (Space Grotesk, JetBrains Mono)
│   └── <style> ─ sistema de diseño completo con CSS custom properties
│
└── <body>
    ├── Skip link de accesibilidad (#main-content)
    ├── <nav> ─ barra de navegación sticky
    │   ├── Logo SVG + nombre "meu·project"
    │   └── Links: Plataforma · Arquitectura · Stack · [Acceder →]
    │
    ├── <main id="main-content">
    │   ├── .hero ─ titular, subtítulo, CTA primario y secundario
    │   ├── .stats ─ 4 badges: Kubernetes v1.30 · PHP 8.3 · TLS auto · NFS+PVC
    │   ├── #plataforma ─ grid 2×3 de features con iconos
    │   ├── .divider
    │   ├── #arquitectura ─ diagrama de flujo + tarjetas de capa
    │   ├── .divider
    │   └── #stack ─ chips con las 12 tecnologías del stack
    │
    ├── <footer> ─ indicador de estado + branding
    ├── #loginOverlay ─ modal de autenticación (role="dialog")
    └── <script> ─ lógica del modal y llamada fetch al backend
```

### 4.3 Sistema de diseño — CSS Custom Properties

El archivo usa variables CSS como única fuente de verdad visual:

```css
:root {
  /* Fondos */
  --bg:       #080a0e;   /* Fondo base de la página */
  --surface:  #0d1017;   /* Cards, modal */
  --surface2: #131720;   /* Hover states, inputs */

  /* Bordes */
  --border:  rgba(255,255,255,0.07);
  --border2: rgba(255,255,255,0.13);

  /* Tipografía */
  --text:  #dde1ea;   /* Texto principal */
  --muted: #6b7280;   /* Texto secundario */
  --faint: #353a42;   /* Placeholders */

  /* Colores de acento */
  --teal:  #2dd4bf;   /* Primario — acciones, highlights */
  --blue:  #60a5fa;   /* Secundario — badges LDAP, nodos arch */
  --green: #4ade80;   /* Éxito, estado operativo */
  --red:   #f87171;   /* Error, mensajes de fallo */

  /* Variantes semitransparentes */
  --teal-dim:  rgba(45,212,191,0.10);
  --blue-dim:  rgba(96,165,250,0.10);
  --green-dim: rgba(74,222,128,0.10);
  --red-dim:   rgba(248,113,113,0.10);

  /* Escala de border-radius */
  --r-sm: 6px;   /* botones pequeños */
  --r-md: 10px;  /* inputs, botones principales */
  --r-lg: 16px;  /* sin uso directo, disponible */
  --r-xl: 22px;  /* cards, modal, features grid */
}
```

### 4.4 Responsividad

Breakpoint único en `640px`:

| Elemento | Desktop | Mobile (≤640px) |
|---|---|---|
| `nav` | `padding: 14px 40px` | `padding: 12px 20px` |
| `.nav-link` | Visible | Oculto (`display: none`) |
| `.hero` | `padding: 100px 40px 80px` | `padding: 60px 20px` |
| `.stats` | Fila horizontal | Columna vertical |
| `.section` | `padding: 0 40px 80px` | `padding: 0 20px 60px` |
| `.modal` | Centrado, max-width 400px | `margin: 20px`, padding reducido |
| `footer` | Fila horizontal | Columna vertical |

### 4.5 Accesibilidad (WCAG)

| Medida | Implementación |
|---|---|
| Skip link | Visible al recibir foco, salta a `#main-content` |
| Landmark nav | `role="navigation"` + `aria-label="Navegación principal"` |
| Modal accesible | `role="dialog"` + `aria-modal="true"` + `aria-labelledby="modal-title"` |
| Listas semánticas | `role="list"` / `role="listitem"` en stats y chips |
| Diagrama | `role="img"` + `aria-label` descriptivo |
| Inputs requeridos | `aria-required="true"` en username y password |
| Mensajes en vivo | `role="alert"` + `aria-live="assertive"` en `#loginMsg` |
| Focus automático | Al abrir el modal, foco en `#username` tras 100ms |
| Escape para cerrar | `document.addEventListener('keydown', ...)` |
| Decorativos | `aria-hidden="true"` en todos los SVGs e iconos emoji |

---

## 5 — Modal de autenticación

### 5.1 Estructura HTML

```html
<!-- Overlay: clic fuera cierra el modal -->
<div class="overlay" id="loginOverlay"
     onclick="handleOverlayClick(event)"
     role="dialog" aria-modal="true" aria-labelledby="modal-title">

  <div class="modal" id="loginModal">
    <button class="modal-close" onclick="closeLogin()">✕</button>

    <!-- Cabecera del modal -->
    <div class="modal-logo">...</div>
    <div class="ldap-badge">OpenLDAP auth</div>
    <div class="modal-title" id="modal-title">Acceder al panel</div>
    <div class="modal-sub">Introduce tus credenciales de directorio</div>

    <!-- Formulario -->
    <div class="form-group">
      <label for="username">Usuario (uid LDAP)</label>
      <input type="text" id="username"
             placeholder="p.ej. jdoe"
             autocomplete="username"
             onkeydown="handleKey(event)"
             aria-required="true">
    </div>
    <div class="form-group">
      <label for="password">Contraseña</label>
      <input type="password" id="password"
             placeholder="••••••••"
             autocomplete="current-password"
             onkeydown="handleKey(event)"
             aria-required="true">
    </div>

    <!-- Botón con spinner integrado -->
    <button class="btn-submit" id="submitBtn" onclick="doLogin()">
      <span id="btnText">Iniciar sesión</span>
      <div class="spinner" id="spinner"></div>
    </button>

    <!-- Feedback al usuario -->
    <div class="login-msg" id="loginMsg" role="alert" aria-live="assertive"></div>

    <div class="login-footer">Acceso restringido · Solo administradores</div>
  </div>
</div>
```

### 5.2 Estados del formulario

```
Estado IDLE (inicial)
├── submitBtn.disabled = false
├── #btnText: visible ("Iniciar sesión")
└── #spinner: oculto

Estado LOADING (enviando request)
├── submitBtn.disabled = true   ← previene doble envío
├── #btnText: display: none
└── #spinner: visible + animación spin 0.6s

Estado ERROR (credenciales incorrectas / red)
├── submitBtn.disabled = false
├── #loginMsg.className = "login-msg error"
├── #loginMsg.textContent = mensaje del backend o "Error de conexión..."
├── password.value = ""         ← se limpia por seguridad
└── focus → input#password

Estado SUCCESS (autenticación correcta)
├── #loginMsg.className = "login-msg success"
├── #loginMsg.textContent = "✓ Autenticado. Redirigiendo..."
└── setTimeout 800ms → window.location.href = data.redirect
```

### 5.3 Funciones JavaScript

```javascript
openLogin()
// Añade clase .open al #loginOverlay
// Bloquea scroll del body (document.body.style.overflow = 'hidden')
// Focus en #username tras 100ms

closeLogin()
// Elimina clase .open
// Restaura scroll del body
// Llama a resetForm() → limpia campos y estado

handleOverlayClick(e)
// Cierra el modal SOLO si el click es sobre el propio overlay
// (no sobre el .modal interior)

handleKey(e)
// Si e.key === 'Enter' → llama doLogin()
// Activo en ambos inputs (username y password)

// Listener global:
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') closeLogin()
})

resetForm()
// Vacía username.value y password.value
// Elimina clases de #loginMsg (lo oculta)
// Llama a setLoading(false)

setLoading(loading: boolean)
// true:  deshabilita botón, oculta texto, muestra spinner
// false: habilita botón, muestra texto, oculta spinner

showMsg(type: 'error' | 'success', text: string)
// Asigna className = 'login-msg ' + type
// Escribe el texto en #loginMsg
// CSS muestra/oculta el elemento según la clase
```

### 5.4 Función `doLogin()` — flujo completo

```javascript
async function doLogin() {
  // 1. Validación client-side
  const user = document.getElementById('username').value.trim()
  const pass = document.getElementById('password').value
  if (!user || !pass) {
    showMsg('error', 'Introduce usuario y contraseña.')
    return
  }

  // 2. Activar estado loading
  setLoading(true)
  showMsg('', '')

  try {
    // 3. POST al endpoint del backend
    const res = await fetch('/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: user, password: pass })
    })

    // 4. Parseo defensivo del JSON
    let data
    try {
      data = await res.json()
    } catch (_) {
      throw new Error('Respuesta inesperada del servidor.')
    }

    // 5a. Éxito
    if (res.ok && data.ok) {
      showMsg('success', '✓ Autenticado. Redirigiendo...')
      setTimeout(() => {
        window.location.href = data.redirect || '/dashboard'
      }, 800)

    // 5b. Error de negocio (401, credenciales inválidas)
    } else {
      showMsg('error', data.error || 'Credenciales incorrectas.')
      setLoading(false)
      document.getElementById('password').value = ''
      document.getElementById('password').focus()
    }

  } catch (err) {
    // 5c. Error de red o respuesta no parseable
    showMsg('error', 'Error de conexión. Inténtalo de nuevo.')
    setLoading(false)
  }
}
```

**Decisiones de seguridad UX:**
- La contraseña se borra en caso de error (nunca queda en el DOM)
- El botón se deshabilita durante la petición (previene doble envío)
- Los mensajes de error no exponen información técnica del servidor
- El redirect usa `data.redirect` del servidor, con fallback a `/dashboard`

---

## 6 — API de autenticación — `meu-api`

### 6.1 Descripción

`meu-api` es el servicio backend que implementa la lógica de autenticación contra OpenLDAP. Está construido con FastAPI (Python) y corre en el puerto `8001` dentro del namespace `meu`.

- **Imagen:** `10.2.2.191:5000/meu-api:latest`
- **Service:** `meu-api-svc` → `ClusterIP:10.104.60.1:8001`
- **Endpoint activo:** `10.244.182.58:8001`
- **Acceso externo:** Solo a través de Ingress en la ruta `/auth/*`

### 6.2 Endpoint `POST /auth/login`

**Estado verificado:** Operativo. Devuelve 401 con credenciales incorrectas y 200 con credenciales correctas.

#### Request

```http
POST /auth/login
Host: meu-project.me
Content-Type: application/json

{
  "username": "admin",
  "password": "contraseña_del_usuario"
}
```

#### Response — Éxito (HTTP 200)

```json
{
  "ok": true,
  "redirect": "/dashboard"
}
```

#### Response — Credenciales incorrectas (HTTP 401)

```json
{
  "ok": false,
  "error": "Credenciales incorrectas."
}
```

#### Response — Error de directorio LDAP (HTTP 503)

```json
{
  "ok": false,
  "error": "Error de directorio. Inténtalo más tarde."
}
```

### 6.3 Lógica LDAP en el backend

El backend realiza un **bind directo** con las credenciales recibidas. No se usa una cuenta de servicio intermediaria:

```
1. Recibe { username, password }
2. Construye DN: uid=<username>,ou=People,dc=meu,dc=local
3. Intenta bind LDAP contra ldap://10.2.2.191:389
4. Bind exitoso (código 0)  → devuelve { ok: true, redirect: "/dashboard" }
5. Bind fallido (código 49) → devuelve { ok: false, error: "Credenciales incorrectas." }
6. Sin conexión LDAP        → devuelve { ok: false, error: "Error de directorio." }
```

Ejemplo de implementación de referencia con `ldap3`:

```python
from ldap3 import Server, Connection, SIMPLE, ALL
from ldap3.core.exceptions import LDAPBindError, LDAPSocketOpenError

LDAP_HOST   = "ldap://10.2.2.191"
BASE_DN     = "dc=meu,dc=local"
PEOPLE_OU   = "ou=People"

def authenticate(username: str, password: str) -> dict:
    user_dn = f"uid={username},{PEOPLE_OU},{BASE_DN}"
    server  = Server(LDAP_HOST, get_info=ALL)

    try:
        conn = Connection(
            server,
            user=user_dn,
            password=password,
            authentication=SIMPLE,
            auto_bind=True    # lanza LDAPBindError si falla
        )
        conn.unbind()
        return {"ok": True, "redirect": "/dashboard"}

    except LDAPBindError:
        return {"ok": False, "error": "Credenciales incorrectas."}

    except LDAPSocketOpenError:
        return {"ok": False, "error": "Error de directorio. Inténtalo más tarde."}
```

### 6.4 Variables de entorno recomendadas

Para no hardcodear parámetros LDAP en el código:

```bash
LDAP_HOST=ldap://10.2.2.191
LDAP_BASE_DN=dc=meu,dc=local
LDAP_PEOPLE_OU=ou=People
```

En el Deployment de Kubernetes:

```yaml
env:
  - name: LDAP_HOST
    value: "ldap://10.2.2.191"
  - name: LDAP_BASE_DN
    value: "dc=meu,dc=local"
  - name: LDAP_PEOPLE_OU
    value: "ou=People"
```

### 6.5 Verificación del endpoint desde línea de comandos

```bash
# Credenciales incorrectas → debe devolver 401
curl -sk -o /dev/null -w "%{http_code}" \
  https://meu-project.me/auth/login \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"test","password":"test"}'
# Output esperado: 401

# Credenciales correctas → debe devolver 200
curl -sk \
  https://meu-project.me/auth/login \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<password>"}'
# Output esperado: {"ok":true,"redirect":"/dashboard"}
```

---

## 7 — API Dashboard — *(pendiente de implementación)*

> ** Esta sección está reservada para ser completada por el compañero responsable de la API de dashboard.**
>
> A continuación se documenta el estado actual y el contrato que debe cumplirse para que la integración con el frontend sea completa.

### 7.1 Estado actual

El Deployment `meu-dashboard` está corriendo con `nginx:alpine` como imagen provisional. Sirve una página placeholder en `/dashboard`. El Service `meu-dashboard-svc` está activo y el Ingress ya lo enruta correctamente:

```
https://meu-project.me/dashboard → meu-dashboard-svc:80 → pod meu-dashboard
```

### 7.2 Lo que hay que implementar

El compañero debe sustituir la imagen de `meu-dashboard` por la aplicación real del panel y exponer los endpoints necesarios. El frontend ya redirige correctamente a `/dashboard` tras una autenticación exitosa gracias al campo `redirect` de la respuesta de `meu-api`.

### 7.3 Contrato de integración esperado

El dashboard debe cumplir los siguientes requisitos mínimos para integrarse con el sistema existente:

**Ruta de acceso:**

```
GET https://meu-project.me/dashboard
```

Debe devolver la interfaz del panel de administración (HTML o SPA).

**Gestión de sesión:**

La API `meu-api` devuelve actualmente solo `{ ok: true, redirect: "/dashboard" }`. Si se requiere sesión autenticada en el dashboard (cookie, JWT, etc.), hay que acordar con `meu-api` el mecanismo:

| Opción | Descripción |
|---|---|
| Cookie de sesión | `meu-api` emite `Set-Cookie` en el 200, el dashboard la valida |
| JWT en redirect | `meu-api` incluye un token en la URL de redirect |
| Sin sesión | El dashboard es público una vez dentro de la red (opción más simple para MVP) |

**Endpoints que deberá exponer (a definir por el compañero):**

```
# Placeholder — completar con la API real
GET  /dashboard              → Página principal del panel
GET  /dashboard/api/...      → Endpoints de la API del dashboard
POST /dashboard/api/...      → Operaciones de gestión
```

### 7.4 Para actualizar el Deployment del dashboard

Cuando la imagen esté lista en el registry:

```bash
# Actualizar imagen
kubectl set image deployment/meu-dashboard \
  nginx=10.2.2.191:5000/meu-dashboard:latest \
  -n meu

# O con un nuevo manifiesto
kubectl apply -f meu-dashboard-deployment.yaml

# Verificar
kubectl rollout status deployment/meu-dashboard -n meu
kubectl get pods -n meu -l app=meu-dashboard
```

### 7.5 Notas para el compañero

- El Ingress usa `pathType: Prefix` para `/dashboard`, así que todas las subrutas (`/dashboard/algo`) también llegarán al service.
- El Service `meu-dashboard-svc` escucha en el puerto `80`. Si la app corre en otro puerto, hay que actualizar el Service.
- El namespace es `meu`. Todos los recursos deben crearse en ese namespace.
- TLS está gestionado por cert-manager con Let's Encrypt. No hace falta configurar SSL en la app.

---

## 8 — Flujo end-to-end verificado

### 8.1 Flujo normal (autenticación exitosa)

```
1. Usuario abre https://meu-project.me
   └─ Nginx Ingress → meu-web-svc → nginx:alpine
   └─ Responde con index.html desde ConfigMap 

2. Usuario pulsa "Acceder al panel" o "Acceder →"
   └─ JavaScript: openLogin() → #loginOverlay.classList.add('open')
   └─ Modal visible, foco en input#username 

3. Usuario introduce uid=admin + contraseña y pulsa Enter o el botón
   └─ doLogin(): validación client-side OK
   └─ setLoading(true): spinner visible, botón deshabilitado

4. fetch('POST /auth/login', { username, password })
   └─ Ingress: /auth → meu-api-svc:8001
   └─ meu-api: construye DN uid=admin,ou=People,dc=meu,dc=local
   └─ LDAP bind contra 10.2.2.191:389 → éxito 

5. meu-api responde HTTP 200:
   └─ { "ok": true, "redirect": "/dashboard" }

6. Frontend:
   └─ showMsg('success', '✓ Autenticado. Redirigiendo...')
   └─ setTimeout 800ms → window.location.href = '/dashboard'

7. Ingress: /dashboard → meu-dashboard-svc:80
   └─ Panel del dashboard (actualmente placeholder) 
```

### 8.2 Flujo de error (credenciales incorrectas)

```
1-3. Igual que el flujo normal.

4. fetch('POST /auth/login', { username, password })
   └─ meu-api: bind LDAP falla (código 49)
   └─ Responde HTTP 401: { "ok": false, "error": "Credenciales incorrectas." }

5. Frontend:
   └─ showMsg('error', 'Credenciales incorrectas.')
   └─ setLoading(false)
   └─ password.value = ''
   └─ focus → input#password
   └─ El modal sigue abierto, el usuario puede reintentar 
```

### 8.3 Flujo de error (red / servidor caído)

```
4. fetch('/auth/login') lanza excepción (timeout, ECONNREFUSED, etc.)
   └─ catch(err): showMsg('error', 'Error de conexión. Inténtalo de nuevo.')
   └─ setLoading(false)
   └─ El modal sigue abierto 
```

---

## 9 — Ingress — Enrutamiento HTTP/S

### 9.1 Manifiesto del Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: meu-web-ingress
  namespace: meu
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
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
          - path: /auth
            pathType: Prefix
            backend:
              service:
                name: meu-api-svc
                port:
                  number: 8001
          - path: /dashboard
            pathType: Prefix
            backend:
              service:
                name: meu-dashboard-svc
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: meu-web-svc
                port:
                  number: 80
    - host: www.meu-project.me
      http:
        paths:
          # Mismas reglas para el host www
          ...
```

### 9.2 Tabla de enrutamiento

| Path | Tipo | Service destino | Puerto |
|---|---|---|---|
| `/auth/*` | Prefix | `meu-api-svc` | 8001 |
| `/dashboard*` | Prefix | `meu-dashboard-svc` | 80 |
| `/` (resto) | Prefix | `meu-web-svc` | 80 |

> **Orden de evaluación:** Nginx Ingress evalúa las rutas por especificidad descendente. `/auth` y `/dashboard` tienen prioridad sobre `/`.

### 9.3 TLS

- **Emisor:** `cert-manager` con ClusterIssuer `letsencrypt-prod`
- **Secret:** `meu-project-tls` (namespace `meu`)
- **Hosts cubiertos:** `meu-project.me` y `www.meu-project.me`
- **Redirección HTTP→HTTPS:** Activa (`ssl-redirect: "true"`)

---

## 10 — Errores conocidos y decisiones de diseño

### 10.1 DN incorrecto en comentario del código fuente

**Problema:** El script del `index.html` contiene un comentario con el DN `uid=<username>,ou=people,dc=meu-project,dc=me`. Este DN no existe en el servidor LDAP real.

**Estado:** Solo es un comentario; no afecta al comportamiento en producción porque la lógica LDAP está implementada en el backend (`meu-api`), no en el frontend.

**Acción recomendada:** Actualizar el comentario para reflejar el DN correcto (`dc=meu,dc=local`) en la próxima edición del archivo.

### 10.2 `ImagePullBackOff` en despliegue inicial de `meu-api`

**Problema:** El primer Deployment de `meu-api` usó `image: meu-api:latest` con `imagePullPolicy: IfNotPresent`. En un clúster multinodo, la imagen local solo existe en el nodo donde se construyó. Si el pod se programa en otro nodo, falla con `ImagePullBackOff`.

**Solución aplicada:** Se cambió la imagen a `10.2.2.191:5000/meu-api:latest` (registry interno del clúster). Todos los nodos pueden tirar la imagen desde ahí.

**Estado actual:**  Resuelto. El pod está Running desde el registry interno.

### 10.3 ConfigMap creado desde ruta incorrecta

**Problema:** Durante el despliegue inicial se intentó crear el ConfigMap con `--from-file=index.html=/mnt/user-data/uploads/meu-project-index.html`. Esa ruta no existe en el servidor.

**Solución aplicada:** El HTML se copió a `~/index.html` con `nano` y el ConfigMap se creó con `--from-file=index.html=/home/meu_master/index.html`.

**Estado actual:**  Resuelto. ConfigMap correctamente montado en el pod.

### 10.4 Contraseña del bind manager (`cn=admin`)

El DN `cn=admin,dc=meu,dc=local` tiene la contraseña por defecto cambiada. No se usa en el flujo de autenticación de usuarios (el bind es directo con el uid del usuario), así que no afecta a la operativa del sistema.

---
