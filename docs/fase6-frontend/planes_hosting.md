## Soporte a Planes de Hosting (dinámico)

### Descripción

La API permite asignar **recursos computacionales (CPU/RAM) dinámicamente** según el plan de hosting elegido por el cliente. El plan se envía en el JSON de la petición `POST /provision` y la API lo pasa al script `new-client.sh`, que inyecta los límites en el Deployment de Kubernetes.

Esta funcionalidad reemplaza los recursos fijos (`resources: {}`) por valores configurables por plan, sin necesidad de modificar el template YAML manualmente.

### Planes disponibles

Actualmente hay tres niveles, ajustados para entornos con recursos limitados (máquinas pequeñas):

| Plan       | CPU request | CPU limit | RAM request | RAM limit | Disco (PVC) * |
|------------|-------------|-----------|-------------|-----------|---------------|
| **basic**  | `5m`        | `25m`     | `32Mi`      | `64Mi`    | No usado      |
| **pro**    | `10m`       | `50m`     | `64Mi`      | `128Mi`   | No usado      |
| **enterprise** | `20m`  | `100m`    | `128Mi`     | `256Mi`   | No usado      |

> *La persistencia de datos se gestiona exclusivamente en la base de datos MariaDB externa. Por tanto, no se utilizan volúmenes locales (ni PVC ni hostPath). Los pods son **stateless** por diseño.

### Modo de uso

En la petición de creación de cliente, incluir el campo `"plan"`:

```bash
curl -X POST https://api.meu-project.me/provision \
  -H "Content-Type: application/json" \
  -d '{
    "nombre_web": "acme",
    "version_php": "8.3",
    "db_name": "db_acme",
    "plan": "enterprise"
  }'
Si no se envía el campo plan, se usa "basic" por defecto.

Verificación de recursos asignados
Para comprobar que el pod tiene los límites correspondientes al plan:

bash
kubectl describe pod -n cliente-acme | grep -A5 "Limits\|Requests"
Salida esperada para plan enterprise:

text
Limits:
  cpu:     100m
  memory:  256Mi
Requests:
  cpu:     20m
  memory:  128Mi
Personalización de los valores de los planes
Si se necesitan ajustes (por ejemplo, máquinas más potentes o recursos diferentes), editar el script new-client.sh y modificar las variables dentro del case:

bash
nano ~/saas-hosting/scripts/new-client.sh
Ejemplo para cambiar el plan pro a CPU=200m, RAM=512Mi:

bash
  pro)
    CPU_REQ="100m"; CPU_LIM="200m"; MEM_REQ="256Mi"; MEM_LIM="512Mi"
    ;;
Luego reiniciar la API: sudo systemctl restart saas-api.

Notas de implementación
La lógica de selección de recursos se implementa en new-client.sh mediante un case sobre la variable $PLAN.

El template YAML (cliente-template.yaml) contiene las variables __CPU_REQ__, __CPU_LIM__, __MEM_REQ__, __MEM_LIM__ que son sustituidas por sed en tiempo de ejecución.

No se requiere modificar el main.py para añadir nuevos planes más allá de cambiar los valores en el script.

El flujo completo (incluyendo la creación de la base de datos) sigue siendo el mismo, solo se han añadido los límites de recursos al pod.

text

Así ya tienes **un documento independiente y autocontenido** que puedes añadir como apéndice o como nueva sección en tu documentación principal. Si prefieres que lo integre completamente con el documento anterior, dímelo y lo reescribo.