# Lógica: Kubectl

---

## Contexto y justificación

Una vez que la API ya ha creado la base de datos lógica del cliente y ha generado sus credenciales, el siguiente paso es desplegar automáticamente su entorno dentro de Kubernetes. Esa lógica es la encargada de **inyectar los parámetros del cliente** en la plantilla maestra y **aplicar el despliegue** en el clúster.

En otras palabras, esta función actúa como el puente entre la capa de negocio de la API y Kubernetes:

1. La API recibe los datos del nuevo cliente.
2. La API prepara los valores que necesita el despliegue.
3. La API ejecuta el comando de despliegue.
4. Kubernetes crea el namespace, Deployment, Service e Ingress del cliente.

Aunque el nombre de la fase sea **“Lógica: Kubectl”**, en este proyecto la forma más limpia y mantenible es usar **Helm como motor de plantillas** y dejar que Helm renderice y aplique los YAML al clúster. A nivel práctico, la API sigue “hablando con Kubernetes”, pero lo hace a través del chart que ya habéis definido.

---

## Objetivo de esta lógica

La función debe ser capaz de:

- Recibir el nombre del cliente, dominio, imagen y parámetros asociados.
- Inyectar esos valores en la plantilla maestra del chart.
- Crear o actualizar el despliegue del cliente en Kubernetes.
- Devolver a la API un resultado claro: éxito, error y recursos creados.

Esta lógica evita tener que crear YAML manuales para cada cliente y convierte el alta de un cliente en un proceso reproducible, automático y trazable.

---

## ¿Qué recurso crea realmente?

A partir de los parámetros del cliente, esta lógica termina creando:

- Un **Namespace** exclusivo para el cliente.
- Un **Deployment** con el pod que ejecuta la web del cliente.
- Un **Service** de tipo `ClusterIP` para exponer ese pod dentro del clúster.
- Un **Ingress** para enrutar el dominio del cliente.
- Opcionalmente, un **Secret** con credenciales, variables de entorno o configuraciones privadas.

---

## ¿Por qué centralizarlo en la API?

| Enfoque | Problema |
|--------|----------|
| Crear YAML manualmente por cliente | Muy lento, propenso a errores, imposible de escalar |
| Ejecutar `kubectl apply` a mano | No hay automatización real, depende de intervención humana |
| API + función de despliegue | Alta automática, repetible, auditable y fácil de integrar con el resto del SaaS |

Centralizar esta lógica en la API tiene varias ventajas:

- El alta de cliente queda unificada en un solo flujo.
- La API puede validar datos antes de desplegar.
- Se pueden controlar errores y hacer rollback.
- Se puede registrar en logs qué se desplegó, cuándo y para quién.

---

## Flujo completo de creación

```text
POST /clients
   ↓
La API valida nombre, dominio e imagen
   ↓
La API crea la BBDD lógica del cliente
   ↓
La API crea el Secret con credenciales
   ↓
La API ejecuta la lógica de despliegue Kubernetes
   ↓
Helm/Kubernetes crea:
  ├── Namespace
  ├── Deployment
  ├── Service
  └── Ingress
   ↓
El cliente queda accesible por su dominio
```

---

## Arquitectura dentro del proyecto

```text
[Usuario / Panel / API]
        ↓
[Función create_client()]
        ↓
[Función deploy_client_to_k8s()]
        ↓
[Helm chart parametrizado]
        ↓
[Kubernetes]
  ├── Namespace client-acme
  ├── Deployment acme-deployment
  ├── Service acme-service
  └── Ingress acme-ingress
```

---

## Parámetros que la función debe recibir

La función de despliegue necesita, como mínimo, estos datos:

| Parámetro | Descripción | Ejemplo |
|-----------|-------------|---------|
| `client_name` | Nombre corto del cliente | `acme` |
| `domain` | Dominio público del cliente | `acme.meu-project.me` |
| `image` | Imagen Docker que se desplegará | `registry.meu-project.me/saas-php:8.3` |
| `db_secret_name` | Nombre del Secret con credenciales | `acme-db-credentials` |
| `replica_count` | Número de réplicas del pod | `1` |
| `cpu_limit` | Límite de CPU | `250m` |
| `memory_limit` | Límite de memoria | `256Mi` |

En una versión más avanzada, también podría recibir:

- límites de almacenamiento,
- versión de PHP,
- variables de entorno extra,
- rutas personalizadas,
- flags para activar o desactivar features.

---

## Dos formas de aplicar el YAML

### Opción A — Renderizar YAML y aplicar con `kubectl`

Consiste en generar un fichero YAML final con los valores del cliente y luego ejecutar:

```bash
kubectl apply -f cliente-acme.yaml
```

### Opción B — Usar Helm directamente

Consiste en pasar los parámetros al chart y dejar que Helm renderice y aplique todo:

```bash
helm upgrade --install cliente-acme ~/saas-hosting/helm/client-chart \
  --set client.name=acme \
  --set client.domain=acme.meu-project.me \
  --set client.image=registry.meu-project.me/saas-php:8.3
```

### Qué conviene en este proyecto

Como ya tenéis un **YAML Template Maestro con Helm**, lo correcto es usar **Helm** como mecanismo principal. Técnicamente el resultado final sigue siendo aplicar YAML en Kubernetes, pero evitáis:

- plantillas duplicadas,
- sustituciones frágiles con `sed`,
- ficheros temporales difíciles de mantener,
- problemas de versionado.

---

## Función principal `deploy_client_to_k8s`

**Para qué sirve:** Recibe los parámetros del cliente, construye el comando de despliegue y lo ejecuta desde la API. Si el cliente no existe, lo instala; si ya existe, lo actualiza.

```python
import subprocess

def deploy_client_to_k8s(
    client_name: str,
    domain: str,
    image: str,
    db_secret_name: str,
    replica_count: int = 1,
    cpu_request: str = "50m",
    memory_request: str = "64Mi",
    cpu_limit: str = "250m",
    memory_limit: str = "256Mi"
):
    """
    Despliega o actualiza un cliente en Kubernetes usando Helm.

    Args:
        client_name: Nombre corto del cliente (ej: acme)
        domain: Dominio público del cliente
        image: Imagen Docker a desplegar
        db_secret_name: Secret con credenciales de base de datos
        replica_count: Número de réplicas
        cpu_request: CPU mínima garantizada
        memory_request: RAM mínima garantizada
        cpu_limit: CPU máxima permitida
        memory_limit: RAM máxima permitida

    Returns:
        dict con resultado del despliegue
    """

    release_name = f"cliente-{client_name}"
    chart_path = "/root/saas-hosting/helm/client-chart"

    cmd = [
        "helm", "upgrade", "--install", release_name, chart_path,
        "--set", f"client.name={client_name}",
        "--set", f"client.domain={domain}",
        "--set", f"client.image={image}",
        "--set", f"client.dbSecretName={db_secret_name}",
        "--set", f"replicaCount={replica_count}",
        "--set", f"resources.requests.cpu={cpu_request}",
        "--set", f"resources.requests.memory={memory_request}",
        "--set", f"resources.limits.cpu={cpu_limit}",
        "--set", f"resources.limits.memory={memory_limit}"
    ]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True
        )

        return {
            "status": "ok",
            "release": release_name,
            "namespace": f"client-{client_name}",
            "stdout": result.stdout.strip()
        }

    except subprocess.CalledProcessError as e:
        return {
            "status": "error",
            "release": release_name,
            "stderr": e.stderr.strip(),
            "stdout": e.stdout.strip()
        }
```

---

## Qué hace exactamente esta función

| Paso | Acción | Resultado |
|------|--------|-----------|
| 1 | Construye el nombre del release | `cliente-acme` |
| 2 | Apunta al chart maestro | `~/saas-hosting/helm/client-chart` |
| 3 | Inyecta valores con `--set` | Nombre, dominio, imagen, recursos, secret |
| 4 | Ejecuta `helm upgrade --install` | Instala si no existe, actualiza si ya existe |
| 5 | Devuelve un dict con estado | `ok` o `error` |

### Ventaja de `upgrade --install`

En vez de separar “instalar” y “actualizar”, este patrón hace ambas cosas con el mismo comando:

- si el cliente no existe, lo crea;
- si ya existe, lo actualiza.

Esto simplifica muchísimo la lógica de la API.

---

## Plantilla esperada en el chart

Para que la función anterior sirva de verdad, el chart debe soportar esos valores. Por ejemplo, en el `Deployment` podrías tener:

```yaml
spec:
  containers:
    - name: php-nginx
      image: {{ .Values.client.image }}
      envFrom:
        - secretRef:
            name: {{ .Values.client.dbSecretName }}
      resources:
        requests:
          cpu: {{ .Values.resources.requests.cpu }}
          memory: {{ .Values.resources.requests.memory }}
        limits:
          cpu: {{ .Values.resources.limits.cpu }}
          memory: {{ .Values.resources.limits.memory }}
```

Y en `values.yaml`:

```yaml
client:
  name: "default"
  domain: "default.meu-project.me"
  image: "registry.meu-project.me/saas-php:8.3"
  dbSecretName: "default-db-credentials"

resources:
  requests:
    cpu: "50m"
    memory: "64Mi"
  limits:
    cpu: "250m"
    memory: "256Mi"

replicaCount: 1
```

---

## Integración con la función principal de la API

La lógica real del alta de cliente podría quedar así:

```python
def create_client(client_name: str, domain: str):
    """
    Flujo completo de creación de cliente:
    1. Crear BBDD
    2. Crear Secret
    3. Desplegar recursos en Kubernetes
    """

    # 1. Crear base de datos lógica y usuario
    db_credentials = create_client_database(client_name)

    # 2. Crear Secret Kubernetes con credenciales
    secret_name = create_k8s_secret(client_name, db_credentials)

    # 3. Desplegar cliente en Kubernetes
    deploy_result = deploy_client_to_k8s(
        client_name=client_name,
        domain=domain,
        image="registry.meu-project.me/saas-php:8.3",
        db_secret_name=secret_name
    )

    if deploy_result["status"] != "ok":
        raise Exception(f"Error desplegando cliente en Kubernetes: {deploy_result}")

    return {
        "status": "ok",
        "client": client_name,
        "domain": domain,
        "namespace": f"client-{client_name}"
    }
```

---

## Crear el Secret antes del despliegue

Esta lógica solo funciona bien si el Secret con las credenciales existe antes de arrancar el pod. Si el Deployment intenta arrancar referenciando un Secret inexistente, el pod fallará.

Ejemplo de función:

```python
from kubernetes import client, config

def create_k8s_secret(client_name: str, db_credentials: dict):
    """
    Crea el Secret con credenciales del cliente.
    """
    config.load_incluster_config()
    v1 = client.CoreV1Api()

    secret_name = f"{client_name}-db-credentials"
    namespace = f"client-{client_name}"

    secret = client.V1Secret(
        metadata=client.V1ObjectMeta(
            name=secret_name,
            namespace=namespace
        ),
        string_data={
            "DB_HOST": db_credentials["db_host"],
            "DB_PORT": str(db_credentials["db_port"]),
            "DB_NAME": db_credentials["db_name"],
            "DB_USER": db_credentials["db_user"],
            "DB_PASSWORD": db_credentials["db_password"]
        }
    )

    v1.create_namespaced_secret(namespace=namespace, body=secret)
    return secret_name
```

> En una implementación real, el namespace debe existir antes de crear el Secret, o bien el chart debe crear el Secret directamente como parte del despliegue.

---

## Alternativa: renderizar primero y aplicar después

Si quisieras mantener una lógica más cercana a “kubectl puro”, el flujo sería este:

1. La API genera un fichero `values-acme.yaml`.
2. Helm renderiza los manifiestos con `helm template`.
3. La API aplica ese YAML final al clúster.

Ejemplo:

```python
def render_and_apply(client_name: str, values_file: str):
    render_cmd = [
        "helm", "template",
        f"cliente-{client_name}",
        "/root/saas-hosting/helm/client-chart",
        "-f", values_file
    ]

    apply_cmd = ["kubectl", "apply", "-f", "-"]

    render = subprocess.Popen(render_cmd, stdout=subprocess.PIPE, text=True)
    apply = subprocess.run(apply_cmd, stdin=render.stdout, capture_output=True, text=True)

    return {
        "returncode": apply.returncode,
        "stdout": apply.stdout,
        "stderr": apply.stderr
    }
```

### Cuándo usar esta variante

- si quieres inspeccionar el YAML final antes de aplicarlo,
- si necesitas guardar el manifiesto generado,
- si quieres depurar exactamente qué se envía al clúster.

### Cuándo no compensa

- si ya usáis Helm de forma nativa,
- si queréis menos complejidad operativa,
- si no necesitáis conservar el YAML renderizado.

---

## Manejo de errores

La lógica de despliegue debe contemplar varios fallos posibles:

| Error | Causa típica | Acción recomendada |
|------|--------------|-------------------|
| Release falla al instalar | Valor mal pasado o chart inconsistente | Devolver error claro a la API |
| Imagen no existe | Tag incorrecto o registry inaccesible | Cancelar alta y registrar el error |
| Secret ausente | Se creó tarde o falló su creación | No desplegar hasta corregirlo |
| Namespace no existe | Orden incorrecto en la automatización | Crear namespace antes |
| Ingress no obtiene certificado | DNS o cert-manager mal configurado | Cliente creado pero no operativo públicamente |

Ejemplo de patrón defensivo:

```python
def safe_create_client(client_name: str, domain: str):
    try:
        db_credentials = create_client_database(client_name)
        deploy_result = deploy_client_to_k8s(
            client_name=client_name,
            domain=domain,
            image="registry.meu-project.me/saas-php:8.3",
            db_secret_name=f"{client_name}-db-credentials"
        )

        if deploy_result["status"] != "ok":
            raise Exception(deploy_result["stderr"])

        return {"status": "ok"}

    except Exception as e:
        # Aquí podría añadirse rollback:
        # - borrar release helm
        # - borrar namespace
        # - borrar BBDD si procede
        return {"status": "error", "message": str(e)}
```

---

## Verificación manual tras el despliegue

```bash
# Ver el release
helm list -A

# Ver todos los recursos del cliente
kubectl get all -n client-acme

# Ver el ingress
kubectl get ingress -n client-acme

# Ver eventos del namespace
kubectl get events -n client-acme --sort-by=.metadata.creationTimestamp

# Ver logs del pod
kubectl logs -n client-acme deployment/acme-deployment

# Ver descripción detallada
kubectl describe deployment acme-deployment -n client-acme
kubectl describe service acme-service -n client-acme
kubectl describe ingress acme-ingress -n client-acme
```

---

## Qué debería verse si todo ha ido bien

- Existe un release `cliente-acme`.
- Existe el namespace `client-acme`.
- El Deployment tiene al menos un pod en estado `Running`.
- El Service apunta al pod correcto.
- El Ingress tiene la regla para `acme.meu-project.me`.
- El pod recibe las variables del Secret.
- El dominio termina sirviendo la web del cliente.

---

## Rollback y eliminación

Si el despliegue falla o el cliente se da de baja, la API debe poder deshacerlo.

### Eliminar release

```bash
helm uninstall cliente-acme
```

### Borrar namespace

```bash
kubectl delete namespace client-acme
```

### Posible rollback automático

Si la BBDD ya se creó pero Kubernetes falló, la API puede:

1. borrar el release Helm,
2. borrar el namespace,
3. borrar el usuario y la base de datos lógica,
4. devolver error controlado.

---

## Diagrama de flujo completo

```text
POST /clients
   ↓
La API valida datos de entrada
   ↓
create_client_database(client_name)
   ↓
create_k8s_secret(client_name, db_credentials)
   ↓
deploy_client_to_k8s(client_name, domain, image, db_secret_name)
   ↓
helm upgrade --install cliente-acme ...
   ↓
Kubernetes crea:
  ├── Namespace client-acme
  ├── Deployment acme-deployment
  ├── Service acme-service
  └── Ingress acme-ingress
   ↓
cert-manager emite certificado
   ↓
Cliente disponible en https://acme.meu-project.me
```

---

## Resumen funcional de la fase

Esta fase convierte la creación de un cliente en una operación automática dentro del clúster. La API deja de depender de pasos manuales y pasa a tener una función que:

- recibe parámetros,
- los inyecta en la plantilla maestra,
- despliega recursos en Kubernetes,
- controla errores,
- y devuelve un resultado reutilizable por el resto del sistema.

Es, en la práctica, la pieza que une la lógica de negocio del SaaS con la infraestructura real donde vive cada cliente.