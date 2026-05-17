# Planes de Hosting — MEU
 
## Estado actual
 
La plataforma MEU implementa un sistema de aprovisionamiento automático de recursos por plan. Cuando se crea un nuevo cliente mediante la API, se le asignan límites de CPU y RAM dentro del clúster Kubernetes según el plan contratado. La base de datos MariaDB y el dominio con certificado HTTPS se configuran automáticamente en el mismo proceso.
 
### Planes disponibles
 
| Plan | CPU (request / limit) | RAM (request / limit) |
|---|---|---|
| **Basic** | 5m / 25m | 32Mi / 64Mi |
| **Pro** | 10m / 50m | 64Mi / 128Mi |
| **Enterprise** | 20m / 100m | 128Mi / 256Mi |
 
> Los valores están ajustados para el entorno actual de la plataforma. Se pueden modificar en `new-client.sh` sin tocar el código de la API.
 
### Qué incluye el aprovisionamiento automático
 
Al crear un cliente con su plan correspondiente, la API realiza automáticamente:
 
- Creación del namespace dedicado en Kubernetes.
- Despliegue del pod del sitio web con los límites de recursos del plan.
- Creación de la base de datos MariaDB asociada al cliente.
- Configuración del dominio y emisión del certificado HTTPS mediante Cert-Manager y Let's Encrypt.
### Qué NO está implementado aún
 
Los siguientes elementos están definidos como objetivo pero no están operativos en la versión actual:
 
- **Almacenamiento persistente por plan (PVC):** Los pods son stateless. La persistencia de datos se gestiona exclusivamente en la base de datos MariaDB externa. No se utilizan volúmenes locales por diseño del entorno actual.
- **Límites de almacenamiento web diferenciados por plan:** No hay cuotas de disco configuradas. Es una mejora pendiente.
- **Copias de seguridad automáticas:** No implementadas. Objetivo futuro con Velero + S3.
- **Panel de cliente con autogestión:** No implementado. Las gestiones las realiza el equipo de administración bajo petición.
- **Número de dominios por plan:** La diferenciación por plan no está implementada a nivel de restricción automática.
---
 
## Objetivo de evolución de los planes
 
El objetivo a medio plazo es que cada plan ofrezca las siguientes capacidades, una vez que la infraestructura lo permita:
 
| Característica | **Basic** | **Pro** | **Enterprise** |
|---|---|---|---|
| CPU / RAM | 25m / 64Mi | 50m / 128Mi | 100m / 256Mi |
| Almacenamiento web | 1 GB | 5 GB | 20 GB |
| Bases de datos | 1 · 256 MB | 2 · 1 GB | 5 · 5 GB |
| Dominios | 1 | 2 | 5 |
| Certificado HTTPS | ✓ | ✓ | ✓ |
| Copias de seguridad | Semanal | Diaria | Diaria · 30 días |
| Panel de autogestión | ✓ | ✓ | ✓ |
| Soporte | 48 h | 24 h | 8 h |
 
---
 
## Uso técnico
 
Para provisionar un cliente con un plan concreto:
 
```bash
curl -X POST https://api.meu-project.me/provision \
  -H "Content-Type: application/json" \
  -d '{
    "nombre_web": "acme",
    "version_php": "8.3",
    "db_name": "db_acme",
    "plan": "enterprise"
  }'
```
 
Si no se envía el campo `plan`, se aplica `basic` por defecto.
 
Para verificar los recursos asignados al pod:
 
```bash
kubectl describe pod -n cliente-acme | grep -A5 "Limits\|Requests"
```
 
Para modificar los valores de un plan, editar el `case` correspondiente en `new-client.sh`:
 
```bash
nano ~/saas-hosting/scripts/new-client.sh
```
 
Tras cualquier cambio, reiniciar la API:
 
```bash
sudo systemctl restart saas-api
```
