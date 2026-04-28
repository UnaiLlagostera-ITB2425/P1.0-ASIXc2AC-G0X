# Desplegar clúster MariaDB
## Descripción
Despliegue de MariaDB como recurso gestionado dentro del clúster K3s mediante un StatefulSet y un PVC, para garantizar estabilidad de identidad de pod y persistencia de datos. Esta tarea se ejecuta desde el nodo Master de Erick y se integra con la base de datos centralizada desplegada en la EC2 DDBB de Manuel (10.2.2.154).

## Contexto de la arquitectura
La BBDD centralizada ya está operativa en la EC2 dedicada de Manuel:
| Elemento         | Valor                                              |
| ---------------- | -------------------------------------------------- |
| Instancia        | ec2-ddbb — t3.small, subred privada 10.2.2.0/24    |
| IP privada       | 10.2.2.154                                         |
| Puerto           | 3306                                               |
| Base de datos    | plataforma_hosting                                 |
| Usuario          | meu_admin                                          |
| Acceso permitido | 10.2.2.%, 10.0.%, 10.1.% (tras VPC Peering activo) |
| Almacenamiento   | EBS gp3 10 GiB montado en /var/lib/mysql           |

## Decisiones aplicadas
   - El StatefulSet se despliega en el clúster K3s del Master (Cuenta A).
   - La persistencia real de datos no recae sobre el PVC de Kubernetes, sino sobre el EBS gp3 de la EC2 DDBB de Manuel.
   - El PVC actúa como referencia lógica dentro del clúster para mantener compatibilidad con el patrón StatefulSet estándar de Kubernetes.
   - El acceso a MariaDB desde los pods se realiza a través de un Service + Endpoints externo apuntando a 10.2.2.154:3306 por VPC Peering.
   - Longhorn y NFS descartados — overhead innecesario en el entorno Educate con instancias de poca RAM.

## Prerrequisitos antes de desplegar
   - Secret mariadb-credentials aplicado con kubectl apply -f secret-mariadb.yaml
   - ConfigMap mariadb-config aplicado con kubectl apply -f configmap-mariadb.yaml
   - VPC Peering pcx-A-C activo y Route Tables configuradas
   - Puerto 3306 abierto en Security Group DDBB desde 10.0.0.0/16
   - Usuario meu_admin@10.0.% creado en MariaDB (ya hecho)
   - Los manifiestos **secret-mariadb.yaml** y **configmap-mariadb.yaml** han sido preparados por Manuel como artefactos de integración para el clúster K3s. Su creación y configuración se documenta en el documento de configuración de instancia MariaDB.

## Manifiesto Service + Endpoints externo (k8s/database/mariadb-external-service.yaml)
Para que los pods del clúster puedan conectarse a la EC2 DDBB de Manuel:
```sql
CUANDO ME LO PASO ERICK
```

## Manifiesto StatefulSet + PVC (k8s/database/mariadb-statefulset.yaml)
A desplegar por Erick desde el Master:
```sql
CUANDO ME LO PASO ERICK
```

## Estado
   - Secret mariadb-credentials aplicado — kubectl apply -f secret-mariadb.yaml
   - ConfigMap mariadb-config aplicado — kubectl apply -f configmap-mariadb.yaml
   - Manifiesto Service + Endpoints externo desplegado
   - Manifiesto StatefulSet + PVC desplegado
   - Conectividad verificada desde pod al MariaDB de la EC2 DDBB (10.2.2.154:3306)