# Desplegar Clúster MariaDB en Kubernetes

## 1. Descripción

Despliegue de MariaDB como recurso gestionado dentro del clúster K3s mediante un **StatefulSet** y un **PVC**, para garantizar estabilidad de identidad de pod y persistencia de datos. Esta tarea se ejecuta desde el nodo Master y se integra con la base de datos centralizada desplegada en la EC2 DDBB de Manuel (`10.2.2.154`).

---

## 2. Contexto de la arquitectura

| Elemento         | Valor                                                |
|------------------|------------------------------------------------------|
| Instancia        | ec2-ddbb — t3.small, subred privada 10.2.2.0/24      |
| IP privada       | 10.2.2.154                                           |
| Puerto           | 3306                                                 |
| Base de datos    | plataforma_hosting                                   |
| Usuario          | meu_admin                                            |
| Acceso permitido | 10.2.2.%, 10.0.%, 10.1.% (VPC Peering activo)        |
| Almacenamiento   | EBS gp3 10 GiB montado en /var/lib/mysql             |

---

## 3. Decisiones aplicadas

- El StatefulSet se despliega en el clúster K3s del Master (Cuenta A).
- La persistencia real de datos **no** recae sobre el PVC de Kubernetes, sino sobre el **EBS gp3 de la EC2 DDBB**.
- El PVC actúa como referencia lógica dentro del clúster para mantener compatibilidad con el patrón StatefulSet estándar de Kubernetes.
- El acceso a MariaDB desde los pods se realiza a través de un **Service + Endpoints externo** apuntando a `10.2.2.154:3306` por VPC Peering.

---

## 4. StorageClass — Verificación

```bash
kubectl get storageclass
```

Salida esperada:
```
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

> **WaitForFirstConsumer** es el comportamiento correcto — el PVC permanece en `Pending` hasta que un pod lo solicite, evitando que el volumen se cree en el nodo incorrecto.

### Test de funcionamiento del StorageClass

```bash
# 1. Crear PVC de prueba
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 100Mi
EOF

# 2. Crear pod que lo use para forzar el binding
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-pvc-pod
spec:
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "echo OK > /data/test.txt && cat /data/test.txt"]
    volumeMounts:
    - mountPath: /data
      name: vol
  volumes:
  - name: vol
    persistentVolumeClaim:
      claimName: test-pvc
  restartPolicy: Never
EOF

# 3. Verificar resultado
kubectl logs test-pvc-pod
# → OK ✅

# 4. Limpiar
kubectl delete pod test-pvc-pod
kubectl delete pvc test-pvc
```

---

## 5. Prerrequisitos

Verificar todos los puntos antes de desplegar:

- [ ] Secret `mariadb-credentials` aplicado: `kubectl apply -f secret-mariadb.yaml`
- [ ] ConfigMap `mariadb-config` aplicado: `kubectl apply -f configmap-mariadb.yaml`
- [ ] VPC Peering pcx-A-C activo y Route Tables configuradas
- [ ] Puerto 3306 abierto en Security Group DDBB desde `10.0.0.0/8`
- [ ] Usuario `meu_admin@10.0.%` creado en MariaDB

> Los manifiestos `secret-mariadb.yaml` y `configmap-mariadb.yaml` son preparados por Manuel como artefactos de integración. Su creación se documenta en el **Manual de Secrets BBDD y ConfigMap**.

### Verificar conectividad antes de desplegar

```bash
# Desde el Master
bash -c "timeout 5 bash -c 'echo > /dev/tcp/10.2.2.154/3306' && echo 'CONECTADO' || echo 'TIMEOUT'"

# Desde un pod en el clúster (más fiable — simula el entorno real)
kubectl run test-conn --image=busybox --rm -it --restart=Never -- \
  sh -c "timeout 5 sh -c 'echo > /dev/tcp/10.2.2.154/3306' && echo CONECTADO || echo TIMEOUT"
```

---

## 6. Manifiesto Service + Endpoints externo

**Archivo:** `k8s/database/mariadb-external-service.yaml`

Permite que los pods del clúster resuelvan `mariadb-externo` y se conecten a la EC2 DDBB sin hardcodear la IP en el código de la aplicación.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mariadb-externo
  namespace: default
spec:
  type: ClusterIP
  ports:
  - port: 3306
    targetPort: 3306
    protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: mariadb-externo
  namespace: default
subsets:
- addresses:
  - ip: 10.2.2.154
  ports:
  - port: 3306
```

```bash
kubectl apply -f k8s/database/mariadb-external-service.yaml

# Verificar que el endpoint apunta a la IP correcta
kubectl describe service mariadb-externo
# Endpoints: 10.2.2.154:3306
```

---

## 7. Manifiesto StatefulSet + PVC

**Archivo:** `k8s/database/mariadb-statefulset.yaml`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: meu-project
  namespace: default
spec:
  serviceName: "mariadb"
  replicas: 1
  selector:
    matchLabels:
      app: meu-project
  template:
    metadata:
      labels:
        app: meu-project
    spec:
      containers:
      - name: mariadb
        image: mariadb:10.11
        ports:
        - containerPort: 3306
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mariadb-credentials
              key: MARIADB_ROOT_PASSWORD
        - name: MYSQL_DATABASE
          value: plataforma_hosting
        - name: MYSQL_USER
          valueFrom:
            secretKeyRef:
              name: mariadb-credentials
              key: MARIADB_USER
        - name: MYSQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mariadb-credentials
              key: MARIADB_PASSWORD
        volumeMounts:
        - name: mariadb-data
          mountPath: /var/lib/mysql
        - name: mariadb-config
          mountPath: /etc/mysql/conf.d/custom.cnf
          subPath: my.cnf
      volumes:
      - name: mariadb-config
        configMap:
          name: mariadb-config
  volumeClaimTemplates:
  - metadata:
      name: mariadb-data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: local-path
      resources:
        requests:
          storage: 2Gi
```

```bash
kubectl apply -f k8s/database/mariadb-statefulset.yaml

# Seguir el arranque
kubectl get pods -w
# meu-project-0   0/1   ContainerCreating   ...
# meu-project-0   1/1   Running             
```

---

## 8. Verificación de conectividad

```bash
# Verificar que el pod puede acceder a MariaDB externo
kubectl exec -it meu-project-0 -- sh -c \
  "apk add --no-cache mariadb-client 2>/dev/null && \
   mariadb -h 10.2.2.154 -u meu_admin -p plataforma_hosting -e 'SELECT 1;'"

# Alternativa más rápida con netcat
kubectl exec -it meu-project-0 -- sh -c \
  "timeout 5 sh -c 'echo > /dev/tcp/10.2.2.154/3306' && echo CONECTADO || echo TIMEOUT"
```

---

## 9. Estado del despliegue

- [x] Secret `mariadb-credentials` aplicado
- [x] ConfigMap `mariadb-config` aplicado
- [x] Manifiesto Service + Endpoints externo desplegado
- [x] Manifiesto StatefulSet + PVC desplegado
- [x] Conectividad verificada desde pod al MariaDB de la EC2 DDBB (`10.2.2.154:3306`)

---

# Secrets BBDD y ConfigMap

## 1. Descripción

Creación de los artefactos de configuración y credenciales para la base de datos centralizada:

- **Secret** — credenciales sensibles cifradas en base64, consumidas por el StatefulSet de Kubernetes.
- **ConfigMap** — parámetros de conexión y archivo `my.cnf` optimizado para la EC2 t3.small de 2 GB de RAM.

La tarea se divide en dos partes:
- **Manuel** — configura el servidor MariaDB y prepara los manifiestos como artefactos de integración.
- **Erick** — aplica los manifiestos en el clúster K3s.

---

## 2. Configuración del servidor — my.cnf

**Archivo:** `/etc/mysql/mariadb.conf.d/50-server.cnf`, bloque `[mariadb]`

```ini
[mariadb]
skip-name-resolve
collation-server             = utf8mb4_unicode_ci
innodb_buffer_pool_size      = 512M
innodb_buffer_pool_instances = 1
innodb_file_per_table        = 1
max_connections              = 80
tmp_table_size               = 64M
max_heap_table_size          = 64M
```

### Justificación de parámetros

| Parámetro                      | Valor              | Motivo                                                          |
|--------------------------------|--------------------|-----------------------------------------------------------------|
| `skip-name-resolve`            | ON                 | Evita resolución DNS inversa en red privada con VPC Peering     |
| `collation_server`             | utf8mb4_unicode_ci | Coherencia con el esquema `plataforma_hosting`                  |
| `innodb_buffer_pool_size`      | 512M               | Conservador para 2 GB de RAM — estabilidad primero              |
| `innodb_buffer_pool_instances` | 1                  | Suficiente para ese tamaño de buffer pool                       |
| `innodb_file_per_table`        | ON                 | Un fichero `.ibd` por tabla — facilita backups y purgas         |
| `max_connections`              | 80                 | Moderado para evitar consumo excesivo en t3.small               |
| `tmp_table_size`               | 64M                | Equilibrado para consultas temporales sin disparar RAM          |
| `max_heap_table_size`          | 64M                | Coherente con `tmp_table_size`                                  |

---

## 3. Pasos de configuración en ec2-ddbb

```bash
# 1. Copia de seguridad del archivo original
sudo cp /etc/mysql/mariadb.conf.d/50-server.cnf \
     /etc/mysql/mariadb.conf.d/50-server.cnf.bak

# 2. Editar el archivo y añadir el bloque [mariadb]
sudo nano /etc/mysql/mariadb.conf.d/50-server.cnf

# 3. Reinicio del servicio
sudo systemctl restart mariadb
sudo systemctl status mariadb
# → active (running)  
```

### Verificación de variables aplicadas

```sql
-- Ejecutar dentro de MariaDB
SHOW VARIABLES LIKE 'skip_name_resolve';         -- ON
SHOW VARIABLES LIKE 'collation_server';          -- utf8mb4_unicode_ci
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';   -- 536870912 (512 MB)
SHOW VARIABLES LIKE 'max_connections';           -- 80
SHOW VARIABLES LIKE 'tmp_table_size';            -- 67108864 (64 MB)
SHOW VARIABLES LIKE 'innodb_file_per_table';     -- ON
```

---

## 4. Secret — secret-mariadb.yaml

Los valores deben estar codificados en **base64**. Nunca escribir contraseñas en texto plano en los manifiestos.

```bash
# Generar los valores base64
echo -n "password_root_aqui" | base64
echo -n "meu_admin" | base64
echo -n "password_usuario_aqui" | base64
```

**Archivo:** `k8s/secrets/secret-mariadb.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mariadb-credentials
  namespace: default
type: Opaque
data:
  MARIADB_ROOT_PASSWORD: <base64_root_password>
  MARIADB_USER: <base64_usuario>
  MARIADB_PASSWORD: <base64_password>
```

```bash
# Aplicar en el clúster (ejecutar desde el Master)
kubectl apply -f k8s/secrets/secret-mariadb.yaml

# Verificar — muestra metadatos, NO los valores en claro
kubectl get secret mariadb-credentials
kubectl describe secret mariadb-credentials
```

Salida esperada:
```
Name:         mariadb-credentials
Namespace:    default
Type:         Opaque
Data
====
MARIADB_PASSWORD:       20 bytes
MARIADB_ROOT_PASSWORD:  20 bytes
MARIADB_USER:           9 bytes
```

> **Seguridad:** No commitear el archivo `secret-mariadb.yaml` al repositorio con valores reales. Añadirlo al `.gitignore` o usar herramientas como **Sealed Secrets** o **External Secrets Operator** en entornos de producción.

---

## 5. ConfigMap — configmap-mariadb.yaml

**Archivo:** `k8s/configmaps/configmap-mariadb.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mariadb-config
  namespace: default
data:
  my.cnf: |
    [mariadb]
    skip-name-resolve
    collation-server             = utf8mb4_unicode_ci
    innodb_buffer_pool_size      = 512M
    innodb_buffer_pool_instances = 1
    innodb_file_per_table        = 1
    max_connections              = 80
    tmp_table_size               = 64M
    max_heap_table_size          = 64M
  DB_HOST: "10.2.2.154"
  DB_PORT: "3306"
  DB_NAME: "plataforma_hosting"
```

```bash
# Aplicar en el clúster (ejecutar desde el Master)
kubectl apply -f k8s/configmaps/configmap-mariadb.yaml

# Verificar
kubectl get configmap mariadb-config
kubectl describe configmap mariadb-config
```

### Uso en el StatefulSet

El ConfigMap se monta como archivo en el contenedor de MariaDB:

```yaml
# Fragmento del StatefulSet
volumeMounts:
- name: mariadb-config
  mountPath: /etc/mysql/conf.d/custom.cnf
  subPath: my.cnf

volumes:
- name: mariadb-config
  configMap:
    name: mariadb-config
```

---

## 6. Estado

- [x] `my.cnf` aplicado y verificado en EC2 DDBB
- [x] MariaDB reiniciado correctamente — `active (running)`
- [x] Todos los parámetros verificados con `SHOW VARIABLES`
- [x] `secret-mariadb.yaml` preparado y entregado a Erick
- [x] `configmap-mariadb.yaml` preparado y entregado a Erick
- [x] `kubectl apply -f secret-mariadb.yaml` — aplicado en clúster
- [x] `kubectl apply -f configmap-mariadb.yaml` — aplicado en clúster

---