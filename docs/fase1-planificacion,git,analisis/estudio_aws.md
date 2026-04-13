# Justificación de AWS y estudio de instancias

## Contexto del crédito

El equipo está formado por tres personas. Cada cuenta AWS Educate Starter incluye 50 USD de crédito, lo que suma 150 USD en total. Como ese saldo no puede agruparse en una sola cuenta, hemos tenido que repartir los recursos entre las tres y planificar el despliegue con cuidado para que ninguna se agote antes de finalizar el proyecto. Esta limitación, además de condicionar la arquitectura, nos ha servido para trabajar con una visión más realista del control de costes en la nube.

## Región

Las cuentas AWS Educate Starter solo permiten operar en `us-east-1` (Norte de Virginia), por lo que no ha sido posible elegir otra región. Aunque en un escenario ideal habríamos valorado una región con mejor encaje en sostenibilidad o latencia, en este caso hemos asumido la restricción propia del entorno académico. Si el proyecto evolucionara a una cuenta de producción, estudiaríamos una migración a regiones como `us-west-2` o `eu-west-3`, en función de criterios de coste, rendimiento y sostenibilidad.

## Arquitectura de nodos

Se ha decidido separar la base de datos en un nodo dedicado, independiente del resto de servicios. Esta decisión responde a varios motivos:

- **Rendimiento**: la base de datos tiene un perfil de consumo más sensible a memoria y operaciones de E/S que el resto de componentes.
- **Seguridad**: el aislamiento permite aplicar reglas de acceso más estrictas y reducir la superficie de exposición.
- **Escalabilidad**: si en algún momento la base de datos necesita más recursos, se podrá redimensionar su nodo sin afectar al resto del clúster.
- **Estabilidad**: separar los servicios reduce la contención de recursos y facilita el diagnóstico de incidencias.

La arquitectura prevista queda distribuida en tres nodos:

1. **Nodo master**: aloja el plano de control del clúster.
2. **Nodo worker general**: ejecuta los servicios de aplicación, frontend, monitorización y componentes auxiliares.
3. **Nodo worker de base de datos**: dedicado exclusivamente al motor de base de datos.

## Selección de instancias

Para este proyecto se ha optado por instancias de la familia **t3**, disponibles en las cuentas educativas y equilibradas para un entorno de desarrollo. La elección se ha hecho teniendo en cuenta el presupuesto, la carga prevista y la necesidad de mantener una arquitectura funcional sin sobredimensionar recursos.

| Rol | Instancia | vCPU | RAM | Coste/hora (USD) | Justificación |
|---|---|---:|---:|---:|---|
| **Master** | `t3.small` | 2 | 2 GB | 0,0208 | Suficiente para el plano de control del clúster en un entorno académico. |
| **Worker general** | `t3.small` | 2 | 2 GB | 0,0208 | Adecuado para ejecutar los servicios principales durante la fase de desarrollo. |
| **Worker BBDD** | `t3.small` | 2 | 2 GB | 0,0208 | Permite mantener la base de datos aislada con recursos suficientes para el alcance actual del proyecto. |

> En un entorno de producción o con una carga más alta, sería razonable valorar instancias superiores, especialmente para el nodo de base de datos y el worker general.

## Almacenamiento (EBS)

Todos los volúmenes se plantean sobre discos **gp3**, ya que ofrecen un equilibrio adecuado entre coste y rendimiento para este proyecto.

- Cada nodo contará con un disco raíz de **20 GB**, suficiente para sistema operativo, dependencias, contenedores y logs.
- El nodo de base de datos tendrá además un volumen adicional de **10 GB** para almacenar los datos persistentes.

| Recurso | Tamaño | Precio por GB-mes | Coste mensual estimado |
|---|---:|---:|---:|
| Disco raíz master | 20 GB | 0,08 USD | 1,60 USD |
| Disco raíz worker general | 20 GB | 0,08 USD | 1,60 USD |
| Disco raíz worker BBDD | 20 GB | 0,08 USD | 1,60 USD |
| Volumen adicional BBDD | 10 GB | 0,08 USD | 0,80 USD |
| **Total EBS** |  |  | **5,60 USD/mes** |

El volumen adicional de base de datos se montará como almacenamiento persistente para asegurar la conservación de la información aunque el contenedor se reinicie o se reprograme.

## Red y seguridad

La red se ha planteado con una estructura sencilla, pero suficiente para separar servicios públicos e internos:

- **VPC**: `10.0.0.0/16`
- **Subred pública**: `10.0.1.0/24`, destinada a entrada de tráfico y acceso administrativo controlado.
- **Subred privada**: `10.0.2.0/24`, destinada a los nodos internos del clúster.
- **Internet Gateway**: asociado a la parte pública de la arquitectura.
- **Security Groups**:
  - **Grupo público**: permite HTTP (`80`) y HTTPS (`443`) desde cualquier origen, y SSH (`22`) solo desde las IP autorizadas del equipo.
  - **Grupo privado**: restringe el tráfico a las comunicaciones internas del clúster y al acceso controlado a la base de datos.

Este planteamiento no busca una arquitectura excesivamente compleja, sino una base clara, segura y coherente con el alcance del proyecto.

## Backups

Para las copias de seguridad se utilizará un **bucket S3 con versionado activado**. Esta decisión permite conservar versiones anteriores de ficheros y facilita la recuperación ante borrados accidentales o errores de configuración.

Con un volumen inicial pequeño, el coste mensual del almacenamiento en S3 es muy bajo, por lo que encaja bien en un proyecto con presupuesto ajustado. Además, centralizar los backups en S3 simplifica la estrategia de recuperación y deja preparada una base razonable para fases posteriores.

## Estimación general de costes

A nivel orientativo, el coste mensual del despliegue completo se reparte entre computación, almacenamiento y backups. Mantener tres instancias activas de forma continua incrementaría el gasto rápidamente, por lo que la estrategia realista en este contexto pasa por **encender los recursos solo durante las horas de trabajo** y apagarlos cuando no se utilicen.

De este modo, el proyecto sigue siendo viable dentro del crédito disponible y, al mismo tiempo, permite trabajar con una arquitectura suficientemente seria como para justificar decisiones reales de diseño.

## Proyección futura

Si el proyecto se llevara más allá del entorno académico, se contemplarían varias mejoras:

- Migración a una región más adecuada en coste, latencia o sostenibilidad.
- Redimensionado de instancias en función de métricas reales de consumo.
- Sustitución de la base de datos autogestionada por un servicio administrado como **Amazon RDS**.
- Aplicación de mecanismos de ahorro como **Savings Plans** o instancias reservadas.
- Incorporación de escalado automático en los nodos de aplicación.

## Conclusión

La arquitectura elegida busca un equilibrio entre funcionalidad, coste y realismo. No se ha diseñado para maximizar potencia, sino para ajustarse a las limitaciones de AWS Educate sin renunciar a una separación lógica de servicios, un mínimo de seguridad de red y una base técnica suficientemente sólida para el desarrollo del proyecto.

Más allá de la parte técnica, esta planificación también refleja uno de los aprendizajes más importantes del proyecto: en la nube no solo importa qué se puede desplegar, sino también qué se puede mantener de forma sostenible dentro del presupuesto disponible.