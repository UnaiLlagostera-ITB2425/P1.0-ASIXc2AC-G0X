# Elección de Almacenamiento
## Introducción y Objetivo
Los contenedores en Kubernetes son efímeros por naturaleza: si un pod se reinicia o se reprograma en otro nodo, pierde todos sus datos internos. Para garantizar que la información persiste independientemente del ciclo de vida de los contenedores, es necesario definir una estrategia de almacenamiento persistente.

En este proyecto, la capa de persistencia recae principalmente sobre MariaDB, desplegado en un nodo EC2 dedicado (EC2 DDBB) fuera del clúster K3s. El objetivo de este documento es evaluar las opciones de almacenamiento disponibles y justificar la decisión final.

Se han evaluado tres soluciones: AWS EBS, NFS Local y Longhorn.

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
  | Puntos fuertes                                     | Puntos débiles                                   |
  | -------------------------------------------------- | ------------------------------------------------ |
  | Integración nativa con EC2 y AWS                   | Solo funciona en entornos AWS                    |
  | Datos replicados automáticamente dentro de la AZ   | Solo permite acceso desde un nodo a la vez (RWO) |
  | Snapshots automáticos hacia S3                     | Coste continuo aunque la instancia esté apagada  |
  | Alto rendimiento con tipo gp3 (IOPS configurables) | Latencia de red frente a disco local             |
  | SLA 99,95% de disponibilidad                       | Sin acceso multi-nodo nativo                     |
  | Sin gestión adicional de software en el nodo       | —                                                |
  - **Casos de uso ideales:** Bases de datos (MySQL, MariaDB, PostgreSQL), almacenamiento de datos críticos que deben sobrevivir a reinicios de instancias.

- **NFS Local (Network File System):** Servidor de archivos compartido en red. Funciona como una carpeta compartida a la que todos los nodos del clúster pueden acceder a la vez.
  **Tipo:** Sistema de archivos en red | **Modo de acceso:** RWX
  | Puntos fuertes                             | Puntos débiles                                         |
  | ------------------------------------------ | ------------------------------------------------------ |
  | Acceso simultáneo desde varios nodos (RWX) | Punto único de fallo si no se replica                  |
  | Compatible con cualquier entorno           | Rendimiento limitado por la red                        |
  | Bajo coste                                 | Sin alta disponibilidad nativa                         |
  | Sin dependencia de proveedor cloud         | No recomendado para bases de datos de alto rendimiento |
  - **Casos de uso ideales:** Archivos compartidos entre pods, assets estáticos, entornos de desarrollo. No recomendado para bases de datos.

- **Longhorn:** Solución de almacenamiento distribuido diseñada específicamente para Kubernetes. Reparte y replica los datos automáticamente entre los nodos del clúster.
  **Tipo:** Almacenamiento en bloque distribuido cloud-native | **Modo de acceso:** RWO
  | Puntos fuertes                     | Puntos débiles                                                                      |
  | ---------------------------------- | ----------------------------------------------------------------------------------- |
  | 100% open source y cloud-native    | Requiere mínimo 3 nodos para replicación efectiva                                   |
  | Replicación automática entre nodos | Alto consumo de red y disco en escrituras intensivas                                |
  | Panel web de gestión integrado     | Más complejo de operar que EBS                                                      |
  | Backups a S3 integrados            | Overhead adicional en cada nodo del clúster                                         |
  | Sin dependencia de proveedor cloud | Nuestras instancias t3.small tienen 2 GB RAM; Longhorn consume ~200-300 MB por nodo |
  - **Conclusión:** La opción más completa y alineada con nuestro proyecto.

## Solución Adoptada: AWS EBS
Se adopta AWS EBS como única solución de almacenamiento persistente del proyecto, por las siguientes razones:
- Integración nativa con EC2: no requiere instalar ningún software adicional en los nodos. En un entorno que ya corre sobre AWS, EBS es la opción más directa y sin overhead.
- La base de datos está fuera del clúster K3s: MariaDB corre directamente sobre el SO del EC2 DDBB. Longhorn y NFS están diseñados para pods de Kubernetes, no para procesos del sistema operativo.
- Recursos limitados (t3.small, 2 GB RAM): Longhorn consume ~200-300 MB por nodo, un coste no justificado cuando EBS no consume ningún recurso adicional en el nodo.
- Snapshots nativos hacia S3: cubre el requisito de backups sin software adicional, combinado con mysqldump programado periódicamente.

**NFS** queda descartado por no ser adecuado para bases de datos y por introducir un punto único de fallo. **Longhorn** queda descartado porque sus ventajas (portabilidad, independencia de proveedor) no son relevantes en un entorno ya comprometido con AWS.