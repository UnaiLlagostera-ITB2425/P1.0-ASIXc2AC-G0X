# Estudio tecnológico del stack: base de datos, servidor web y automatización

## Introducción

Este documento recoge el estudio completo y justificado de las tres decisiones tecnológicas más relevantes del proyecto a nivel de capa de datos, capa de presentación y operación automatizada. Para cada componente se han definido los requisitos concretos del proyecto, se han evaluado en profundidad todas las alternativas relevantes del mercado, se han comparado mediante tablas detalladas y se ha llegado a una decisión fundamentada.

El objetivo de este estudio no es solo justificar las elecciones, sino dejar constancia del proceso de análisis: qué se valoró, qué se descartó y por qué. Cualquier decisión diferente requeriría cambiar también parte de la arquitectura, y ese razonamiento queda recogido aquí.

---

## 1. Base de datos

### 1.1 Requisitos del proyecto

La plataforma necesita persistir múltiples tipos de entidades con relaciones bien definidas entre ellas: usuarios, sitios web, planes de hosting, credenciales de acceso, configuraciones de servicio y registros de actividad. El perfil de carga es predominantemente **OLTP** (transacciones frecuentes y simples, muchas lecturas y escrituras concurrentes de baja complejidad individual).

Los requisitos técnicos definidos son:

| Requisito | Descripción |
|---|---|
| Modelo relacional | Integridad referencial, claves foráneas y soporte completo de transacciones ACID |
| Memoria reducida | Instancias t3.small con 2 GB de RAM compartida con el agente K8s y exportadores de métricas |
| Soporte de contenedores | Imagen Docker oficial, mantenida y con soporte multi-versión |
| Licencia libre | Sin restricciones de uso, sin módulos de pago, sin dependencia de terceros |
| Operación autónoma | Sin servicios gestionados externos, base de datos autoalojada en el clúster |
| Comunidad activa | Documentación accesible, foros activos, resolución de bugs con continuidad |
| Soporte de replicación | Disponible para posibles escenarios de alta disponibilidad futuros |

### 1.2 Alternativas descartadas antes del análisis

SQLite queda descartado desde el inicio al no estar diseñado para entornos multiusuario concurrentes. Su modelo de bloqueo a nivel de fichero lo hace inadecuado incluso para cargas de trabajo moderadas con múltiples conexiones simultáneas.

Las bases de datos NoSQL (MongoDB, Redis, Cassandra) quedan fuera del alcance porque el modelo de datos del proyecto es relacional por naturaleza y no presenta características que justifiquen el coste operativo y cognitivo de una base de datos no relacional.

Las bases de datos gestionadas en la nube (Amazon RDS, Amazon Aurora) son opciones válidas para producción, pero están fuera del alcance de este proyecto por las restricciones de las cuentas AWS Educate y el coste adicional que implicarían.

### 1.3 Alternativas evaluadas

#### 1.3.1 MariaDB

MariaDB nació en 2009 como fork de MySQL, creado por Michael Widenius (el propio creador de MySQL) tras la adquisición de Sun Microsystems —y con ella, de MySQL— por parte de Oracle. Desde entonces ha evolucionado de forma completamente independiente, añadiendo mejoras de rendimiento, nuevos motores de almacenamiento y funcionalidades que MySQL no tiene disponibles en su versión comunitaria.

**Arquitectura y funcionamiento:**

MariaDB utiliza un modelo de concurrencia basado en **hilos** (threads). Cuando llega una conexión nueva, se le asigna un hilo del pool, evitando el coste de crear un proceso nuevo por cada cliente. El motor de almacenamiento por defecto es **InnoDB** (compartido con MySQL), con soporte completo de transacciones ACID, claves foráneas y MVCC (Multi-Version Concurrency Control) para la gestión de concurrencia. Adicionalmente, MariaDB incorpora el motor **Aria** para tablas temporales e internas, más eficiente que el antiguo MyISAM.

**Características relevantes para el proyecto:**

- **Thread pool nativo en la versión comunitaria**: permite gestionar un número de conexiones mayor que el número de hilos activos, reduciendo el consumo de memoria por conexión concurrente. En MySQL, esta característica es exclusiva de la versión Enterprise (de pago).
- **Consumo de memoria reducido**: MariaDB está optimizado para un perfil de consumo más ligero que PostgreSQL. Según benchmarks publicados y estudios de la Universidad Politécnica de Zamora, MariaDB mantiene mejor rendimiento relativo en escenarios con muchos usuarios concurrentes y consultas simples, que es exactamente el perfil de este proyecto.
- **Galera Cluster nativo**: replicación multi-master disponible sin licencias adicionales, lo que abre la puerta a arquitecturas de alta disponibilidad en el futuro sin cambiar de motor de base de datos.
- **Compatibilidad total con MySQL**: cualquier cliente, ORM, herramienta de administración gráfica o script diseñado para MySQL funciona sin modificaciones con MariaDB, ya que comparten protocolo de red, sintaxis SQL y estructura de ficheros de configuración.
- **Imagen Docker oficial**: disponible en Docker Hub bajo el namespace `mariadb`, con versiones LTS bien mantenidas y actualizaciones de seguridad publicadas de forma regular.
- **Licencia GPL pura**: sin partes cerradas, sin restricciones de uso, sin dependencia de Oracle.

**Limitaciones:**

- No tiene el soporte avanzado de tipos de datos que ofrece PostgreSQL (JSON binario JSONB, arrays nativos, hstore, herencia de tablas).
- La compatibilidad con MySQL no es perfecta al 100% en versiones muy recientes, aunque las diferencias afectan a funcionalidades avanzadas que no son relevantes para este proyecto.
- No es la mejor opción cuando se necesitan consultas analíticas complejas o cargas OLAP intensivas.

---

#### 1.3.2 MySQL

MySQL es el sistema gestor de bases de datos relacional de código abierto más extendido del mundo, con más de 25 años de historia y una base de instalaciones enorme. Es la M del stack LAMP y el estándar de facto del ecosistema web clásico.

**Fortalezas:**

- Documentación exhaustiva, comunidad muy amplia y enorme cantidad de recursos de aprendizaje disponibles.
- Compatibilidad con prácticamente cualquier herramienta, framework y ORM del mercado.
- Rendimiento sólido en cargas OLTP estándar con el motor InnoDB.
- Imagen Docker oficial bien mantenida.

**Por qué queda por detrás de MariaDB en este proyecto:**

Desde la adquisición de Sun Microsystems por Oracle en 2010, el desarrollo de la versión comunitaria de MySQL ha perdido agilidad frente a MariaDB. Ciertas características que sí están disponibles en MariaDB Community (como el thread pool o el motor ColumnStore) están reservadas en MySQL para la versión Enterprise, que es de pago.

En términos técnicos, para el alcance de este proyecto MySQL y MariaDB son prácticamente equivalentes en rendimiento y funcionalidades básicas. La diferencia está en la política de desarrollo y en las características adicionales que MariaDB ofrece de forma libre. Dado que no existe ninguna ventaja concreta de MySQL sobre MariaDB para este caso de uso, y que MariaDB ofrece más funcionalidades en su versión comunitaria, la elección se inclina claramente hacia MariaDB.

---

#### 1.3.3 PostgreSQL

PostgreSQL es el motor relacional más completo y técnicamente avanzado de los tres. Su conformidad con el estándar SQL es superior (puntuación de 10/10 frente al 7/10 de MySQL/MariaDB según análisis independientes), y su soporte de tipos de datos avanzados, extensiones y procedimientos almacenados no tiene rival en el mundo open source.

**Fortalezas técnicas:**

- JSON y JSONB (JSON binario, con índices GIN para búsquedas muy rápidas en estructuras JSON).
- Arrays nativos, hstore, tipos geométricos.
- Herencia de tablas.
- Extensiones como PostGIS (geoespacial), pgcrypto, uuid-ossp, pg_stat_statements.
- Full-text search integrado y muy potente.
- CTEs recursivas, window functions, índices parciales y funcionales.
- MVCC muy eficiente para cargas de escritura concurrente alta.
- Modelo de replicación más flexible (asíncrona, síncrona, streaming, cascada).

**Por qué queda descartado para este proyecto:**

- **Consumo de memoria base más alto**: PostgreSQL utiliza un modelo de proceso por conexión (un proceso del sistema operativo por cada cliente conectado), a diferencia del modelo de hilos de MariaDB. Esto se traduce en un mayor consumo de memoria por conexión activa. En una instancia con 2 GB de RAM donde ya corren el agente de Kubernetes, exportadores de métricas y otros procesos, este overhead puede generar presión de memoria real y afectar a la estabilidad del nodo.
- **Configuración más exigente en entornos con recursos limitados**: parámetros como `shared_buffers`, `work_mem`, `max_connections` y `effective_cache_size` deben ajustarse con cuidado para evitar que PostgreSQL consuma más RAM de la disponible. MariaDB tiene un comportamiento más conservador por defecto.
- **Las características avanzadas no son necesarias**: JSON avanzado, arrays, herencia de tablas y extensiones geoespaciales no tienen uso en este proyecto. Pagar el coste de recursos adicionales por funcionalidades que no se van a utilizar no está justificado.
- **Curva de configuración más pronunciada**: aunque PostgreSQL es bien conocido, su configuración óptima en entornos con poca RAM requiere más conocimiento específico que MariaDB.

Según estudios de rendimiento publicados, en escenarios de carga OLTP con muchos usuarios concurrentes y consultas simples (que es exactamente el perfil de este proyecto), MariaDB procesa más peticiones por segundo que PostgreSQL bajo las mismas condiciones de hardware.

---

### 1.4 Tabla comparativa de bases de datos

| Criterio | MariaDB | MySQL | PostgreSQL |
|---|---|---|---|
| Licencia | GPL (100% libre) | GPL con restricciones Oracle | PostgreSQL License (libre) |
| Modelo de concurrencia | Hilos (thread pool nativo) | Hilos (thread pool solo Enterprise) | Procesos por conexión |
| Consumo de memoria base | **Bajo** | Bajo-medio | **Medio-alto** |
| Rendimiento OLTP (lectura simple) | Alto | Alto | Medio-alto |
| Rendimiento consultas complejas | Medio | Medio | **Alto** |
| Soporte JSON avanzado (JSONB) | No | No | **Sí** |
| Arrays y tipos avanzados | No | No | **Sí** |
| Full-text search integrado | Básico | Básico | **Avanzado** |
| Conformidad estándar SQL | Media (7/10) | Media (7/10) | **Alta (10/10)** |
| Galera Cluster (multi-master) | **Sí (Community)** | No (Community) | No |
| Replicación avanzada | Sí | Parcial | **Sí (más opciones)** |
| Compatibilidad con MySQL | **Total** | — | Parcial |
| Imagen Docker oficial | Sí | Sí | Sí |
| Desarrollo libre y activo | **Sí** | Parcial (Oracle) | Sí |
| Adecuado para este proyecto | ✅ **Mejor opción** | ⚠️ Viable (sin ventajas) | ❌ Excesivo para el perfil |

### 1.5 Decisión justificada: MariaDB

**Elegimos MariaDB como motor de base de datos del proyecto.**

MariaDB ofrece exactamente lo que el proyecto necesita: modelo relacional completo con transacciones ACID, alto rendimiento en cargas OLTP, bajo consumo de memoria (crítico en instancias t3.small), licencia completamente libre, imagen Docker oficial, thread pool nativo en la versión comunitaria y soporte de replicación multi-master con Galera Cluster para escenarios futuros.

MySQL queda descartado por no ofrecer ninguna ventaja concreta sobre MariaDB para este caso de uso, y por tener restricciones de licencia en algunas funcionalidades que en MariaDB son libres.

PostgreSQL queda descartado porque sus ventajas (JSON avanzado, arrays, extensiones geoespaciales, conformidad SQL estricta) no son necesarias en este proyecto, y su mayor consumo de memoria introduce un riesgo real de inestabilidad en las instancias disponibles.

---

## 2. Servidor web y procesamiento PHP

### 2.1 Requisitos del proyecto

El servidor web tiene dos roles diferenciados dentro de la arquitectura:

1. **Ingress Controller**: recibe todo el tráfico HTTP/HTTPS entrante al clúster y lo enruta hacia los servicios correctos según el host o la ruta.
2. **Servidor de sitios web**: sirve el contenido PHP dinámico y estático de los sitios de los clientes alojados en la plataforma.

Los requisitos técnicos son:

| Requisito | Descripción |
|---|---|
| Bajo consumo de memoria | Múltiples instancias por clúster, recursos compartidos con otros servicios |
| Rendimiento en contenido estático | Imágenes, CSS, JS y archivos de descarga sin procesar PHP |
| Integración con PHP | Procesador externo PHP-FPM para separar responsabilidades |
| Proxy inverso | Redirigir peticiones hacia servicios internos del clúster |
| Integración con Kubernetes | Compatibilidad nativa con el ecosistema de Ingress Controllers |
| Seguridad configurable | Soporte de WAF (ModSecurity), cabeceras de seguridad, rate limiting |
| Gestión por plantillas | Generación de configuraciones mediante scripts de automatización |
| Aislamiento multicliente | Capacidad de asignar pools PHP separados por sitio/cliente |

### 2.2 Alternativas evaluadas

#### 2.2.1 Nginx

Nginx fue diseñado desde cero en 2004 con una arquitectura **asíncrona y basada en eventos**. A diferencia de los servidores web tradicionales, Nginx no crea un proceso o hilo por cada conexión entrante. En cambio, un único proceso maestro gestiona múltiples workers (generalmente uno por CPU), y cada worker atiende miles de conexiones simultáneas mediante un bucle de eventos no bloqueante. Esto lo hace extremadamente eficiente en términos de memoria y CPU bajo carga concurrente alta.

**Modelo de integración con PHP:**

Nginx no ejecuta PHP de forma nativa. Delega el procesamiento de scripts PHP a un proceso externo (**PHP-FPM**, FastCGI Process Manager) mediante el protocolo FastCGI. Esta separación de responsabilidades tiene múltiples ventajas:

- El servidor web y el procesador PHP se pueden reiniciar, actualizar y escalar de forma independiente.
- Un fallo en PHP-FPM no tumba al servidor web.
- Es posible asignar un pool PHP-FPM diferente por cliente o por sitio web, con su propio usuario, límites de memoria y configuración, consiguiendo un aislamiento real entre clientes.
- En Kubernetes, Nginx y PHP-FPM pueden correr en contenedores separados dentro del mismo pod o en pods distintos, siguiendo el principio de responsabilidad única.

**Fortalezas para este proyecto:**

- **Consumo de memoria muy bajo**: bajo carga moderada, Nginx ocupa notablemente menos RAM que Apache con el mismo tráfico. La diferencia es especialmente relevante en instancias con poca memoria.
- **Rendimiento superior en contenido estático**: imágenes, hojas de estilo, scripts y archivos se sirven directamente desde el sistema de archivos con un overhead mínimo.
- **Proxy inverso de primera clase**: Nginx está diseñado para actuar como proxy y balanceador de carga. La configuración de upstream, timeouts, buffers y caché es muy granular y bien documentada.
- **Estándar en Kubernetes**: el controlador Ingress más utilizado en Kubernetes es **ingress-nginx**, mantenido por la CNCF y basado en Nginx. Usar la misma tecnología tanto para el Ingress Controller como para los servidores de sitios reduce la complejidad, unifica los conocimientos del equipo y simplifica el troubleshooting.
- **ModSecurity como WAF**: Nginx tiene soporte para ModSecurity, el WAF (Web Application Firewall) open source más extendido, permitiendo aplicar reglas OWASP para protección contra inyecciones SQL, XSS, LFI y otras amenazas comunes.
- **Rate limiting nativo**: Nginx incorpora módulos de rate limiting (`limit_req`, `limit_conn`) para proteger los servicios contra ataques de fuerza bruta o tráfico abusivo sin dependencias adicionales.
- **Configuración declarativa y predecible**: los bloques `server` y `location` de Nginx tienen una semántica clara, sin herencias implícitas ni directivas que se sobreescriban de forma inesperada.
- **Generación de configuraciones por plantillas**: la sintaxis de Nginx es perfectamente compatible con plantillas Jinja2, lo que permite generar configuraciones de nuevos sitios de forma automatizada desde Python.

**Limitaciones:**

- No soporta `.htaccess`. Toda la configuración debe estar en los ficheros del servidor. Para este proyecto, donde la infraestructura está completamente bajo control del equipo, esto no es un problema. La ausencia de `.htaccess` es incluso una ventaja de seguridad en un entorno multicliente, ya que impide que los clientes modifiquen el comportamiento del servidor.
- Los módulos no son dinámicos: se compilan en el binario. La imagen oficial incluye todos los módulos necesarios para el uso habitual, por lo que esto no afecta al proyecto.

---

#### 2.2.2 Apache HTTP Server

Apache es el servidor web de código abierto más veterano y durante décadas el más extendido del mundo. Su arquitectura original se basa en el modelo **MPM Prefork** (un proceso por conexión) o **MPM Worker/Event** (hilos por conexión), y soporta módulos dinámicos que se pueden cargar y descargar sin recompilar el servidor.

**Fortalezas:**

- Soporte nativo de `.htaccess`, lo que permite delegar configuración de directorio a los administradores de los sitios.
- Módulos dinámicos: flexibilidad para añadir funcionalidades sin recompilar.
- `mod_php`: puede ejecutar PHP directamente dentro del proceso del servidor (aunque es considerado un antipatrón en entornos modernos).
- Documentación enormemente extensa y base de usuarios muy amplia.
- `mod_security`: soporte de WAF similar al de Nginx.

**Por qué queda por detrás de Nginx en este proyecto:**

- **Consumo de memoria más alto bajo carga**: el modelo de hilos o procesos por conexión de Apache escala de forma más pronunciada que la arquitectura asíncrona de Nginx, especialmente con muchas conexiones simultáneas o conexiones keep-alive de larga duración.
- **Como proxy inverso**: Apache puede actuar como proxy inverso con `mod_proxy`, pero la configuración es más compleja y el rendimiento en este rol es inferior al de Nginx, que fue diseñado específicamente para ello.
- **No es el estándar en Kubernetes**: los Ingress Controllers basados en Apache existen pero son minoritarios. Usar Apache implicaría trabajar con dos tecnologías diferentes para el proxy de entrada (ingress-nginx) y para los servidores de sitios, añadiendo complejidad innecesaria.
- **`.htaccess` en entornos multicliente**: en un hosting multicliente, permitir `.htaccess` introduce riesgos de seguridad si no se gestiona con cuidado, ya que los clientes pueden modificar configuraciones del servidor como la ejecución de scripts, el seguimiento de enlaces simbólicos o las restricciones de acceso.

---

#### 2.2.3 Caddy

Caddy es un servidor web moderno escrito en Go, con gestión automática de certificados TLS mediante Let's Encrypt integrada por defecto. Su configuración se basa en un único fichero `Caddyfile` de sintaxis muy simple.

**Fortalezas:**

- TLS automático sin configuración adicional.
- Configuración muy simple y legible.
- Consumo de memoria bajo.
- API de administración vía HTTP para modificar la configuración en caliente.

**Por qué queda descartado:**

- La gestión automática de TLS de Caddy pierde relevancia en Kubernetes, donde **cert-manager** ya cumple esa función de forma más robusta e integrada con el ecosistema del clúster.
- El ecosistema de Ingress Controllers basado en Caddy es muy reducido frente a ingress-nginx.
- El soporte de WAF (ModSecurity) y las opciones de seguridad avanzadas son limitadas comparadas con Nginx.
- La comunidad y la documentación de casos de uso en producción son significativamente más reducidas.
- La madurez en entornos de hosting multicliente con PHP-FPM está menos probada y documentada.

---

### 2.3 Tabla comparativa de servidores web

| Criterio | Nginx | Apache | Caddy |
|---|---|---|---|
| Arquitectura | Asíncrona, basada en eventos | Hilos/procesos por conexión | Goroutines (Go) |
| Consumo de memoria bajo carga | **Muy bajo** | Medio-alto | Bajo |
| Rendimiento en contenido estático | **Excelente** | Bueno | Bueno |
| Rendimiento como proxy inverso | **Excelente** | Bueno | Bueno |
| PHP nativo | No (requiere PHP-FPM) | Sí (mod_php) o FPM | No (requiere FPM) |
| Soporte `.htaccess` | No | Sí | No |
| Módulos dinámicos | No | Sí | Limitado |
| TLS automático | Mediante cert-manager | Mediante cert-manager | **Nativo** |
| WAF (ModSecurity) | **Sí** | Sí | Limitado |
| Rate limiting nativo | **Sí** | Parcial (mod_ratelimit) | Sí |
| Estándar Ingress en Kubernetes | **Sí (ingress-nginx)** | No | No |
| Aislamiento por pools PHP-FPM | **Excelente** | Posible | Posible |
| Generación de config por plantillas | **Muy sencillo** | Complejo | Sencillo |
| Comunidad y documentación | **Muy amplia** | Muy amplia | Media |
| Madurez en producción | **Muy alta** | Muy alta | Media |
| Adecuado para este proyecto | ✅ **Mejor opción** | ⚠️ Viable con limitaciones | ❌ Inmaduro en K8s |

### 2.4 Decisión justificada: Nginx + PHP-FPM

**Elegimos Nginx con PHP-FPM como stack de servidor web del proyecto.**

Nginx es el servidor web que mejor encaja en la arquitectura en todos los niveles simultáneamente: actúa como Ingress Controller de entrada al clúster (ingress-nginx), como proxy inverso hacia los servicios internos y como servidor de los sitios web de los clientes con PHP-FPM. Usar la misma tecnología en todos estos roles simplifica la operación, unifica los conocimientos del equipo y facilita el troubleshooting.

Su bajo consumo de memoria, su rendimiento en contenido estático, su soporte de ModSecurity como WAF, el rate limiting nativo y la capacidad de generar configuraciones mediante plantillas hacen de Nginx la opción más sólida para este proyecto.

Apache queda descartado principalmente por su mayor consumo de recursos y por no ser el estándar en Kubernetes. Caddy queda descartado por madurez insuficiente en entornos multicliente con PHP en Kubernetes.

---

## 3. Lenguaje de automatización

### 3.1 Requisitos del proyecto

La automatización del proyecto abarca dos ámbitos con características técnicas distintas:

**Aprovisionamiento de nuevos servicios:**
- Creación de namespaces, cuotas de recursos y políticas de red en Kubernetes.
- Generación dinámica de manifiestos YAML para nuevos sitios web (Deployments, Services, PVCs).
- Creación y configuración de bases de datos MariaDB por cliente.
- Generación de configuraciones Nginx a partir de plantillas parametrizadas.
- Gestión de secretos (credenciales, certificados).
- Registro y actualización de estado en la base de datos de la plataforma.

**Operación y mantenimiento:**
- Scripts de backup de base de datos y clúster hacia S3.
- Comprobaciones de estado de servicios.
- Rotación y limpieza de logs.
- Tareas periódicas en pipelines CI/CD (GitHub Actions).

Los requisitos son:

| Requisito | Descripción |
|---|---|
| API de Kubernetes | Interacción nativa con la API del clúster sin depender de subprocesos kubectl |
| API de AWS | Acceso a S3, EC2 y otros servicios de AWS |
| Plantillas dinámicas | Generación de ficheros YAML y de configuración parametrizados |
| Manejo robusto de errores | Gestión predecible de fallos con información útil de diagnóstico |
| Legibilidad y mantenibilidad | Código revisable por el equipo y por el tribunal |
| Portabilidad | Ejecutable en local, en contenedores y en pipelines CI/CD |
| Sin costes adicionales | Sin licencias ni dependencias de pago |

### 3.2 Alternativas evaluadas

#### 3.2.1 Python

Python es un lenguaje de propósito general de alto nivel, con sintaxis limpia, tipado dinámico y uno de los ecosistemas de librerías más extensos de cualquier lenguaje de programación. En el ámbito de la automatización de infraestructura y DevOps es el lenguaje más utilizado: según la encuesta de Stack Overflow de 2024, Python alcanza el 51% de uso entre desarrolladores, incluyendo el ámbito de operaciones e infraestructura.

**Librerías clave para este proyecto:**

| Librería | Función |
|---|---|
| `kubernetes-client/python` | Cliente oficial de la API de Kubernetes, mantenido por la CNCF |
| `boto3` | SDK oficial de AWS, cobertura completa de todos los servicios |
| `Jinja2` | Motor de plantillas para generar YAML, configuraciones Nginx y scripts |
| `PyYAML` | Lectura y escritura de ficheros YAML (manifiestos, configuraciones) |
| `requests` | Llamadas HTTP a APIs externas |
| `paramiko` | Conexiones SSH si fuera necesario |
| `subprocess` | Ejecución controlada de comandos externos (kubectl, helm, etc.) |

**Fortalezas para este proyecto:**

- **Cliente Kubernetes oficial**: interacción directa con la API del clúster con tipado de objetos, sin necesidad de parsear la salida de kubectl.
- **boto3**: el SDK de AWS más completo y documentado disponible. Subir backups a S3, gestionar snapshots o listar recursos de EC2 son operaciones de pocas líneas.
- **Jinja2**: generación de manifiestos YAML y configuraciones Nginx parametrizadas con condicionales, bucles y filtros. Es la misma librería que usa Ansible internamente.
- **Manejo de errores estructurado**: bloques `try/except` con tipado de excepciones, trazas completas y posibilidad de logging estructurado en JSON.
- **Reutilización**: funciones, módulos y clases permiten organizar el código de forma modular y reutilizable entre scripts.
- **Legibilidad**: el código Python es significativamente más fácil de leer y mantener que un script Bash equivalente de complejidad media o alta. Esto facilita la revisión del código y la comprensión por parte del tribunal.
- **Integración nativa con GitHub Actions**: Python está disponible en todos los runners de GitHub Actions sin instalación adicional.
- **Portabilidad total**: un script Python funciona igual en cualquier distribución Linux, en macOS y dentro de un contenedor Alpine o Debian.

**Limitaciones:**

- Para tareas muy simples (copiar un fichero, encadenar dos comandos de una línea), Bash es más rápido de escribir.
- Requiere un intérprete instalado, aunque Python 3 viene preinstalado en todas las distribuciones modernas y en las imágenes base de contenedores.

---

#### 3.2.2 Bash

Bash es el lenguaje de scripts nativo de Linux, omnipresente, sin dependencias externas y la forma más directa de encadenar comandos del sistema. Según la misma encuesta de Stack Overflow 2024, el uso de Bash/Shell entre profesionales de operaciones e infraestructura es del 49%, prácticamente empatado con Python.

**Fortalezas:**

- Disponible en cualquier sistema Linux sin instalación.
- Integración directa con cualquier herramienta de línea de comandos: `kubectl`, `helm`, `aws` CLI, `velero`, `docker`, etc.
- Ideal para entrypoints de contenedores, scripts de inicialización de poca complejidad y encadenamiento de comandos en pipelines.
- Velocidad de ejecución para tareas de nivel de sistema.

**Limitaciones para automatización compleja:**

- El manejo de errores es frágil por defecto. Sin `set -e`, `set -o pipefail` y comprobaciones explícitas de cada retorno, los errores pasan silenciosamente. Un script Bash mal escrito puede parecer que ha terminado correctamente cuando ha fallado a mitad.
- El código crece en complejidad muy rápido. A partir de cierta longitud, un script Bash es difícil de leer, entender y mantener.
- No tiene tipos ni estructuras de datos complejas. Trabajar con JSON o YAML (necesario para interactuar con Kubernetes y AWS) requiere herramientas externas como `jq` o `yq`.
- Las funciones en Bash tienen un ámbito de variables confuso y no permiten el nivel de abstracción y reutilización de Python.
- Depurar scripts Bash complejos es tedioso y propenso a errores silenciosos.

**Conclusión sobre Bash**: es la herramienta adecuada para tareas simples y es perfectamente complementario con Python. No es adecuado como lenguaje principal de automatización para la complejidad de este proyecto.

---

#### 3.2.3 Ansible

Ansible es una herramienta de automatización de configuración e infraestructura desarrollada por Red Hat. Sus playbooks en YAML describen el estado deseado de los sistemas de forma declarativa, y Ansible aplica los cambios necesarios para alcanzar ese estado de forma idempotente, conectándose a los nodos mediante SSH sin necesidad de instalar un agente.

**Fortalezas:**

- Idempotencia por diseño: ejecutar el mismo playbook varias veces produce el mismo resultado.
- Sin agente en los nodos gestionados: solo requiere SSH y Python en el destino.
- Ecosistema muy amplio de módulos: gestión de paquetes, servicios, ficheros, usuarios, nube, contenedores, Kubernetes, bases de datos, etc.
- Legible para personas con menos experiencia en programación.
- Muy adecuado para la gestión de la configuración de servidores y el aprovisionamiento inicial de sistemas.

**Por qué queda por detrás de Python en este proyecto:**

- **Solapamiento con ArgoCD**: Ansible gestiona el estado deseado de la infraestructura de forma declarativa, pero en una arquitectura GitOps con ArgoCD, ArgoCD ya cumple esa función dentro del clúster Kubernetes. Introducir Ansible añade una capa de gestión que se solapa con lo que ArgoCD ya hace mejor en el contexto de Kubernetes.
- **Flujo de control limitado en YAML**: los condicionales (`when`), bucles (`loop`, `with_items`) y el manejo de errores (`ignore_errors`, `failed_when`) en YAML son funcionales pero menos expresivos y más verbosos que el equivalente en Python para lógica compleja.
- **Menos flexible para lógica de negocio**: cuando la automatización requiere lógica de aprovisionamiento compleja (crear una base de datos, generar un manifiesto dinámico, registrar el estado en una API interna), Ansible obliga a usar módulos específicos o a caer en scripts de shell embebidos, perdiendo la ventaja de la legibilidad declarativa.
- **Dependencia adicional**: Ansible requiere instalación y mantenimiento de su propio entorno, lo que añade complejidad al stack.

---

#### 3.2.4 Terraform (mención)

Terraform es la herramienta de referencia para infraestructura como código en entornos cloud. Su modelo declarativo con proveedores para AWS, Kubernetes y prácticamente cualquier servicio lo hace ideal para el aprovisionamiento de infraestructura cloud.

**Por qué queda fuera del alcance:**

- El aprovisionamiento cloud de este proyecto está acotado (VPC, subredes, instancias EC2, bucket S3) y no justifica la complejidad operativa de Terraform (backend de estado, ciclo plan/apply, gestión de secrets en el estado).
- No es adecuado para automatización operativa (backups, scripts de mantenimiento), que requiere lógica imperativa.
- Podría considerarse para una fase futura de infraestructura como código completa, pero queda fuera del alcance actual.

---

### 3.3 Tabla comparativa de herramientas de automatización

| Criterio | Python | Bash | Ansible | Terraform |
|---|---|---|---|---|
| Cliente Kubernetes oficial | **Sí** | No (kubectl CLI) | Sí (módulo) | Sí (provider) |
| SDK AWS oficial | **Sí (boto3)** | No (aws CLI) | Sí (módulo) | Sí (provider) |
| Manejo de errores | **Robusto** | Frágil | Medio | Medio |
| Legibilidad código complejo | **Alta** | Baja | Media | Media |
| Idempotencia nativa | Manual | Manual | **Sí** | **Sí** |
| Plantillas dinámicas | **Jinja2 (nativo)** | Limitado | Jinja2 | Limitado |
| Trabajo con YAML/JSON | **Excelente** | Requiere jq/yq | Nativo | Nativo |
| Lógica de negocio compleja | **Sí** | No | Parcialmente | No |
| Reutilización de código | **Alta** | Baja | Media | Media |
| Portabilidad | **Muy alta** | Alta | Alta | Alta |
| Sin dependencias adicionales | Casi siempre | **Siempre** | No | No |
| Integración GitHub Actions | **Excelente** | Buena | Buena | Buena |
| Solapamiento con ArgoCD/GitOps | No | No | **Sí** | No |
| Curva de aprendizaje | Media | **Baja** | Media | Media-alta |
| Adecuado para tareas simples | Sí | **Mejor opción** | Sí | No |
| Adecuado para automatización compleja | **Mejor opción** | No | Parcialmente | No |

### 3.4 Decisión justificada: Python + Bash

**Elegimos Python como lenguaje principal de automatización, con Bash para tareas simples del sistema.**

Python ofrece el cliente oficial de Kubernetes, el SDK de AWS más completo (boto3), generación de plantillas mediante Jinja2, manejo robusto de errores y código legible y mantenible. Es el lenguaje con mejor encaje para la complejidad de automatización que requiere este proyecto: aprovisionamiento dinámico de servicios, interacción con APIs, generación de configuraciones y operación del clúster.

Bash complementa a Python para las tareas donde tiene sentido: entrypoints de contenedores, scripts de inicialización simples, encadenamiento de comandos en pipelines de CI/CD y pequeñas tareas de sistema. La coexistencia de ambos es la práctica estándar en entornos DevOps reales.

Ansible queda descartado por solaparse con ArgoCD en la gestión del estado del clúster y por ofrecer menos flexibilidad que Python para la lógica de aprovisionamiento compleja.

Terraform queda fuera del alcance actual del proyecto, aunque podría incorporarse en una fase futura de infraestructura como código completa.

---

## 4. Resumen ejecutivo de decisiones

| Componente | Tecnología elegida | Descartadas | Razón principal de la elección |
|---|---|---|---|
| Base de datos | **MariaDB** | MySQL, PostgreSQL | Bajo consumo de RAM, thread pool Community, Galera Cluster, licencia libre total |
| Servidor web | **Nginx + PHP-FPM** | Apache, Caddy | Arquitectura asíncrona, estándar en K8s (ingress-nginx), WAF con ModSecurity, plantillas |
| Automatización principal | **Python** | Ansible, Terraform | Cliente K8s y AWS oficiales, Jinja2, manejo de errores robusto, legibilidad |
| Automatización secundaria | **Bash** | — | Tareas simples de sistema, entrypoints de contenedores, pipelines CI/CD |

Las cuatro decisiones responden al mismo principio: elegir la tecnología con mejor encaje técnico para el perfil de recursos disponibles y el tipo de trabajo a realizar, sin añadir complejidad que no esté justificada por el alcance real del proyecto. No se ha elegido la opción más sofisticada en cada categoría, sino la más adecuada para este contexto específico.
