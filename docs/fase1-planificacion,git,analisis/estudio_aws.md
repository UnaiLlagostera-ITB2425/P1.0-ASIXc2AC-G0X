# Justificación de AWS y estudio de instancias

## Contexto del crédito

Somos un equipo de tres personas. Cada uno tenemos una cuenta AWS Educate Starter con 50 dólares de crédito, lo que suma 150 dólares en total. Sin embargo, no podemos juntar ese dinero en una sola cuenta; tenemos que repartir los recursos entre las tres cuentas para que ninguna se quede sin crédito antes de terminar el proyecto. Esta limitación nos ha obligado a planificar con cuidado, pero también nos ha enseñado a gestionar costes en la nube.

## Región

Las cuentas AWS Educate Starter solo permiten usar la región us-east-1 (Norte de Virginia). No podemos elegir otra. Aunque inicialmente nos hubiera gustado desplegar en una región con energías 100% renovables, asumimos esta limitación. Según los informes de AWS, todas sus regiones de EE. UU. funcionan con un mix energético superior al 90% renovable, así que el impacto ambiental no es despreciable. Si el proyecto pasara a producción con una cuenta de pago normal, entonces valoraríamos migrar a us-west-2 o eu-west-3.

## Arquitectura de nodos

Hemos decidido que la base de datos tendrá su propio nodo dedicado, separado del nodo donde corran el resto de servicios. Las razones son claras:

- **Rendimiento**: una base de datos necesita mucha memoria y E/S. Si comparte nodo con otros procesos, habrá contención.
- **Seguridad**: al aislarla, podemos aplicar reglas de red muy estrictas.
- **Escalabilidad**: si la base de datos necesita más recursos, podemos cambiar su instancia sin afectar al resto.
- **Tolerancia a fallos**: si el nodo general se cae, la base de datos sigue operativa, y viceversa.

Por tanto, nuestra arquitectura tiene tres nodos:

1. **Nodo master**: ejecuta el plano de control del orquestador (etcd, API, scheduler, etc.).
2. **Nodo worker general**: ejecuta los servicios de aplicación (API, interfaz web, monitorización, etc.).
3. **Nodo worker de base de datos**: ejecuta exclusivamente el motor de base de datos.

## Selección de instancias

Hemos analizado los precios de us-east-1 (abril de 2026) a partir de la información que nos proporciona la propia AWS. Para nuestro proyecto, utilizaremos instancias de la familia **t3**, que son las que tenemos disponibles en la cuenta educativa y ofrecen un buen equilibrio entre precio y rendimiento. Los precios que aparecen en la imagen son para Linux base, que es el sistema operativo que usaremos (Ubuntu). A continuación, la tabla con los tipos elegidos:

| Rol | Tipo de instancia | vCPU | RAM | Coste por hora (USD) | Justificación |
|-----|------------------|------|-----|----------------------|----------------|
| **Master** | t3.small | 2 | 2 GB | 0,0208 | El plano de control es ligero. Con 2 GB de RAM y 2 vCPUs va sobrado. Descartamos t3.micro (1 GB) porque el almacenamiento clave (etcd) puede consumir más memoria de la cuenta. |
| **Worker de base de datos** | t3.small | 2 | 2 GB | 0,0208 | La base de datos necesita al menos 2 GB para sus buffers internos y conexiones. Realmente podría funcionar con una t3.small aunque lo recomendado sería una medium, como no haremos muchas operaciones para evitar futuros problemas con el saldo de la máquina nos mantendremos con lo justo. |
| **Worker general** | t3.medium | 2 | 4 GB | 0,0416 | Aquí correrán varios servicios (API, frontend, monitorización, etc.). Hemos estimado que 2 GB son suficientes para la fase de desarrollo. Si más adelante vemos que se queda corto, siempre podemos cambiar a t3.medium (4 GB). |

*Nota: el precio de t3.medium no aparece en la imagen, pero según la documentación de AWS, en us-east-1 cuesta 0,0416 USD/h (el doble que t3.small). Lo hemos confirmado en la calculadora de precios.*

## Almacenamiento (discos EBS)

Todos los discos serán de tipo **gp3**, que ofrecen un rendimiento base de 3000 IOPS y 125 MB/s. No necesitamos más por ahora.

- **Cada nodo** tiene un disco raíz de 20 GB. Espacio suficiente para el sistema operativo, el runtime de contenedores, las imágenes y los logs.
- **El nodo de base de datos** tiene además un volumen adicional de 10 GB para los datos persistentes. Este volumen se montará como un PersistentVolumeClaim.

| Recurso | Tamaño | Precio por GB-mes | Coste mensual |
|----------|--------|-------------------|---------------|
| Disco raíz master | 20 GB | 0,08 USD | 1,60 USD |
| Disco raíz worker general | 20 GB | 0,08 USD | 1,60 USD |
| Disco raíz worker BBDD | 20 GB | 0,08 USD | 1,60 USD |
| **Total EBS** | | | **4,80 USD** |

## Redes y seguridad

- **VPC**: Una sola con rango 10.0.0.0/16.
- **Subred pública**: 10.0.1.0/24. Para el balanceador de entrada (Ingress) y para acceso SSH a los nodos.
- **Subred privada**: 10.0.2.0/24. Para los workers (general y base de datos). No tendrán IP pública directamente.
- **Internet Gateway**: Asociado a la subred pública.
- **Security groups**:
  - **Grupo público**: permite HTTP (80), HTTPS (443) desde cualquier origen, y SSH (22) solo desde las IPs de nuestro equipo. Las ips elásticas requerirán un sobre coste mínimo.
  - **Grupo privado**: permite todo el tráfico interno entre los nodos del clúster y el acceso a la base de datos (puerto específico) solo desde el worker general.

## Backups

Para las copias de seguridad del clúster y de las bases de datos usaremos un **bucket S3 con versionado**. El coste del almacenamiento S3 Standard es de 0,023 USD por GB-mes. Con 5 GB iniciales, el coste es insignificante (unos 0,12 USD al mes). Este bucket lo asignamos a una de las cuentas.

## Planes de futuro (cuenta de pago normal)

Si el proyecto pasara a producción con una cuenta de pago normal, haríamos lo siguiente:

- **Cambio de región**: migraríamos a us-west-2 (Oregón) o eu-west-3 (París) para mejorar la sostenibilidad y la latencia.
- **Instancias más potentes**: si la carga aumenta, pasaríamos a t3.medium o incluso a instancias de la familia c5 (más CPU).
- **Base de datos gestionada**: en lugar de mantener la base de datos en un nodo propio, usaríamos un servicio como RDS, que nos da backups automáticos y alta disponibilidad.
- **Ahorro de costes**: contrataríamos Savings Plans para los nodos que funcionan 24/7, y usaríamos instancias spot para tareas no críticas.
- **Escalado automático**: añadiríamos un Auto Scaling Group para los workers generales, de modo que se puedan añadir o quitar nodos según la demanda.

## Reflexión final

Hemos tenido que hacer malabares con los precios reales de las instancias t3 para ajustarnos al presupuesto de 50 USD por cuenta. Al final, repartiendo los nodos entre dos cuentas y usando una t3.micro para el worker general, hemos conseguido una arquitectura viable que mantiene la base de datos dedicada. Aprender a gestionar estas limitaciones es parte del valor formativo del proyecto.