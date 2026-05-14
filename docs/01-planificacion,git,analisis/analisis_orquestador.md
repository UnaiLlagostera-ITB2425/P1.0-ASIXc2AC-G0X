# Elección del orquestador de contenedores: Kubernetes (K8s)

## Introducción

La elección del orquestador de contenedores es la decisión más crítica de este proyecto. Tras analizar las opciones, se ha optado por **Kubernetes nativo (distribuido mediante kubeadm)**. A diferencia de las distribuciones ligeras o simplificadas, Kubernetes estándar ofrece el mayor grado de control, transparencia y fidelidad a los estándares de la industria, garantizando que la arquitectura sea portable a cualquier proveedor de nube sin dependencias de terceros y permitiendo integrar de forma nativa el plano de red con Calico, la exposición de servicios con Ingress NGINX y la automatización TLS con cert-manager.

Este documento justifica la elección de **K8s** a partir de la arquitectura finalmente implantada, donde el clúster se ejecuta sobre instancias EC2 autogestionadas, el tráfico externo entra directamente por el Ingress Controller desplegado dentro de Kubernetes y los certificados se emiten y renuevan desde el propio clúster sin componentes externos adicionales.

---

## 1. Contexto y restricciones del entorno

### 1.1 Infraestructura disponible
El despliegue se realiza sobre instancias EC2 separadas por rol funcional, con un nodo de control, un nodo submaster que actúa como punto de entrada público ejecutando Ingress NGINX y un nodo worker adicional para carga de trabajo de aplicación; el manual también contempla una instancia dedicada para la base de datos fuera del clúster cuando la persistencia se desacopla del plano de cómputo.

| Nodo | Subred | Rol K8s | Función principal |
|---|---|---|---|
| Control Plane | Privada | **Master** | API Server, Scheduler, Controller Manager, etcd |
| Submaster | Pública | **Worker + Ingress** | Ingress NGINX Controller, entrada HTTP/HTTPS, pods de aplicación |
| Worker | Privada | **Worker** | Ejecución de Pods de aplicación |
| DDBB | Privada | **Externo** | Nodo dedicado MariaDB/MySQL fuera del clúster cuando aplica |

### 1.2 Restricción operativa real
La restricción principal no es solo el tamaño de la instancia, sino la necesidad de operar un clúster completo sin servicios gestionados de AWS y manteniendo trazabilidad total sobre cada componente. Ese requisito hace inviable delegar funciones críticas en servicios externos y refuerza la necesidad de un orquestador cuyo comportamiento pueda inspeccionarse en detalle, ajustarse manualmente y depurarse a bajo nivel.

Además, la solución implantada introduce exigencias que solo se resuelven correctamente dentro del propio clúster: un CNI funcional desde bootstrap, exposición directa del Ingress en los puertos 80 y 443, gestión de certificados mediante recursos nativos de Kubernetes y coordinación entre control plane, networking y servicios. Todo ello convierte a Kubernetes estándar en una elección arquitectónica, no solo operativa.

---

## 2. Por qué Kubernetes "Vanilla" (kubeadm) sobre otras opciones

### 2.1 Comparativa Técnica

| Criterio | K8s (kubeadm) | K3s / k0s | MicroK8s |
|---|---|---|---|
| **Estandarización** | **Total (Referencia CNCF)** | Distribución modificada | Dependiente de empaquetado adicional |
| **Componentes** | Desacoplados (static pods y procesos identificables) | Binario unificado con mayor abstracción | Servicios empaquetados con menor transparencia |
| **Backend de estado** | **etcd** visible y administrable | Backend simplificado o integrado según distribución | Backend abstractado |
| **Transparencia** | Máxima, cada fallo puede aislarse por componente | Menor visibilidad interna | Media |
| **Ajuste fino** | Alto, permite modificar API Server, red y services | Limitado por diseño simplificado | Medio |
| **Alineación con la solución final** | **Total** | Parcial | Parcial |

### 2.2 Razones del descarte de alternativas
- **K3s/k0s:** Aunque consumen menos recursos, abstraen decisiones internas que en este proyecto sí fueron necesarias modificar, como el comportamiento del API Server, la red CNI y la exposición del Ingress en puertos estándar 80 y 443. La solución final exigió cambiar el rango de NodePorts en el kube-apiserver y validar el efecto operativo de ese cambio sobre ingress-nginx, algo que encaja mejor con kubeadm que con distribuciones más opacas.
- **Amazon EKS:** Rompe el principio de autogestión total y añade dependencia directa de servicios gestionados de AWS. Además, la arquitectura implantada persigue explícitamente mantener el stack portable y controlado de extremo a extremo dentro de EC2.
- **MicroK8s:** Añade una capa de empaquetado y operación que no aporta ventajas concretas frente a kubeadm en una solución donde el objetivo es comprender y documentar cada componente del control plane, la red y el ingreso HTTPS.

---

## 3. Análisis detallado de Kubernetes (kubeadm)

**kubeadm** es la herramienta estándar para crear clústeres Kubernetes alineados con las prácticas de instalación oficiales. En este proyecto su valor no es solo pedagógico, sino estructural: permitió desplegar un clúster donde la red de pods con Calico, la exposición del Ingress y la automatización de certificados se resuelven utilizando primitivas nativas del ecosistema Kubernetes, sin atajos externos.

### 3.1 Arquitectura del Plano de Control
A diferencia de alternativas más simplificadas, Kubernetes desplegado con kubeadm expone claramente sus componentes de control plane como unidades diferenciadas y administrables. Esa separación resulta esencial cuando se deben ajustar parámetros del `kube-apiserver`, verificar el estado del clúster tras cambios en manifiestos estáticos o diagnosticar errores como la caída del API Server por un formato YAML incorrecto en `kube-apiserver.yaml`.

Esto aporta tres ventajas directas a la solución: observabilidad real de cada componente, capacidad de recuperación controlada a través de kubelet y trazabilidad completa sobre la seguridad TLS interna del clúster desde su inicialización. La necesidad de inspeccionar el API Server, el kubelet y los manifiestos estáticos durante la adaptación del rango de NodePorts confirma que esta transparencia no fue opcional, sino necesaria.

### 3.2 Kubernetes como plataforma de integración del stack
La justificación de Kubernetes se refuerza con los cambios aplicados en la arquitectura final. El tráfico ya no atraviesa un proxy NGINX externo en Docker, sino que entra directamente al Ingress NGINX Controller desplegado como workload del clúster, lo que desplaza la inteligencia de entrada al propio orquestador y convierte a Kubernetes en el punto real de terminación y decisión de routing.

Ese cambio solo tiene sentido cuando el orquestador puede coordinar servicios, ingresses, certificados, secrets, pods y conectividad de red como un mismo sistema. Kubernetes aporta precisamente esa superficie unificada de control mediante recursos declarativos, reconciliación automática y separación estricta entre estado deseado y estado observado.

### 3.3 Gestión de red con Calico
La elección de Kubernetes también queda justificada por la necesidad de un modelo de red de pods completo y extensible. En la solución implantada, Calico actúa como CNI del clúster, aportando conectividad entre pods y servicios, distribución de rutas mediante BGP y encapsulación IP-in-IP CrossSubnet cuando el tráfico cruza subredes distintas en AWS.

Esta integración no es un accesorio, sino una característica central del orquestador. Sin un CNI activo, los pods no pueden comunicarse entre sí ni con el propio `kube-apiserver`, y la solución requirió incluso resolver el problema de bootstrap de Calico precreando manualmente el kubeconfig del plugin CNI en todos los nodos para romper la dependencia circular del arranque. La necesidad de este nivel de intervención demuestra que se necesitaba un Kubernetes completo y transparente, no una distribución que escondiera estos mecanismos.

### 3.4 Exposición de servicios e Ingress
Kubernetes permite modelar la exposición externa mediante Services e Ingresses como objetos de primer nivel. En esta arquitectura, ingress-nginx se publica como servicio NodePort y se adapta el rango permitido por el API Server para incluir los puertos 80 y 443, ya que en AWS la traducción con reglas locales de iptables no resultó fiable debido al comportamiento previo de las Elastic IP en la infraestructura de red.

Esta decisión técnica es una de las justificaciones más fuertes para elegir kubeadm: el proyecto necesitó modificar el comportamiento base del clúster para alinear la entrada pública con los puertos estándar de HTTP y HTTPS. Kubernetes estándar permitió realizar ese ajuste de forma explícita, verificable y documentable.

### 3.5 Automatización TLS con cert-manager
La plataforma final no solo ejecuta aplicaciones, sino que también gestiona certificados como parte del propio ciclo de vida del sistema. cert-manager automatiza la solicitud, validación, emisión y renovación de certificados TLS, y lo hace usando recursos nativos de Kubernetes como `ClusterIssuer`, `Certificate`, `Order` y `Challenge`.

Esta integración justifica el uso de Kubernetes como orquestador porque el clúster deja de ser un mero scheduler de contenedores para convertirse en una plataforma de operaciones declarativas. La validación HTTP-01 depende del Ingress NGINX, del acceso al puerto 80 público, del DNS apuntando al submaster y de la capacidad del clúster para crear recursos temporales durante el challenge; todo el flujo se resuelve dentro del ecosistema Kubernetes.

---

## 4. Implementación y Automatización

La instalación se automatiza mediante scripts y procedimientos reproducibles para minimizar errores manuales y mantener consistencia entre nodos. Sin embargo, la automatización no sustituye a la comprensión de la plataforma: en esta solución fue necesario intervenir sobre manifests del API Server, validar el estado de Calico, parchear el servicio de ingress-nginx y verificar recursos de cert-manager.

### 4.1 Secuencia de Despliegue
1. **Pre-requisitos:** Instalación del runtime de contenedores y preparación del sistema base para kubeadm.
2. **Inicialización:** `kubeadm init` del control plane con la configuración de red del clúster.
3. **Red (CNI):** Instalación de **Calico** como plugin CNI por su capacidad de aportar conectividad entre pods, BGP entre nodos y control fino del comportamiento en AWS.
4. **Bootstrap de Calico:** Precreación del kubeconfig de `calico-cni-plugin` en todos los nodos para evitar el bloqueo circular del init container cuando aún no existe red CNI funcional.
5. **Join de Workers:** Unión de los workers al clúster mediante kubeadm y validación del estado `Ready`.
6. **Ingress:** Despliegue de **ingress-nginx** y adaptación del rango de NodePorts para exponer 80 y 443 directamente.
7. **TLS:** Instalación de **cert-manager**, creación del `ClusterIssuer` y emisión de certificados mediante HTTP-01.

### 4.2 Configuración del Ingress Controller
Se instala **ingress-nginx** como controlador de entrada del clúster porque centraliza el routing HTTP/HTTPS desde objetos Ingress nativos y encaja con el flujo final de certificados, redirección a HTTPS y cabeceras `X-Forwarded-*`. A diferencia del diseño anterior, ya no depende de un NGINX externo; esto reduce latencia, elimina un punto adicional de fallo y refuerza el papel de Kubernetes como plataforma unificada de entrada, exposición y seguridad.

---

## 5. Viabilidad técnica y operativa

Utilizar Kubernetes "Vanilla" es viable no solo por coste, sino por coherencia arquitectónica. La solución final demuestra que kubeadm permitió construir un clúster capaz de operar networking overlay con Calico, exposición pública con ingress-nginx y automatización TLS con cert-manager sin recurrir a controladores propietarios de AWS ni a componentes externos para compensar carencias del orquestador.

También se confirma la viabilidad operativa porque el manual incorpora procedimientos concretos de verificación y troubleshooting para todos los elementos críticos: estado de nodos, salud de Calico, establecimiento de BGP, disponibilidad del Ingress, validez del `ClusterIssuer`, emisión de certificados y diagnóstico del API Server. Este grado de observabilidad y control es precisamente uno de los argumentos más sólidos a favor de Kubernetes nativo.

---

## 6. Decisión Final: Kubernetes Nativo

**Se elige Kubernetes (kubeadm) por ser la opción que mejor soporta la arquitectura finalmente implantada y por ofrecer control total sobre red, ingreso, seguridad TLS y operación del clúster.**

### Resumen de la Decisión

| Componente | Selección | Justificación |
|---|---|---|
| **Distribución** | **Kubernetes Vanilla** | Estándar de facto, sin vendor lock-in y con control completo del clúster. |
| **Herramienta** | **kubeadm** | Método oficial para desplegar y ajustar el control plane y los workers. |
| **Runtime** | **Container runtime compatible con CRI** | Integración nativa con kubelet y ejecución estándar de pods. |
| **Network Plugin** | **Calico** | Conectividad entre pods, BGP, IP-in-IP CrossSubnet y base para segmentación futura. |
| **Ingress** | **NGINX Ingress** | Entrada directa al clúster en 80/443, routing por host/path y terminación TLS. |
| **Gestión TLS** | **cert-manager + Let’s Encrypt** | Emisión y renovación automática de certificados desde recursos nativos del clúster. |

> **Conclusión:** Aunque existen alternativas más ligeras, **Kubernetes nativo** es la opción que mejor justifica una arquitectura profesional, auditable y extensible. Los cambios realizados en la solución — entrada directa por Ingress NGINX, red de pods con Calico y automatización TLS con cert-manager — no reducen la necesidad de Kubernetes estándar, sino que la refuerzan, porque convierten al clúster en el núcleo real de la operación, la seguridad y la conectividad del sistema.
