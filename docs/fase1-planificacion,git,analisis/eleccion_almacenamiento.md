# Elección de Almacenamiento
## Introducción y Objetivo
Los contenedores en Kubernetes son efímeros por naturaleza: si un pod se reinicia o se reprograma en otro nodo, pierde todos sus datos internos. Para garantizar que la información persiste independientemente del ciclo de vida de los contenedores, es necesario definir una estrategia de almacenamiento persistente.

En este proyecto, la capa de persistencia recae principalmente sobre MariaDB, desplegado en un nodo EC2 dedicado (EC2 DDBB) fuera del clúster K3s. El objetivo de este documento es evaluar las opciones de almacenamiento disponibles y justificar la decisión final.

Se han evaluado cuatro soluciones: AWS EBS, NFS Local, Longhorn y Local Path Provisioner.

## Conceptos previos
Antes de entrar en las soluciones, es útil conocer dos términos clave de Kubernetes:
- **PV (Persistent Volume):** El "disco" que se reserva en el clúster para guardar datos.
- **PVC (Persistent Volume Claim):** La "solicitud" que hace una aplicación para usar ese disco.
- **StorageClass:** Define el tipo y proveedor del almacenamiento que se usará para crear PVs dinámicamente.
- **Modos de acceso:**
    - **RWO** — Solo un nodo puede leer y escribir a la vez.
    - **RWX** — Varios nodos pueden leer y escribir al mismo tiempo.

## Soluciones Evaluadas
- **AWS EBS (Elastic Block Store):** Disco virtual gestionado por Amazon. Funciona como un pendrive que se conecta a un servidor en la nube de AWS.

  **Tipo:** Almacenamiento en bloque gestionado por AWS | **Modo de acceso:** RWO
  | Puntos fuertes                                     | Puntos débiles                                                        |
  | -------------------------------------------------- | --------------------------------------------------------------------- |
  | Integración nativa con EC2 y AWS                   | Solo funciona en entornos AWS                                         |
  | Datos replicados automáticamente dentro de la AZ   | Solo permite acceso desde un nodo a la vez (RWO)                      |
  | Snapshots automáticos hacia S3                     | Coste continuo aunque la instancia esté apagada                       |
  | Alto rendimiento con tipo gp3 (IOPS configurables) | Latencia de red frente a disco local                                  |
  | SLA 99,95% de disponibilidad                       | Sin acceso multi-nodo nativo                                          |
  | Sin gestión adicional de software en el nodo       | El EBS CSI Driver requiere permisos IAM no disponibles en AWS Academy |
  - **Casos de uso ideales:** Bases de datos (MySQL, MariaDB, PostgreSQL), almacenamiento de datos críticos que deben sobrevivir a reinicios de instancias.
  

- **NFS Local (Network File System):** Servidor de archivos compartido en red. Funciona como una carpeta compartida a la que todos los nodos del clúster pueden acceder a la vez.
  **Tipo:** Sistema de archivos en red | **Modo de acceso:** RWX
  | Puntos fuertes                             | Puntos débiles                                         |
  | ------------------------------------------ | ------------------------------------------------------ |
  | Acceso simultáneo desde varios nodos (RWX) | Punto único de fallo si no se replica                  |
  | Compatible con cualquier entorno           | Rendimiento limitado por la red                        |
  | Bajo coste                                 | Sin alta disponibilidad nativa                         |
  | Sin dependencia de proveedor cloud         | No recomendado para bases de datos de alto rendimiento |
  - **Casos de uso ideales:** Archivos compartidos entre pods, assets estáticos, entornos de desarrollo. No recomendado para bases de datos

- **Longhorn:** Solución de almacenamiento distribuido diseñada específicamente para Kubernetes. Reparte y replica los datos automáticamente entre los nodos del clúster.
  **Tipo:** Almacenamiento en bloque distribuido cloud-native | **Modo de acceso:** RWO
  | Puntos fuertes                     | Puntos débiles                                                                      |
  | ---------------------------------- | ----------------------------------------------------------------------------------- |
  | 100% open source y cloud-native    | Requiere mínimo 3 nodos para replicación efectiva                                   |
  | Replicación automática entre nodos | Alto consumo de red y disco en escrituras intensivas                                |
  | Panel web de gestión integrado     | Más complejo de operar que EBS                                                      |
  | Backups a S3 integrados            | Overhead adicional en cada nodo del clúster                                         |
  | Sin dependencia de proveedor cloud | Nuestras instancias t3.small tienen 2 GB RAM; Longhorn consume ~200-300 MB por nodo |

- **Local Path Provisioner (Rancher/K3s):** Proveedor de almacenamiento local integrado por defecto en K3s. Crea volúmenes persistentes usando directorios del sistema de archivos del nodo donde corre el pod.
  **Tipo:** Almacenamiento local en el nodo | **Modo de acceso:** RWO
  | Puntos fuertes                                          | Puntos débiles                                     |
  | ------------------------------------------------------- | -------------------------------------------------- |
  | Integrado por defecto en K3s, sin instalación adicional | Sin replicación entre nodos                        |
  | Sin permisos AWS ni drivers externos necesarios         | Los datos quedan ligados al nodo físico            |
  | Consumo de recursos prácticamente nulo                  | No apto para alta disponibilidad                   |
  | Coherente con la filosofía nativa de K3s                | Sin snapshots automáticos integrados               |
  | Ideal para entornos con restricciones IAM               | Si el nodo falla, los datos del volumen se pierden |
  - **Casos de uso ideales:** Almacenamiento dentro del clúster para proyectos con restricciones de permisos cloud, entornos académicos, cargas de trabajo sin requisito de alta disponibilidad.

## Solución Adoptada: dos capas diferenciadas
**Almacenamiento fuera del clúster — EC2 DDBB con MariaDB:** Se mantiene AWS EBS (gp3) para el volumen de datos de MariaDB en el EC2 DDBB. MariaDB corre directamente sobre el SO del nodo, no como pod de Kubernetes. En este contexto, EBS es la solución correcta: se monta como punto de montaje del sistema operativo (/var/lib/mysql) y no requiere ningún driver de Kubernetes.

Snapshots nativos hacia S3 combinados con mysqldump programado cubren el requisito de backups sin software adicional.

**Almacenamiento dentro del clúster — NFS para datos de clientes (StorageClass nfs-client):** Se adopta NFS Local como StorageClass para los volúmenes compartidos entre pods de clientes, servido desde el propio EC2 DDBB (/srv/nfs/clientes), por las siguientes razones:
- **Acceso RWX desde todos los nodos:** Permite que varios pods en distintos nodos lean y escriban simultáneamente, necesario para la plataforma multicliente.

- **Sin dependencia de permisos IAM:** No requiere roles ni políticas IAM de AWS, compatible con las restricciones de AWS Academy Learner Lab.

- **Reutilización del EC2 DDBB:** El servidor NFS corre en la misma instancia que MariaDB, sin infraestructura adicional.

- **Integración vía Helm:** el NFS Subdir External Provisioner crea la StorageClass nfs-client dentro del clúster apuntando al share NFS del EC2 DDBB.

**Almacenamiento dentro del clúster — StorageClass para pods y PVCs:** Se adopta Local Path Provisioner como StorageClass para los volúmenes persistentes dentro del clúster K3s, por las siguientes razones:
- **Restricciones IAM de AWS Academy:** el EBS CSI Driver requiere crear roles y políticas IAM que las cuentas Learner Lab tienen bloqueados (iam:CreateRole, iam:CreatePolicy). No es posible instalarlo.
- **Ya integrado en K3s:** Local Path Provisioner viene configurado por defecto como StorageClass en K3s sin instalación ni permisos adicionales.
- **Sin overhead de recursos:** no consume RAM adicional en los nodos, crítico en instancias t3.small con 2 GB.
- **Coherencia con el proyecto:** sigue el mismo principio aplicado en el resto de decisiones técnicas — usar tecnologías nativas o integradas en K3s sin añadir complejidad no justificada.

**Longhorn** queda descartado por su overhead de memoria en instancias t3.small y porque sus ventajas de portabilidad no son relevantes en un entorno AWS. **EBS CSI Driver** queda descartado por las restricciones IAM de AWS Academy que impiden su instalación. **NFS** fue inicialmente descartado por no ser adecuado para bases de datos y por introducir un punto único de fallo; sin embargo, durante la implementación se incorporó como mejora para el almacenamiento compartido de clientes, un caso de uso donde sus limitaciones no aplican y su acceso RWX aporta valor real.