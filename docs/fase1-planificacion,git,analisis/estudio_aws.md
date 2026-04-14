# Justificación de AWS y estudio de instancias

## Contexto del crédito
El equipo está formado por tres personas. Cada cuenta AWS Educate Starter incluye 50 USD de crédito, lo que suma 150 USD en total. Como ese saldo no puede agruparse en una sola cuenta, hemos tenido que repartir los recursos entre las tres y planificar el despliegue con cuidado para que ninguna se agote antes de finalizar el proyecto. Esta limitación, además de condicionar la arquitectura, nos ha servido para trabajar con una visión más realista del control de costes en la nube.

El despliegue contempla cuatro instancias EC2 distribuidas entre la subred pública y la subred privada de la VPC: un nodo Master en la subred pública y tres nodos en la subred privada (Worker, Worker 2 y DDBB). Esta distribución es la que refleja los diagramas de red y orquestación del proyecto. [instances.vantage](https://instances.vantage.sh/aws/ec2/t3.small)

## Región
Las cuentas AWS Educate Starter solo permiten operar en `us-east-1` (Norte de Virginia), por lo que no ha sido posible elegir otra región. Aunque en un escenario ideal habríamos valorado una región con mejor encaje en sostenibilidad o latencia, en este caso hemos asumido la restricción propia del entorno académico. Si el proyecto evolucionara a una cuenta de producción, estudiaríamos una migración a regiones como `us-west-2` o `eu-west-3`, en función de criterios de coste, rendimiento y sostenibilidad. [aws.amazon](https://aws.amazon.com/es/ec2/pricing/on-demand/)

## Arquitectura de nodos
La arquitectura de la solución queda distribuida en cuatro instancias EC2, cada una con un rol diferenciado dentro del clúster de Kubernetes auto-gestionado:

1. **Nodo Master (EC2: Master)** — ubicado en la subred pública. Aloja el plano de control completo de Kubernetes (API Server en el puerto 6443/TCP, ETCD en los puertos 2379-2380/TCP, Scheduler y Cloud Controller Manager) y el proceso NGINX, que opera como reverse proxy y balanceador de carga de capa 7 en el puerto 443. Es el único nodo con visibilidad directa desde Internet a través del Internet Gateway de la VPC.

2. **Nodo Worker (EC2: Worker)** — ubicado en la subred privada. Ejecuta el agente Kubelet (puerto 10250/TCP), kube-proxy y el Container Runtime. Recibe peticiones de carga de trabajo desde NGINX a través del puerto 8080 y órdenes de orquestación desde el API Server a través del puerto 10250.

3. **Nodo Base de Datos (EC2: DDBB)** — ubicado en la subred privada. Dedicado exclusivamente al motor MySQL. Acepta consultas SQL en el puerto 3306/TCP exclusivamente desde los nodos Worker y Worker 2. El almacenamiento persistente de MySQL reside en un volumen EBS adicional adjunto a esta instancia.

La decisión de separar la base de datos en un nodo dedicado responde a varios motivos:

- **Rendimiento**: la base de datos tiene un perfil de consumo más sensible a memoria y operaciones de E/S que los servicios de aplicación
- **Seguridad**: el aislamiento permite aplicar reglas de acceso estrictas en el Security Group del nodo DDBB, aceptando tráfico TCP/3306 exclusivamente desde los nodos Worker
- **Escalabilidad**: si la base de datos necesita más recursos, se podrá redimensionar su nodo sin afectar al resto del clúster
- **Estabilidad**: separar los servicios reduce la contención de recursos y facilita el diagnóstico de incidencias
## Selección de instancias
Para este proyecto se ha optado por instancias de la familia **t3**, disponibles en las cuentas educativas y equilibradas para un entorno de desarrollo. La elección se ha hecho teniendo en cuenta el presupuesto, la carga prevista y la necesidad de mantener una arquitectura funcional sin sobredimensionar recursos. [aws.amazon](https://aws.amazon.com/ec2/instance-types/t3/)

| Rol | Instancia | vCPU | RAM | Coste/hora (USD) | Justificación |
|---|---|---:|---:|---:|---|
| **Master** | `t3.small` | 2 | 2 GB | 0,0208 | Suficiente para el plano de control de Kubernetes y el proceso NGINX en un entorno académico  [instances.vantage](https://instances.vantage.sh/aws/ec2/t3.small) |
| **Worker** | `t3.small` | 2 | 2 GB | 0,0208 | Adecuado para ejecutar pods de aplicación, Kubelet y kube-proxy durante la fase de desarrollo  [instances.vantage](https://instances.vantage.sh/aws/ec2/t3.small) |
| **Worker DDBB** | `t3.small` | 2 | 2 GB | 0,0208 | Permite mantener el motor MySQL aislado con recursos suficientes para el alcance actual del proyecto  [instances.vantage](https://instances.vantage.sh/aws/ec2/t3.small) |

> En un entorno de producción o con una carga más alta, sería razonable valorar instancias superiores, especialmente para el nodo de base de datos (`t3.medium` o superior, por la presión de E/S) y para el Master si se incorporan más componentes al plano de control.

## Almacenamiento (EBS)
Todos los volúmenes se plantean sobre discos **gp3**, que ofrecen un equilibrio adecuado entre coste y rendimiento para este proyecto a $0,08 por GB-mes en `us-east-1`. [geeksforgeeks](https://www.geeksforgeeks.org/cloud-computing/aws-ebs-pricing/)

- Cada nodo contará con un disco raíz de **20 GB**, suficiente para sistema operativo, dependencias, imágenes de contenedor y logs
- El nodo DDBB tendrá además un volumen adicional de **10 GB** dedicado exclusivamente al datadir de MySQL, desacoplando el almacenamiento de datos del disco raíz del sistema operativo

| Recurso | Tamaño | Precio por GB-mes | Coste mensual estimado |
|---|---:|---:|---:|
| Disco raíz Master | 20 GB | 0,08 USD | 1,60 USD |
| Disco raíz Worker | 20 GB | 0,08 USD | 1,60 USD |
| Disco raíz Worker 2 | 20 GB | 0,08 USD | 1,60 USD |
| Disco raíz Worker DDBB | 20 GB | 0,08 USD | 1,60 USD |
| Volumen adicional DDBB (datadir MySQL) | 10 GB | 0,08 USD | 0,80 USD |
| **Total EBS** | | | **7,20 USD/mes** |

El volumen adicional del nodo DDBB se montará en el sistema operativo como un punto de montaje independiente y se configurará como datadir de MySQL, garantizando que los datos persisten aunque el contenedor o el proceso MySQL se reinicie. [cloudburn](https://cloudburn.io/blog/amazon-ebs-pricing)

> Los volúmenes EBS se facturan de forma continua, independientemente del estado de encendido de la instancia EC2. Por ello, los 7,20 USD/mes de almacenamiento son un coste fijo durante todo el tiempo que los volúmenes existan, con independencia de las horas de uso de las instancias. [cloudexmachina](https://www.cloudexmachina.io/blog/ebs-pricing)
## Red y seguridad
La red se ha planteado con una estructura que separa los componentes públicos de los internos, de acuerdo con la arquitectura definida en los diagramas de red del proyecto.

- **VPC**: `10.0.0.0/16`
- **Subred pública** (`10.0.1.0/24`): aloja exclusivamente el EC2 Master; tiene asociada una tabla de enrutamiento con ruta por defecto hacia el Internet Gateway de la VPC
- **Subred privada** (`10.0.2.0/24`): aloja los nodos Worker, Worker 2 y DDBB; su tabla de enrutamiento no incluye ruta hacia el Internet Gateway, por lo que ninguno de estos nodos es accesible directamente desde Internet
- **Internet Gateway**: asociado a la subred pública; único punto de entrada y salida de tráfico externo en la VPC
### Security Groups
Se definen tres Security Groups diferenciados según el rol de cada nodo:

**SG-Master-Public** (aplicado al EC2 Master):

| Dirección | Protocolo | Puerto | Origen / Destino | Justificación |
|---|---|---|---|---|
| Entrada | TCP | 443 | 0.0.0.0/0 | Tráfico HTTPS de clientes desde Internet, tras el Firewall perimetral |
| Entrada | TCP | 6443 | IPs autorizadas del equipo + CIDR `10.0.2.0/24` | Acceso al Kubernetes API Server desde el Developer (kubectl) y desde los Kubelets de los Workers |
| Entrada | TCP | 22 | IPs autorizadas del equipo | Acceso administrativo SSH al nodo Master |
| Entrada | TCP | 2379-2380 | `127.0.0.1` (localhost) | ETCD: acceso del API Server (2379) y comunicación entre peers (2380); solo tráfico local |
| Salida | TCP | 8080 | CIDR `10.0.2.0/24` | Distribución de carga de trabajo desde NGINX hacia los Workers |
| Salida | TCP | 10250 | CIDR `10.0.2.0/24` | Órdenes del API Server al Kubelet de cada Worker |

**SG-Workers-Private** (aplicado a EC2 Worker y EC2 Worker 2):

| Dirección | Protocolo | Puerto | Origen / Destino | Justificación |
|---|---|---|---|---|
| Entrada | TCP | 8080 | SG-Master-Public | Peticiones de carga de trabajo enrutadas desde NGINX |
| Entrada | TCP | 10250 | SG-Master-Public | Órdenes de orquestación del Kubernetes API Server al Kubelet |
| Entrada | TCP | 30000-32767 | SG-Master-Public | Rango NodePort de Kubernetes para exposición de servicios |
| Salida | TCP | 3306 | SG-DDBB-Private | Consultas SQL desde los contenedores de aplicación al motor MySQL |
| Salida | TCP | 6443 | SG-Master-Public | Comunicación del Kubelet con el Kubernetes API Server |

**SG-DDBB-Private** (aplicado a EC2 DDBB):

| Dirección | Protocolo | Puerto | Origen / Destino | Justificación |
|---|---|---|---|---|
| Entrada | TCP | 3306 | SG-Workers-Private | Consultas SQL exclusivamente desde los nodos Worker y Worker 2 |
| Entrada | TCP | 22 | IPs autorizadas del equipo | Acceso administrativo SSH para mantenimiento del nodo |

Este planteamiento no busca una arquitectura excesivamente compleja, sino una base clara, segura y coherente con el alcance del proyecto, alineada con los puertos y flujos de datos definidos en los diagramas de red y orquestación.
## Backups
Para las copias de seguridad se utilizará un **bucket S3 con versionado activado**. Esta decisión permite conservar versiones anteriores de ficheros y facilita la recuperación ante borrados accidentales o errores de configuración.

En el contexto de la arquitectura, los elementos críticos a respaldar son:

- **Datadir de ETCD** (EC2 Master): contiene el estado completo del clúster de Kubernetes; una pérdida de este directorio sin backup implica la pérdida de toda la configuración del clúster. Se deben programar snapshots periódicos con `etcdctl snapshot save` y transferirlos al bucket S3
- **Datadir de MySQL** (EC2 DDBB, volumen EBS adicional): contiene los datos persistentes de la aplicación. Se deben programar dumps periódicos (`mysqldump`) o snapshots del volumen EBS y almacenarlos en el bucket S3

Con un volumen inicial pequeño, el coste mensual del almacenamiento en S3 es muy bajo ($0,023 por GB-mes en `us-east-1`), por lo que encaja bien en un proyecto con presupuesto ajustado.
## Estimación general de costes
Mantener cuatro instancias activas de forma continua (730 horas/mes) supondría un coste de cómputo de 4 × $0,0208 × 730 = **$60,74 USD/mes**, lo que agotaría el crédito disponible en aproximadamente 2,5 meses. Por ello, la estrategia realista pasa por **encender los recursos solo durante las horas de trabajo** y apagarlos cuando no se utilicen. Asumiendo una media de 8 horas diarias durante 20 días hábiles al mes (160 horas): [aws-pricing](https://aws-pricing.com/t3.small.html)

| Recurso | Cálculo | Coste estimado |
|---|---|---|
| 4 × EC2 `t3.small` (160 h/mes) | 4 × $0,0208 × 160 h | 13,31 USD/mes  [instances.vantage](https://instances.vantage.sh/aws/ec2/t3.small) |
| 5 × Volúmenes EBS gp3 (continuo) | (tabla anterior) | 7,20 USD/mes  [geeksforgeeks](https://www.geeksforgeeks.org/cloud-computing/aws-ebs-pricing/) |
| Bucket S3 backups (~5 GB estimados) | 5 GB × $0,023 | 0,12 USD/mes |
| **Total estimado mensual** | | **~20,63 USD/mes** |

Con un presupuesto total de 150 USD y un coste estimado de ~20,63 USD/mes, el proyecto tiene una autonomía aproximada de **7 meses** bajo este régimen de uso, margen suficiente para el alcance académico previsto.
## Proyección futura
Si el proyecto se llevara más allá del entorno académico, se contemplarían varias mejoras:

- Migración a una región más adecuada en coste, latencia o sostenibilidad
- Separación del nodo Master en dos instancias: una exclusiva para NGINX y otra para el plano de control de Kubernetes, eliminando la cohabitación de roles que existe en el diseño actual
- Redimensionado de instancias en función de métricas reales de consumo, especialmente para el nodo DDBB (`t3.medium` o superior) y los Workers
- Incorporación de un tercer nodo Worker para permitir rolling updates sin pérdida de capacidad
- Sustitución de la base de datos autogestionada en EC2 por **Amazon RDS**, eliminando la carga operativa de gestión de backups y actualizaciones del motor
- Aplicación de **Savings Plans** o instancias reservadas para cargas de trabajo estables
- Incorporación de escalado automático en los nodos Worker mediante Auto Scaling Groups
## Conclusión
La arquitectura elegida busca un equilibrio entre funcionalidad, coste y realismo. No se ha diseñado para maximizar potencia, sino para ajustarse a las limitaciones de AWS Educate sin renunciar a una separación lógica de servicios, un mínimo de seguridad de red y una base técnica suficientemente sólida para el desarrollo del proyecto. Más allá de la parte técnica, esta planificación también refleja uno de los aprendizajes más importantes del proyecto: en la nube no solo importa qué se puede desplegar, sino también qué se puede mantener de forma sostenible dentro del presupuesto disponible.

***