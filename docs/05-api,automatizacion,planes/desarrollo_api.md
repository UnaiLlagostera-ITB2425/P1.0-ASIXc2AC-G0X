## Desarrollo de API Hosting

## 1. Objetivo del sistema

El objetivo de esta solución es automatizar por completo el aprovisionamiento de un nuevo cliente SaaS, reduciendo un proceso manual de aproximadamente 15 minutos a una operación automatizada de menos de 2 segundos. Antes de esta implementación, el alta de un cliente implicaba editar manifiestos de Kubernetes de forma manual, crear recursos con `kubectl`, preparar la base de datos externa, configurar DNS y esperar la emisión del certificado TLS. Ese flujo era costoso, frágil y dependía de intervención técnica continua.

La API implementada elimina esa dependencia operativa y convierte el alta de cliente en una acción única y reproducible mediante HTTP. El sistema resultante permite crear el entorno completo de un cliente con namespaces aislados, almacenamiento persistente, despliegue web y publicación HTTPS sin pasos manuales adicionales.

## 2. Criterios de diseño

Se eligió **FastAPI** como capa de exposición HTTP porque ofrece validación nativa con Pydantic y generación automática de documentación OpenAPI/Swagger, lo que simplifica la definición formal del contrato de entrada. En un sistema de aprovisionamiento como este, la validación de estructura es crítica, ya que la API recibe datos de cliente, imagen, base de datos y almacenamiento que deben ser consistentes desde el primer momento.

Para la capa de orquestación interna se adoptó un modelo híbrido: Python para la lógica de negocio y herramientas nativas de Kubernetes/Helm para las operaciones de infraestructura. Esta decisión evita reimplementar en Python la lógica de idempotencia, renderizado y aplicación de recursos que ya resuelven bien `kubectl apply` y Helm, y mantiene además una trazabilidad clara durante el diagnóstico operativo.

## 3. Arquitectura funcional

La arquitectura final queda organizada en cuatro bloques principales:

- API FastAPI: recibe el `POST` de alta y valida la petición.
- Orquestación Kubernetes: crea namespace y PVC por cliente.
- Helm chart: despliega la aplicación con el claim existente.
- Ingress + cert-manager: publica el servicio por HTTPS con certificado gestionado automáticamente.

La separación de responsabilidades es importante: la API crea y controla los recursos de ciclo de vida del cliente, mientras que Helm solo despliega el workload y referencia un `PersistentVolumeClaim` ya existente. Esto evita duplicación de storage y reduce la complejidad del chart.

## 4. Flujo de aprovisionamiento

El flujo operativo validado finalmente fue el siguiente:

```text
T+0.00s  Ingress recibe la petición HTTPS.
T+0.10s  FastAPI valida la carga JSON con Pydantic.
T+0.20s  Se crea el namespace del cliente.
T+0.35s  Se crea el PersistentVolumeClaim.
T+0.60s  Helm instala o actualiza el release.
T+0.90s  Kubernetes crea Deployment y Service.
T+1.10s  El pod arranca y ejecuta el initContainer.
T+1.35s  cert-manager gestiona el Certificate si es necesario.
T+1.80s  El cliente queda accesible por HTTPS.
```

En la práctica, el tiempo de provisión dejó de depender de tareas manuales y pasó a depender de la latencia real del clúster y de la emisión de recursos por Kubernetes y cert-manager.

## 5. Decisiones de almacenamiento

Se adoptó un modelo de **PVC por cliente**. La API es la única responsable de crear el `PersistentVolumeClaim`, mientras que el chart de Helm utiliza ese almacenamiento mediante `storage.existingClaim`. Esto evita duplicidades y deja un único responsable claro del ciclo de vida del volumen.

Además, el `Deployment` monta el volumen en `/var/www/html` y el `initContainer` inicializa el contenido base del cliente dentro de ese almacenamiento. Esta estrategia permite persistencia real entre reinicios y actualizaciones del release.

## 6. Alineación de puertos

Uno de los puntos críticos detectados durante la validación fue la discrepancia entre el puerto del contenedor y el del `Service`. El backend real escucha en `80`, por lo que el chart quedó ajustado de forma consistente: `containerPort: 80`, `livenessProbe` y `readinessProbe` sobre `80`, y `Service` con `port: 80` y `targetPort: 80`. Esa coherencia es esencial para que ingress-nginx enrute correctamente y no devuelva `502 Bad Gateway`.

## 7. Seguridad y TLS

La publicación externa se realiza con `ingress-nginx` y `cert-manager` mediante ACME HTTP-01. El `ClusterIssuer` `letsencrypt-prod` gestiona la emisión automática del certificado y el `Ingress` referencia ese issuer mediante la anotación correspondiente. Con ello, el sistema puede emitir y renovar certificados sin intervención manual.

Durante la depuración, se identificó un estado atascado en la emisión ACME que dejó el certificado temporalmente no válido. La resolución consistió en limpiar los recursos de emisión bloqueados para permitir que cert-manager reconstruyera `Certificate`, `Order` y `Challenge` hasta alcanzar el estado `Ready: True`.

## 8. Manifiestos de referencia

### Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cliente01-ingress
  namespace: cliente01
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: 64m
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - cliente01.meu-project.me
      secretName: cliente01-tls
  rules:
    - host: cliente01.meu-project.me
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cliente01-svc
                port:
                  number: 80
```

### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cliente01-svc
  namespace: cliente01
  labels:
    app: cliente01
spec:
  selector:
    app: cliente01
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cliente01-app
  namespace: cliente01
  labels:
    app: cliente01
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cliente01
  template:
    metadata:
      labels:
        app: cliente01
    spec:
      initContainers:
        - name: init-static
          image: busybox
          command:
            - sh
            - -c
            - |
              [ -f /data/index.php ] || echo '<?php echo "<h1>cliente01</h1><p>Sube tus ficheros via SFTP.</p>";' > /data/index.php
          volumeMounts:
            - name: web-storage
              mountPath: /data
      containers:
        - name: php-apache
          image: 10.2.2.191:5000/saas-php:8.3
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
          envFrom:
            - secretRef:
                name: cliente01-db-secret
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
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
          volumeMounts:
            - name: web-storage
              mountPath: /var/www/html
      volumes:
        - name: web-storage
          persistentVolumeClaim:
            claimName: cliente01-pvc
```

### PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cliente01-pvc
  namespace: cliente01
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-k8s
  resources:
    requests:
      storage: 1Gi
```

## 9. Implementación de la API

La API final quedó estructurada como un endpoint `POST /deploy` que recibe una petición validada con modelos Pydantic y desencadena el proceso completo de aprovisionamiento. El módulo `main.py` importa la lógica de Kubernetes desde `app.k8s`, donde se centralizan la creación de namespace, la creación de PVC y la composición del comando Helm.

La ruta de Helm quedó definida sobre `/home/meu_master/saas-hosting/helm/saas-app`, que es donde se encuentra realmente `Chart.yaml`. El chart se invoca con `storage.existingClaim=cliente01-pvc` y `storage.create=false`, evitando así que Helm cree un segundo PVC.

### `app/main.py`

```python
from fastapi import FastAPI
from pydantic import BaseModel
from app.k8s import create_namespace, create_pvc, render_helm_command
import subprocess

app = FastAPI()

class Client(BaseModel):
    name: str
    domain: str
    type: str

class Image(BaseModel):
    name: str
    tag: str

class DB(BaseModel):
    host: str
    name: str
    user: str
    password: str

class Storage(BaseModel):
    size: str
    storageClass: str

class DeployRequest(BaseModel):
    client: Client
    image: Image
    db: DB
    storage: Storage

@app.post("/deploy")
def deploy(data: DeployRequest):
    namespace = data.client.name
    ns = create_namespace(namespace)
    pvc = create_pvc(namespace, data.client.name, data.storage.size, data.storage.storageClass)
    cmd = render_helm_command(data.model_dump())
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)

    if result.returncode != 0:
        return {"ok": False, "error": result.stderr, "namespace": ns.stderr, "pvc": pvc.stderr}

    return {"ok": True, "stdout": result.stdout, "namespace": ns.stdout, "pvc": pvc.stdout}
```

### `app/k8s.py`

```python
from pathlib import Path
import subprocess

CHART_PATH = Path("/home/meu_master/saas-hosting/helm/saas-app")

def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def create_namespace(namespace):
    return run(f"kubectl create namespace {namespace} --dry-run=client -o yaml | kubectl apply -f -")

def create_pvc(namespace, client_name, size, storage_class):
    pvc_name = f"{client_name}-pvc"
    yaml = f"""apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {pvc_name}
  namespace: {namespace}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: {storage_class}
  resources:
    requests:
      storage: {size}
"""
    return run(f"kubectl apply -f - <<'EOF'\n{yaml}EOF")

def render_helm_command(data):
    release = data['client']['name']
    namespace = data['client']['name']
    pvc_name = f"{data['client']['name']}-pvc"

    return (
        f"helm upgrade --install {release} {CHART_PATH} -n {namespace} "
        f"--set client.name={release} "
        f"--set client.domain={data['client']['domain']} "
        f"--set client.type={data['client']['type']} "
        f"--set image.name={data['image']['name']} "
        f"--set image.tag={data['image']['tag']} "
        f"--set db.host={data['db']['host']} "
        f"--set db.name={data['db']['name']} "
        f"--set db.user={data['db']['user']} "
        f"--set db.password={data['db']['password']} "
        f"--set storage.existingClaim={pvc_name} "
        f"--set storage.create=false"
    )
```

## 10. Validación final

La validación realizada confirmó que el pod queda en `Ready`, que el volumen se monta correctamente, que el contenido inicial se escribe en el PVC y que el acceso final por HTTPS funciona sin errores de certificado. El resultado visible en navegador muestra el contenido del cliente servido correctamente, lo que valida extremo a extremo la cadena completa de aprovisionamiento.

## 11. Conclusión

La solución final transforma un proceso manual, repetitivo y propenso a fallo en una plataforma de aprovisionamiento automatizada, formal y escalable. La combinación de FastAPI, Pydantic, Helm, Kubernetes, ingress-nginx y cert-manager permite ofrecer clientes SaaS completos de forma consistente y con una carga operativa muy inferior a la del modelo original.

## 12. Troubleshooting y validación operativa

Durante el desarrollo de la solución se identificaron varios incidentes funcionales que afectaban a distintas capas del sistema: importación de módulos en la API, resolución de rutas del chart de Helm, divergencia de puertos entre Service y Deployment, emisión de certificados TLS y discrepancias entre el backend y la exposición pública del servicio. La resolución de estos incidentes permitió validar el comportamiento extremo a extremo de la plataforma y consolidar una configuración final estable.

### 12.1. Errores de importación en la API

El primer bloque de incidencias estuvo relacionado con la puesta en marcha de la API FastAPI. Inicialmente se intentó ejecutar el servicio con una implementación que importaba Flask, lo que provocó un `ModuleNotFoundError` al no estar instalada esa dependencia en el entorno virtual. Posteriormente, al migrar a FastAPI, surgió un segundo problema de importación por estructura de paquetes, ya que `uvicorn` no encontraba el módulo `k8s` en la ruta esperada. La corrección consistió en homogeneizar la estructura del proyecto, ubicar los módulos bajo `app/` y utilizar imports absolutos del tipo `from app.k8s import ...`, además de asegurar que el entorno virtual activado contenía las dependencias necesarias.

### 12.2. Ruta del chart de Helm

Una vez resuelta la API, se detectó un fallo al ejecutar Helm desde Python: el chart se estaba invocando como `./chart`, pero el directorio real del repositorio se encontraba en `/home/meu_master/saas-hosting/helm/saas-app`. Este problema generaba el error `path "./chart" not found`. La corrección fue sustituir la ruta relativa por la ruta absoluta real del chart, garantizando así que `helm upgrade --install` siempre pudiera localizar `Chart.yaml` con independencia del directorio de ejecución de la API.

### 12.3. Desalineación de puertos

El incidente más relevante a nivel de red ocurrió por una desalineación entre el puerto del contenedor, el Service y las probes del Deployment. El contenedor `php-apache` y la aplicación web interna escuchaban en `80`, pero el Service inicialmente traducía el tráfico hacia `8080`, lo que provocaba `502 Bad Gateway` desde ingress-nginx. La resolución fue uniformar todos los componentes en el puerto `80`: `containerPort: 80`, `port: 80`, `targetPort: 80`, así como `livenessProbe` y `readinessProbe` también sobre `80`. Esta corrección eliminó el error de gateway y permitió que el pod alcanzara el estado `Ready`.

### 12.4. Persistencia y PVC duplicado

En la primera iteración del chart existía un riesgo de duplicación de recursos de almacenamiento: el PVC podía ser creado por la API y también por Helm. Para evitar conflictos de ownership, se decidió que la API fuera la única responsable de crear el PersistentVolumeClaim, mientras que el chart solo haría referencia a ese recurso mediante `storage.existingClaim`. El archivo `pvc.yaml` del chart quedó condicionado o directamente eliminado según la versión de despliegue, evitando así que Kubernetes intentara gestionar dos recursos con la misma finalidad.

### 12.5. Problemas de TLS y cert-manager

En la capa de publicación externa, el certificado TLS emitido por cert-manager pasó por un estado intermedio inconsistente. Aunque el `Challenge` HTTP-01 llegó a validarse correctamente, el `Certificate` quedó temporalmente en `Ready: False` debido a un `Order` erróneo que no finalizó de manera limpia. La solución fue eliminar los recursos ACME atascados —`Certificate`, `CertificateRequest`, `Order` y `Challenge`— para forzar una nueva emisión desde cero. Tras esta limpieza, el certificado pasó a `Ready: True` y el dominio comenzó a servir HTTPS correctamente.

### 12.6. Verificación final del sistema

La validación final se realizó en tres niveles. Primero, desde dentro del pod se comprobó que la aplicación respondía correctamente en `127.0.0.1`, y que el contenido inicial del cliente se había escrito dentro del volumen montado. Segundo, a nivel de Kubernetes, se verificó que el Service devolvía endpoints correctos en `80` y que el Deployment estaba estable en estado `Running` y `Ready`. Tercero, desde el navegador, se confirmó el acceso al dominio mediante HTTPS con certificado válido y contenido servido correctamente. Esta cadena de validación permitió confirmar que la arquitectura completa era funcional y coherente.
