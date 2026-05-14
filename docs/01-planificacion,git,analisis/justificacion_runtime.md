# Elección del runtime de contenedores

## Introducción

Antes de entrar en la comparativa técnica, es necesario entender qué es exactamente un **runtime de contenedores** y qué papel ocupa dentro de la arquitectura del proyecto. Sin esta base, las diferencias entre Docker y containerd pueden parecer abstractas o irrelevantes, cuando en realidad son una decisión técnica con impacto directo en el rendimiento, la seguridad y la compatibilidad del clúster.

---

## 1. ¿Qué es un runtime de contenedores?

Un contenedor no es más que un proceso Linux aislado. Para crearlo y ejecutarlo, alguien tiene que hablar con el kernel del sistema operativo y pedirle que active los mecanismos de aislamiento: **namespaces** (para aislar el sistema de ficheros, la red, los procesos y los usuarios) y **cgroups** (para limitar la CPU, la memoria y otros recursos).

El **runtime de contenedores** es el software que hace exactamente eso: recibe una instrucción del orquestador ("lanza este contenedor con esta imagen y estos límites de recursos"), prepara el entorno de ejecución y arranca el proceso. Es la capa que está entre el orquestador (K3s, en nuestro caso) y el kernel de Linux.

Existen dos niveles de runtime:

- **Runtime de bajo nivel** (*low-level runtime*): habla directamente con el kernel. El estándar es **runc**, que es el motor que arranca el proceso aislado. Casi todos los runtimes de alto nivel delegan en runc (u otro runtime OCI compatible) para la ejecución real.
- **Runtime de alto nivel** (*high-level runtime*): gestiona el ciclo de vida completo: descargar imágenes, desempaquetar capas, preparar el sistema de ficheros, llamar a runc y gestionar el estado del contenedor. Aquí es donde se sitúan **containerd** y **Docker**.

```
Kubernetes (K3s)
      │
      ▼ (llamada via CRI - Container Runtime Interface)
  containerd  ◄──── runtime de alto nivel
      │
      ▼ (llamada via OCI - Open Container Initiative)
    runc        ◄──── runtime de bajo nivel
      │
      ▼
  Kernel Linux (namespaces + cgroups)
```

La **Container Runtime Interface (CRI)** es el contrato estándar que Kubernetes usa para hablar con el runtime. Cualquier runtime que implemente CRI puede ser usado directamente por Kubernetes. Este dato es clave para entender el problema histórico con Docker.

---

## 2. El problema histórico de Docker con Kubernetes

Docker fue el primer runtime que usó Kubernetes, mucho antes de que existiera un estándar. En aquel momento, Kubernetes hablaba directamente con la API de Docker, un protocolo que no estaba diseñado para la orquestación. Cuando en 2016 el proyecto Kubernetes introdujo la CRI para poder soportar múltiples runtimes de forma limpia, Docker tenía un problema: **Docker Engine no implementaba CRI**.

Para no romper la compatibilidad con los millones de clústeres que ya usaban Docker, el proyecto Kubernetes creó un adaptador interno llamado **dockershim**: una capa de traducción que convertía las llamadas CRI de Kubernetes en llamadas a la API de Docker. Era una solución de compromiso temporal que se volvió permanente durante años.

Este adaptador era técnicamente problemático:

- Añadía una capa de indirección: `kubelet → dockershim → Docker daemon → containerd → runc`.
- Docker internamente ya delegaba la ejecución en **containerd** desde la versión 1.11 (2016). Es decir, el camino real de una llamada era: Kubernetes llama a dockershim, que llama a Docker, que llama a containerd, que llama a runc. Tres capas intermedias para hacer lo que containerd podía hacer directamente.
- El código de dockershim era difícil de mantener y generaba bugs propios, independientes de los runtimes que envolvía.

La solución fue inevitable:

- **Kubernetes v1.20 (diciembre 2020)**: dockershim marcado como deprecated.
- **Kubernetes v1.24 (mayo 2022)**: dockershim eliminado definitivamente de Kubernetes.

A partir de Kubernetes v1.24, **Docker Engine ya no puede usarse como runtime de Kubernetes** a menos que se instale un adaptador externo (`cri-dockerd`, mantenido por Mirantis). Esta es la situación actual.

> **Aclaración importante**: el hecho de que Docker no pueda ser el runtime de Kubernetes **no significa que las imágenes Docker no funcionen**. Las imágenes Docker siguen siendo válidas porque siguen el estándar OCI (*Open Container Initiative*), que tanto containerd como CRI-O soportan plenamente. Se pueden construir imágenes con `docker build` y ejecutarlas en un clúster que use containerd sin ningún problema.

---

## 3. Alternativas al runtime evaluadas

### 3.1 Docker Engine (con cri-dockerd)

**Docker Engine** es la plataforma de contenedores más conocida y utilizada en el mundo del desarrollo. Incluye el demonio `dockerd`, una CLI completa (`docker`), BuildKit para construcción de imágenes, gestión de redes y volúmenes, Docker Compose y una interfaz de usuario opcional (Docker Desktop).

**Arquitectura cuando se usa con Kubernetes:**

Dado que Kubernetes v1.24 eliminó dockershim, la única forma de usar Docker Engine como runtime en Kubernetes actualmente es instalar **cri-dockerd**, un adaptador externo que reimplementa la CRI sobre Docker. Esto restaura la cadena completa:

```
K3s (kubelet)
      │
      ▼ (CRI)
  cri-dockerd    ◄──── adaptador externo (proceso adicional)
      │
      ▼
Docker daemon (dockerd)
      │
      ▼
  containerd
      │
      ▼
    runc
      │
      ▼
Kernel Linux
```

Esta cadena tiene **cuatro capas** entre el kubelet y el kernel. Cada capa es un proceso adicional, un punto de fallo potencial y un consumo de memoria que se acumula.

**Ventajas de Docker Engine:**

- CLI familiar e intuitiva: `docker ps`, `docker logs`, `docker exec`, `docker inspect`.
- BuildKit integrado para construcción de imágenes con caché avanzada.
- Docker Compose para gestión de servicios en local.
- La herramienta de desarrollo de contenedores más documentada del mundo.
- Ideal para el entorno de desarrollo local del equipo.

**Por qué queda descartado como runtime de producción en este proyecto:**

- **Consumo de memoria adicional**: el demonio de Docker (`dockerd`) consume entre 80-120 MB de RAM en reposo por sí solo. Sumado al proceso cri-dockerd, se añaden más de 150 MB de overhead exclusivamente para mantener una capa de compatibilidad. En nodos con 2 GB de RAM (Master, Worker 2, DDBB), este coste no está justificado.
- **Cuatro capas hasta el kernel**: K3s → cri-dockerd → dockerd → containerd → runc. Containerd es la capa que realmente ejecuta los contenedores; Docker es solo un intermediario adicional.
- **Mantenimiento externo de cri-dockerd**: cri-dockerd es un proyecto de Mirantis, no del núcleo de Kubernetes. Depender de él introduce una dependencia externa adicional cuya cadencia de mantenimiento y compatibilidad hay que vigilar.
- **K3s incluye containerd integrado**: usar Docker requeriría desinstalar el containerd de K3s e instalar Docker Engine + cri-dockerd, añadiendo complejidad sin ninguna ventaja en producción.
- **No apto para el perfil de uso en producción**: las funcionalidades diferenciales de Docker (BuildKit, Compose, Desktop) son herramientas de **desarrollo**, no de ejecución en producción. En un nodo del clúster que solo ejecuta pods, estas funcionalidades no se usan nunca.

---

### 3.2 CRI-O

**CRI-O** es un runtime de contenedores de alto nivel diseñado exclusivamente para Kubernetes, desarrollado originalmente por Red Hat. Su objetivo declarado es ser el runtime mínimo necesario para cumplir la CRI de Kubernetes, sin ninguna funcionalidad adicional.

**Arquitectura:**

```
K3s (kubelet)
      │
      ▼ (CRI)
   CRI-O        ◄──── runtime de alto nivel (solo Kubernetes)
      │
      ▼ (OCI)
    runc
      │
      ▼
Kernel Linux
```

CRI-O es técnicamente muy limpio: implementa exactamente la CRI sin añadir nada más. No tiene CLI propia para desarrolladores, no gestiona imágenes fuera del contexto de Kubernetes y no incluye herramientas de red o volúmenes propias.

**Ventajas:**

- Diseño mínimo, orientado exclusivamente a Kubernetes.
- Bajo consumo de memoria por su diseño minimalista.
- Seguridad mejorada: no corre con privilegios de root por defecto.
- Integración nativa con el ecosistema Red Hat/OpenShift.

**Por qué queda descartado:**

- **No está incluido en K3s**: K3s viene con containerd integrado. Usar CRI-O requeriría desactivar containerd y configurar CRI-O manualmente, añadiendo pasos de instalación sin ninguna ventaja técnica que lo justifique.
- **Comunidad y documentación más pequeña que containerd**: fuera del ecosistema Red Hat, CRI-O tiene menos recursos documentados, especialmente para integraciones con K3s, AWS EC2 y las herramientas del stack del proyecto.
- **Sin CLI de usuario**: la ausencia de una interfaz de usuario directa hace que el debugging de contenedores sea más complejo para el equipo.
- **No aporta ventajas sobre containerd en este contexto**: containerd y CRI-O tienen un rendimiento muy similar en benchmarks publicados. La diferencia técnica no justifica el coste de configuración adicional.

---

### 3.3 Containerd

**containerd** es un runtime de contenedores de alto nivel mantenido por la **CNCF** (Cloud Native Computing Foundation). Fue extraído del código fuente de Docker en 2016 y donado a la CNCF en 2017. Hoy es el runtime por defecto de **Docker Engine** (que lo usa internamente), de **K3s**, de **K8s** vainilla con kubeadm, de **EKS**, de **GKE** y de **AKS**. Es, de facto, el runtime estándar del ecosistema Kubernetes.

**Arquitectura:**

```
K3s (kubelet)
      │
      ▼ (CRI directo, sin intermediarios)
  containerd   ◄──── runtime de alto nivel
      │
      ▼ (OCI)
    runc
      │
      ▼
Kernel Linux
```

A diferencia de Docker, containerd implementa la CRI de forma nativa. El kubelet de K3s se comunica directamente con containerd sin ninguna capa de adaptación. Esto elimina completamente las capas intermedias y reduce la cadena de llamadas al mínimo técnicamente posible.

**Responsabilidades de containerd:**

- Descarga y almacenamiento de imágenes OCI desde registries (Docker Hub, GitHub Container Registry, registries privados).
- Gestión de snapshots: desempaquetado de las capas de la imagen para construir el sistema de ficheros del contenedor.
- Gestión del ciclo de vida del contenedor: arranque, pausa, reanudación y parada.
- Comunicación con runc para la ejecución real del proceso aislado.
- Soporte de múltiples namespaces para aislar entornos (K3s usa el namespace `k8s.io`).

**Fortalezas para este proyecto:**

- **Incluido en K3s sin instalación adicional**: containerd viene integrado en el binario de K3s. No hay que instalar nada, configurar repositorios ni gestionar versiones de forma independiente.
- **Comunicación directa con el kubelet vía CRI**: sin intermediarios, sin capas de adaptación, sin procesos adicionales. Esto reduce la latencia de operaciones de contenedor (arranque, parada, actualización de imágenes) y elimina puntos de fallo.
- **Menor consumo de memoria que Docker**: al eliminar el demonio de Docker y cri-dockerd, el runtime ocupa menos RAM. Según mediciones publicadas, containerd consume entre 30-50 MB de RAM en reposo, frente a los 80-120 MB del demonio de Docker solo.
- **Runtime por defecto de los principales proveedores cloud**: Amazon EKS, Google GKE y Microsoft AKS usan containerd como runtime por defecto desde 2022-2023. Esto garantiza que cualquier imagen o configuración validada en el proyecto funcionará en un entorno productivo real sin cambios.
- **Compatibilidad total con imágenes OCI**: cualquier imagen construida con `docker build`, `buildah`, `kaniko` o cualquier otra herramienta compatible con el estándar OCI funciona con containerd sin modificaciones.
- **Soporte de la CNCF**: containerd es un proyecto graduado de la CNCF (el nivel más alto de madurez), lo que garantiza mantenimiento a largo plazo, gobernanza abierta y compatibilidad con el ecosistema Kubernetes.
- **CLI de administración (crictl y nerdctl)**: aunque no tiene la CLI de usuario de Docker, containerd dispone de `crictl` (la herramienta estándar CRI para debugging) y de `nerdctl`, una CLI compatible con Docker que permite usar comandos como `nerdctl ps`, `nerdctl logs` o `nerdctl pull` con la misma sintaxis.

**Limitaciones:**

- No incluye herramientas de construcción de imágenes. Para construir imágenes en local, el equipo seguirá usando Docker en sus máquinas de desarrollo. Esto no es un problema: las máquinas de los desarrolladores usan Docker, el clúster usa containerd, y las imágenes (en formato OCI) son compatibles con ambos.
- La CLI `crictl` tiene una sintaxis diferente a `docker`. Esto requiere una adaptación inicial del equipo para las tareas de debugging en los nodos del clúster.

---

## 4. Tabla comparativa

| Criterio | Docker Engine (+ cri-dockerd) | CRI-O | Containerd |
|---|---|---|---|
| Implementa CRI nativamente | ❌ No (requiere cri-dockerd) | ✅ Sí | ✅ Sí |
| Capas hasta el kernel | 4 (kubelet→cri-dockerd→dockerd→containerd→runc) | 2 (kubelet→CRI-O→runc) | **2 (kubelet→containerd→runc)** |
| Incluido en K3s | ❌ No | ❌ No | ✅ **Sí (nativo)** |
| RAM en reposo (runtime) | ~150 MB (dockerd+cri-dockerd) | ~30 MB | **~30-50 MB** |
| Estándar en K8s vanilla, EKS, GKE, AKS | ❌ No | ❌ No | ✅ **Sí** |
| Proyecto CNCF graduado | ❌ No | ✅ Sí | ✅ **Sí** |
| Soporte imágenes OCI (Docker Hub, GHCR) | ✅ Sí | ✅ Sí | ✅ **Sí** |
| CLI de usuario integrada | ✅ Sí (docker) | ❌ No | ⚠️ crictl + nerdctl |
| Construcción de imágenes | ✅ Sí (BuildKit) | ❌ No | ❌ No (externo: buildkit) |
| Complejidad de instalación en K3s | Alta (desinstalar containerd, instalar docker+cri-dockerd) | Media (configuración manual) | **Ninguna (ya integrado)** |
| Proceso adicional en el nodo | dockerd + cri-dockerd | Ninguno | **Ninguno** |
| Debugging con kubectl | Limitado (requiere sync) | ✅ Via crictl | ✅ **Via crictl** |
| Rendimiento en arranque de pods | Más lento (más capas) | Más rápido | **Más rápido** |
| Adecuado para desarrollo local | ✅ Ideal | ❌ No | ⚠️ Con nerdctl |
| Adecuado para runtime en producción K8s | ❌ No recomendado | ✅ Sí | ✅ **Sí (mejor opción)** |

---

## 5. Separación de entornos: desarrollo vs. producción

Un punto que merece explicación explícita es la diferencia entre el runtime que se usa en **desarrollo local** y el que se usa en **producción en el clúster**.

| Entorno | Herramienta | Justificación |
|---|---|---|
| **Desarrollo local** (portátil del equipo) | Docker Engine | CLI familiar, BuildKit para construir imágenes, Docker Compose para levantar servicios de forma rápida |
| **CI/CD** (GitHub Actions) | Docker Engine (para build) | Los pipelines de GitHub Actions usan Docker para construir y publicar imágenes al registry |
| **Producción en el clúster** (nodos EC2) | **containerd** | Runtime nativo de K3s, sin capas innecesarias, menor consumo de RAM, estándar en producción |

Esta separación es la práctica estándar en la industria. El equipo de desarrollo **no necesita containerd en su máquina** porque trabaja con Docker. El clúster **no necesita Docker** porque solo ejecuta pods, no construye imágenes. Las imágenes que construye Docker cumplen el estándar OCI y containerd las ejecuta sin ningún problema.

> **Analogía**: es como separar la fábrica que produce los coches (Docker en CI/CD) de la carretera por la que circulan (containerd en producción). El coche (la imagen OCI) es compatible con ambas.

---

## 6. Consumo de recursos en el contexto del clúster

Para contextualizar el impacto en la arquitectura real del proyecto, la siguiente tabla muestra el overhead de cada runtime en el nodo Master (t3.small, 2 GB), teniendo en cuenta que ya tiene una presión de memoria ajustada con el plano de control de K3s:

| Runtime | Overhead en nodo | Margen de RAM adicional disponible vs. Docker |
|---|---|---|
| Docker Engine + cri-dockerd | ~150 MB adicionales | — |
| CRI-O | ~30 MB | +120 MB |
| **Containerd** | **~40 MB** | **+110 MB** |

En el nodo Worker principal (t3.medium, 4 GB) la diferencia de 110-120 MB entre Docker y containerd es menos crítica. Pero en el nodo Master (t3.small, 2 GB), donde el plano de control de K3s ya consume ~1.430 MB, ahorrarse 110 MB es relevante para la estabilidad del nodo.

---

## 7. Decisión final: Containerd

**Elegimos containerd como runtime de contenedores del proyecto en todos los nodos del clúster.**

### Razones principales

**1. Ya está incluido en K3s.** No hay que instalar nada adicional, no hay que gestionar versiones por separado y no hay que configurar ningún adaptador de compatibilidad. El binario de K3s y containerd son un único paquete.

**2. Elimina capas innecesarias.** La comunicación es directa: K3s → containerd → runc. Usando Docker Engine, la cadena sería: K3s → cri-dockerd → dockerd → containerd → runc. Es añadir tres capas para llegar al mismo punto.

**3. Es el runtime estándar en producción.** Amazon EKS, Google GKE, Microsoft AKS y Kubernetes vanilla con kubeadm usan containerd por defecto. Elegirlo garantiza que el conocimiento y las configuraciones del proyecto son directamente transferibles a cualquier entorno productivo real.

**4. Menor consumo de memoria.** En nodos con 2 GB de RAM como el Master, el Worker 2 y el DDBB, cada MB que no se gasta en overhead del runtime es un MB disponible para los pods de las aplicaciones.

**5. Proyecto CNCF graduado.** Containerd tiene el nivel más alto de madurez dentro de la CNCF, con mantenimiento garantizado, gobernanza abierta y compatibilidad asegurada con las versiones futuras de Kubernetes.

Docker Engine sigue siendo la herramienta de desarrollo local del equipo, para construir imágenes y levantar entornos de prueba. Pero en los nodos del clúster de producción, no tiene ningún rol.

---

## 8. Resumen ejecutivo

| Parámetro | Valor |
|---|---|
| Runtime elegido | **containerd** |
| Versión | La incluida en el binario de K3s (canal `stable`) |
| Instalación | Sin instalación adicional (integrado en K3s) |
| Comunicación con K3s | Directa via CRI (sin adaptadores) |
| Runtime de bajo nivel | runc (estándar OCI, incluido en containerd) |
| CLI de debugging en nodos | `crictl` (para operaciones CRI) |
| Construcción de imágenes | Docker Engine en local y en pipelines CI/CD |
| Alternativas descartadas | Docker Engine + cri-dockerd (capas innecesarias, mayor RAM), CRI-O (no incluido en K3s, menor comunidad) |
| Compatibilidad con imágenes Docker Hub | ✅ Sí (formato OCI estándar) |
