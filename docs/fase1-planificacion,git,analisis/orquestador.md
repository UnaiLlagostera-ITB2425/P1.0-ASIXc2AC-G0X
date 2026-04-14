# Elección del orquestador de contenedores

## Introducción

La elección del orquestador de contenedores es una de las decisiones de arquitectura más críticas del proyecto. El orquestador gestiona el ciclo de vida completo de todos los servicios: cuándo arrancan, cuántos recursos consumen, cómo se comunican, cómo se recuperan de fallos y cómo escalan. Una elección errónea en esta capa compromete tanto la viabilidad técnica del proyecto como la sostenibilidad del gasto en la nube.

Este documento recoge el análisis completo de las distribuciones de Kubernetes disponibles, su comparativa técnica detallada y la justificación de la decisión final, teniendo en cuenta de forma explícita las restricciones reales del entorno: cuentas **AWS Educate Starter** con un crédito total de **150 USD**, región forzada **us-east-1**, instancias limitadas a la familia **t3.small** (2 vCPU, 2 GB de RAM) y un clúster de cuatro nodos distribuidos entre subred pública y privada.

---

## 1. Contexto y restricciones del entorno

### 1.1 Infraestructura disponible

La plataforma se despliega sobre cuatro instancias EC2 **t3.small** distribuidas en la VPC del proyecto:

| Nodo | Subred | Función principal | vCPU | RAM |
|---|---|---|---|---|
| Master | Pública (10.0.1.0/24) | Plano de control K3s + NGINX reverse proxy | 2 | 2 GB |
| Worker | Privada (10.0.2.0/24) | Agente K3s, pods de aplicación | 2 | 2 GB |
| Worker 2 | Privada (10.0.2.0/24) | Agente K3s, pods de aplicación | 2 | 2 GB |
| DDBB | Privada (10.0.2.0/24) | Motor MariaDB (nodo dedicado) | 2 | 2 GB |

Esta arquitectura no es arbitraria: la separación de la base de datos en un nodo dedicado responde a criterios de rendimiento (perfil de E/S diferente al de los pods de aplicación), seguridad (Security Group `SG-DDBB-Private` que acepta TCP/3306 exclusivamente desde los Workers) y escalabilidad futura (se puede redimensionar independientemente del resto del clúster).

### 1.2 Restricciones que condicionan la elección del orquestador

- **RAM disponible en el nodo Master**: 2 GB, compartidos entre el sistema operativo, el plano de control del orquestador, el proceso NGINX y los componentes de monitorización (exportadores de métricas).
- **Coste del orquestador**: servicios gestionados como **Amazon EKS** implican un coste adicional de $0,10/hora por el plano de control (independiente del coste de las instancias), lo que sumaría ~$73/mes solo por el control plane, consumiendo la mitad del crédito total en el primer mes.
- **Región forzada**: las cuentas AWS Educate Starter operan exclusivamente en **us-east-1**. No existe posibilidad de elegir otra región.
- **Sistema operativo en las AMI de AWS**: las imágenes oficiales de AWS (Amazon Linux 2023, Ubuntu Server) no incluyen snap por defecto, lo que afecta a distribuciones que dependen de ese gestor de paquetes.
- **Presupuesto total**: 150 USD distribuidos entre tres cuentas. El orquestador no puede generar costes adicionales de licencia ni de infraestructura gestionada.

### 1.3 Requisitos técnicos del orquestador

| Requisito | Descripción |
|---|---|
| Consumo mínimo de memoria | El plano de control debe dejar margen suficiente en 2 GB de RAM para NGINX y los componentes auxiliares |
| Instalación reproducible | Despliegue scriptable en un único comando, compatible con la automatización en Python del proyecto |
| Certificación CNCF | Compatibilidad garantizada con manifiestos, Helm charts, ArgoCD, cert-manager e ingress-nginx |
| Multi-nodo nativo | Soporte real de clúster con nodo Master separado de los Workers, no solo modo monodo |
| Ingress Controller | Disponible de serie o fácilmente integrable |
| Almacenamiento persistente | Soporte de PersistentVolumes para la base de datos y datos de los sitios |
| Sin coste de licencia | Completamente open source, sin cargo por el plano de control |
| Comunidad activa | Documentación madura, bugs corregidos con continuidad |

---

## 2. Distribuciones descartadas antes del análisis detallado

Antes de entrar en la comparativa, se identificaron varias opciones que quedan fuera del alcance por razones objetivas:

- **Amazon EKS**: Kubernetes gestionado por AWS. Incompatible con cuentas AWS Educate (el plano de control gestionado no está disponible) y con un sobrecoste de $0,10/hora que consumiría el crédito en semanas.
- **Minikube**: Diseñado para desarrollo local en una sola máquina. Sin soporte multi-nodo real ni almacenamiento persistente fiable. No adecuado para despliegues en EC2 con múltiples nodos.
- **Kind (Kubernetes in Docker)**: Kubernetes dentro de contenedores Docker, pensado para pipelines CI y tests automatizados. No es adecuado para despliegues persistentes con datos reales.
- **OpenShift (OKD)**: Distribución empresarial de Red Hat. Requiere un mínimo de 16 GB de RAM por nodo de control, completamente inviable para instancias t3.small.
- **Docker Swarm**: Orquestador nativo de Docker, más simple pero no compatible con la API de Kubernetes. Todos los Helm charts, manifiestos, ArgoCD, cert-manager e ingress-nginx no funcionan en Swarm.

---

## 3. Alternativas evaluadas en detalle

### 3.1 Kubernetes vanilla (kubeadm)

**kubeadm** es la herramienta oficial de la CNCF para instalar Kubernetes estándar sobre cualquier conjunto de máquinas Linux. No es una distribución, sino el método de instalación de referencia del proyecto Kubernetes.

**Arquitectura del plano de control:**

Una instalación con kubeadm despliega todos los componentes del control plane como pods estáticos: `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` y `etcd`. Cada componente corre en su propio contenedor con su propia configuración y ciclo de vida.

**Consumo de recursos en reposo (datos oficiales de la documentación de Kubernetes):**

Los requisitos mínimos declarados por la documentación oficial son **2 vCPU y 2 GB de RAM únicamente para el plano de control**. En la práctica, en un nodo con todos los componentes corriendo (etcd, API server, scheduler, controller manager, coreDNS, kube-proxy y kubelet), el consumo en reposo supera **1.500 MB de RAM** en el nodo de control. Esto deja menos de **500 MB de margen** para el sistema operativo base (~300 MB), NGINX (~100 MB en reposo) y los exportadores de métricas (~50 MB), situándose en el límite de la inviabilidad para un nodo t3.small.

**Por qué queda descartado:**

El consumo de recursos de kubeadm hace que el nodo Master opere permanentemente en condición de presión de memoria, con riesgo real de que el OOM Killer (Out-Of-Memory Killer) del kernel Linux termine procesos críticos del plano de control. Además, la instalación requiere múltiples pasos manuales (instalación de containerd, CNI, kubeadm, configuración de red, inicialización del clúster con `kubeadm init`, union de nodos con `kubeadm join`, instalación separada del Ingress Controller, cert-manager, etc.), lo que hace que la reproducibilidad automática mediante scripts sea significativamente más compleja que con distribuciones ligeras.

---

### 3.2 MicroK8s

**MicroK8s** es una distribución ligera de Kubernetes desarrollada y mantenida por **Canonical** (la empresa detrás de Ubuntu). Se distribuye exclusivamente como un **snap**, el formato de paquete propio de Canonical.

**Arquitectura:**

MicroK8s ejecuta los componentes del plano de control como procesos nativos del sistema (no como pods estáticos como kubeadm), lo que reduce el overhead. Usa `Dqlite` (una implementación distribuida de SQLite) como backend de estado en configuraciones HA, lo que elimina la necesidad de gestionar un clúster etcd externo. El consumo de RAM del plano de control en reposo es de aproximadamente **540 MB**, según la tabla de comparación publicada por SFEIR Institute en su análisis de distribuciones Kubernetes 2026.

MicroK8s tiene un sistema de **add-ons** que permite activar componentes con un único comando: `microk8s enable ingress`, `microk8s enable dns`, `microk8s enable storage`, etc. Esta facilidad es una de sus características más valoradas.

**Por qué queda por detrás de K3s en este proyecto:**

- **Dependencia crítica del gestor snap**: MicroK8s solo puede instalarse mediante snap. Las imágenes EC2 de **Amazon Linux 2023** no tienen snap disponible. En Ubuntu Server 22.04 LTS, snap está disponible, pero requiere una configuración adicional del sistema operativo antes de poder instalar MicroK8s. Esto rompe la reproducibilidad del despliegue automatizado.
- **Consumo de RAM ligeramente mayor que K3s**: 540 MB frente a los ~275 MB del agente K3s en los Workers y ~1.428 MB del servidor K3s con un agente (datos oficiales de la documentación de K3s). Aunque la diferencia puede parecer pequeña, en nodos de 2 GB cada MB cuenta.
- **Comunidad más pequeña en el ecosistema DevOps general**: MicroK8s tiene una comunidad fuerte dentro del ecosistema Canonical/Ubuntu, pero K3s tiene más del doble de GitHub stars (>27.000 frente a ~8.000) y una presencia más amplia en documentación, foros y tutoriales relacionados con despliegues en AWS y CI/CD.
- **Integración con AWS no es nativa**: la instalación automática de MicroK8s en una instancia EC2 requiere más pasos de preparación del sistema operativo que K3s.

---

### 3.3 k0s

**k0s** es una distribución de Kubernetes desarrollada por **Mirantis**, diseñada para ser lo más minimalista posible. Se distribuye como un único binario autónomo sin dependencias del sistema operativo.

**Arquitectura:**

k0s empaqueta todos los componentes del plano de control en un único proceso binario. Usa SQLite como backend por defecto en instalaciones de nodo único y kine con etcd en configuraciones HA. El consumo de RAM en reposo es similar al de K3s: aproximadamente **350-400 MB** para el plano de control.

**Fortalezas:**

- Binario autónomo sin dependencias del sistema operativo: puede instalarse literalmente copiando un fichero y ejecutándolo.
- Consumo de recursos comparable a K3s.
- Completamente open source, sin restricciones de licencia.

**Por qué queda por detrás de K3s:**

- **No incluye componentes de red ni Ingress por defecto**: k0s requiere elegir e instalar manualmente un CNI (Calico, Flannel, etc.) y un Ingress Controller, añadiendo pasos de configuración y decisiones de arquitectura que K3s ya tiene resueltas.
- **Comunidad significativamente más pequeña**: k0s tiene ~10.000 GitHub stars frente a >27.000 de K3s, lo que se traduce en menos documentación, menos ejemplos resueltos y menor probabilidad de encontrar soluciones a problemas específicos en un plazo razonable.
- **Madurez en producción menor**: aunque k0s está técnicamente bien construido, la adopción en entornos de producción documentados es menor que la de K3s, especialmente en integraciones con AWS EC2 y herramientas como ArgoCD.
- **No aporta ventajas concretas sobre K3s para este caso de uso**: el consumo de recursos es similar, pero k0s requiere más configuración inicial sin una razón técnica que lo justifique en el contexto de este proyecto.

---

### 3.4 K3s

**K3s** es una distribución de Kubernetes certificada por la CNCF, desarrollada originalmente por **Rancher Labs** y actualmente mantenida por **SUSE**. Fue publicada en 2019 y diseñada específicamente para entornos con recursos limitados: edge computing, IoT y clústeres pequeños en cloud. Con más de 27.000 GitHub stars y millones de instalaciones activas, es la distribución ligera de Kubernetes más utilizada del mundo.

**Arquitectura interna:**

K3s empaqueta toda la plataforma de Kubernetes en **un único binario de menos de 70 MB** que contiene:

- El plano de control completo (API server, scheduler, controller manager).
- El runtime de contenedores (**containerd** integrado).
- El plugin de red CNI (**Flannel** con VXLAN por defecto).
- **CoreDNS** para resolución de nombres dentro del clúster.
- El Ingress Controller (**Traefik**, sustituible por ingress-nginx).
- Un balanceador de carga simple (**Klipper LB**).
- El proveedor de almacenamiento local (**local-path-provisioner**).
- **SQLite embebido** como backend de estado para instalaciones de nodo único.

**Consumo de recursos (datos oficiales de la documentación de K3s, abril 2026):**

La documentación oficial de K3s publica los siguientes valores medidos en condiciones reales:

| Configuración | CPU mínima | RAM mínima (SQLite) | RAM mínima (etcd embebido) |
|---|---|---|---|
| Servidor K3s con carga de trabajo | 6% de 1 core | 1.596 MB | 1.606 MB |
| Clúster K3s con un agente | 5% de 1 core | 1.428 MB | 1.450 MB |
| Agente K3s únicamente | 3% de 1 core | 275 MB | 275 MB |

> **Interpretación para nuestra arquitectura**: el nodo **Master** corre el servidor K3s con cargas de trabajo, por lo que su consumo estimado del plano de control es de ~1.428-1.596 MB. Dado que el nodo Master tiene 2 GB y además corre NGINX, es necesario aplicar la configuración de ajuste de recursos descrita en la sección 6. Los nodos **Worker** corren únicamente el agente K3s (~275 MB), lo que les deja aproximadamente 1.400 MB libres para los pods de aplicación.

**Ventajas para este proyecto:**

- **Instalación en un único comando, reproducible y scriptable**: `curl -sfL https://get.k3s.io | sh -` instala K3s completamente en menos de 60 segundos. La unión de nodos Worker se realiza con una variable de entorno (`K3S_URL` y `K3S_TOKEN`). Este flujo es directamente integrable en los scripts Python de automatización del proyecto.
- **Certificación CNCF**: K3s pasa el mismo test suite de conformidad que Kubernetes estándar. Todos los manifiestos, Helm charts, ArgoCD, cert-manager e ingress-nginx funcionan sin modificaciones.
- **Sin dependencias del sistema operativo**: funciona en Amazon Linux 2023, Ubuntu Server, Debian y cualquier distribución Linux con kernel moderno. No requiere snap ni gestores de paquetes adicionales.
- **Backend SQLite para nodo único**: elimina la complejidad de gestionar un clúster etcd externo en la fase actual del proyecto. Cuando el proyecto escale, K3s soporta etcd nativo o bases de datos externas (incluida **MariaDB**, el motor elegido en este proyecto) para configuraciones HA.
- **Comunidad más activa de distribuciones ligeras**: >27.000 GitHub stars, millones de instalaciones activas, documentación oficial en español, integración con herramientas del ecosistema AWS y DevOps ampliamente probada.
- **Adoptado en producción real**: SUSE, Deutsche Telekom, Siemens y múltiples operadores de telecomunicaciones usan K3s en producción para cargas de trabajo en el edge, lo que garantiza que el mantenimiento del proyecto continuará a largo plazo.

**Limitaciones conocidas y cómo se gestionan:**

- **Consumo del servidor K3s en el nodo Master**: con ~1.428 MB para el plano de control en un nodo de 2 GB, el margen para NGINX y otros componentes es ajustado. Se gestiona mediante la configuración de reserva de recursos para el sistema y K3s (ver sección 6) y desactivando componentes no necesarios en el nodo Master (Traefik, Klipper LB).
- **SQLite no es adecuado para clústeres con muchos nodos**: para el tamaño del clúster actual (1 servidor + 2 workers + 1 DDBB dedicado), SQLite es perfectamente adecuado. Si el proyecto evolucionara a un entorno productivo con más nodos, se migraría a etcd embebido o a MariaDB como backend externo de kine.
- **Traefik como Ingress Controller por defecto**: se sustituirá por ingress-nginx en el despliegue, lo que requiere desactivar Traefik con el flag `--disable traefik` durante la instalación.

---

## 4. Tabla comparativa

| Criterio | K3s | MicroK8s | k0s | kubeadm |
|---|---|---|---|---|
| Certificación CNCF | ✅ Sí | ✅ Sí | ✅ Sí | ✅ Sí |
| RAM mínima (plano de control) | **~275 MB (agente) / ~1.428 MB (servidor)** | ~540 MB | ~350-400 MB | >1.500 MB |
| Tamaño del binario | **<70 MB** | ~200 MB (snap) | ~150 MB | >300 MB (múltiples) |
| Instalación (pasos mínimos) | **1 comando** | 1 comando (snap) | 2-3 pasos | 5-10 pasos |
| Dependencia del gestor de paquetes | **Ninguna** | Snap (Ubuntu) | Ninguna | APT/YUM + kubeadm |
| Compatible con Amazon Linux 2023 | ✅ Sí | ❌ No sin configuración snap | ✅ Sí | ✅ Sí |
| CNI incluido | Flannel | Calico | ❌ No | ❌ No |
| Ingress Controller incluido | Traefik (sustituible) | ❌ No (add-on) | ❌ No | ❌ No |
| Almacenamiento local incluido | ✅ Sí | ❌ No (add-on) | ❌ No | ❌ No |
| Backend de estado por defecto | SQLite / etcd embebido | Dqlite / etcd | SQLite / kine | etcd externo |
| Soporte HA multi-nodo | ✅ Sí | ✅ Sí | ✅ Sí | ✅ Sí |
| Coste de licencia | **$0** | **$0** | **$0** | **$0** |
| Compatible con EKS Educate | N/A | N/A | N/A | N/A |
| GitHub Stars (abril 2026) | **>27.000** | ~8.000 | ~10.000 | N/A |
| Adopción en producción | Alta | Alta | Media | Muy alta |
| Viable en t3.small con NGINX | ✅ Con ajuste de config | ⚠️ Justo | ✅ Con ajuste | ❌ Inviable |

---

## 5. Análisis de viabilidad de memoria por nodo

El siguiente análisis muestra la distribución estimada de RAM en el nodo **Master** (t3.small, 2 GB) con cada alternativa, en estado de reposo:

| Componente | K3s | MicroK8s | k0s | kubeadm |
|---|---|---|---|---|
| Sistema operativo base (Ubuntu 22.04) | ~300 MB | ~300 MB | ~300 MB | ~300 MB |
| Plano de control (orquestador) | ~1.430 MB | ~540 MB | ~380 MB | ~1.500 MB |
| NGINX (reverse proxy) | ~100 MB | ~100 MB | ~100 MB | ~100 MB |
| Exportadores de métricas | ~50 MB | ~50 MB | ~50 MB | ~50 MB |
| **RAM disponible para pods** | **~120 MB** | **~1.010 MB** | **~1.170 MB** | **~50 MB** |

> **Nota importante**: los 120 MB de margen de K3s en el nodo Master pueden parecer ajustados. Sin embargo, el nodo Master en esta arquitectura **no está previsto para ejecutar pods de aplicación**: su función es exclusivamente el plano de control y NGINX. Los pods de carga de trabajo se ejecutan en los nodos Worker, donde el agente K3s consume solo ~275 MB, dejando ~1.400 MB libres.

Para el nodo **Worker** (t3.small, 2 GB):

| Componente | K3s (agente) |
|---|---|
| Sistema operativo base | ~300 MB |
| Agente K3s (kubelet + containerd) | ~275 MB |
| kube-proxy | ~50 MB |
| **Disponible para pods de aplicación** | **~1.375 MB** |

---

## 6. Configuración prevista de K3s en el proyecto

### 6.1 Arquitectura del clúster

| Nodo | EC2 | Rol K3s | Función adicional |
|---|---|---|---|
| Master | t3.small (subred pública) | K3s server | NGINX reverse proxy + plano de control |
| Worker | t3.small (subred privada) | K3s agent | Pods de aplicación |
| Worker 2 | t3.small (subred privada) | K3s agent | Pods de aplicación |
| DDBB | t3.small (subred privada) | Sin rol K3s | Motor MariaDB dedicado (fuera del clúster) |

> El nodo DDBB está **fuera del clúster K3s**. MariaDB se despliega directamente sobre EC2, no como pod de Kubernetes. Esta decisión se tomó en el estudio de base de datos por razones de rendimiento (E/S dedicada sin overhead de containerd) y seguridad (aislamiento total mediante Security Groups a nivel de VPC).

### 6.2 Instalación del servidor K3s (nodo Master)

```bash
# Instalar K3s en el nodo Master deshabilitando Traefik (sustituido por ingress-nginx)
# y deshabilitando Klipper LB (no necesario en este entorno)
curl -sfL https://get.k3s.io | sh -s - server   --disable traefik   --disable servicelb   --node-taint "node-role.kubernetes.io/master=true:NoSchedule"
```

El taint `NoSchedule` en el nodo Master garantiza que ningún pod de aplicación se schedule en él, reservando la RAM para el plano de control y NGINX.

### 6.3 Unión de nodos Worker

```bash
# En cada nodo Worker, con el token obtenido del nodo Master
curl -sfL https://get.k3s.io | K3S_URL=https://<MASTER_IP>:6443 K3S_TOKEN=<TOKEN> sh -
```

Este proceso es directamente invocable desde los scripts Python de automatización del proyecto mediante `subprocess` o `paramiko`.

### 6.4 Ajuste de recursos en el nodo Master

Para garantizar estabilidad en el nodo Master con 2 GB de RAM, se aplicará la siguiente configuración de reserva de recursos en `/etc/rancher/k3s/config.yaml`:

```yaml
kubelet-arg:
  - "max-pods=30"
  - "eviction-hard=memory.available<150Mi"
  - "system-reserved=cpu=200m,memory=250Mi"
  - "kube-reserved=cpu=200m,memory=250Mi"
kube-apiserver-arg:
  - "default-watch-cache-size=0"
```

Esta configuración reserva 250 MB para el sistema operativo y 250 MB para los componentes de K3s, activa el proceso de evicción de pods cuando la memoria libre baja de 150 MB y limita el número máximo de pods en el nodo Master a 30 (más que suficiente para los componentes del plano de control y los pods de sistema).

### 6.5 Componentes a desplegar sobre K3s

| Componente | Función | Helm chart / Instalación |
|---|---|---|
| **ingress-nginx** | Ingress Controller (sustituye a Traefik) | Helm chart oficial de ingress-nginx |
| **cert-manager** | Gestión automática de certificados TLS (Let's Encrypt) | Helm chart oficial de Jetstack |
| **ArgoCD** | GitOps, despliegue continuo desde el repositorio | Helm chart oficial de ArgoCD |
| **Prometheus** | Recolección de métricas del clúster y las aplicaciones | kube-prometheus-stack (Helm) |
| **Grafana** | Visualización de métricas y dashboards | Incluido en kube-prometheus-stack |

### 6.6 Justificación de la sustitución de Traefik por ingress-nginx

K3s incluye **Traefik** como Ingress Controller por defecto. En este proyecto se sustituye por **ingress-nginx** por las siguientes razones:

1. **Coherencia tecnológica**: el servidor web de los sitios de los clientes usa Nginx. Usar ingress-nginx como controlador de entrada unifica la tecnología en toda la capa de red del proyecto, lo que simplifica el troubleshooting y el conocimiento necesario del equipo.
2. **Compatibilidad de anotaciones**: las anotaciones de ingress-nginx (`nginx.ingress.kubernetes.io/*`) están mejor documentadas y son más predecibles que las de Traefik para casos de uso de hosting multi-sitio.
3. **Ecosistema más extendido**: ingress-nginx tiene más ejemplos documentados de integración con cert-manager, ModSecurity y configuraciones de hosting multicliente.
4. **Facilidad de configuración mediante plantillas**: las configuraciones de ingress-nginx son generables mediante plantillas Jinja2 desde Python, con la misma sintaxis que las configuraciones de Nginx del servidor web.

La desactivación de Traefik se realiza con el flag `--disable traefik` durante la instalación de K3s, sin ningún coste adicional ni configuración especial.

---

## 7. Decisión final: K3s

**Elegimos K3s como orquestador de contenedores del proyecto.**

### Razones principales de la elección

**1. Es la única distribución compatible con las restricciones reales del entorno.** Amazon EKS no está disponible en cuentas Educate. kubeadm deja menos de 50 MB de margen en el nodo Master. K3s, con la configuración de ajuste de recursos descrita, permite operar el plano de control dentro de los 2 GB disponibles y reservar los Workers para las cargas de trabajo reales.

**2. La instalación en un único comando es una ventaja técnica real, no cosmética.** El proyecto tiene como objetivo explícito la automatización del despliegue. Poder provisionar un nodo K3s completamente funcional con una línea de bash desde un script Python (o desde un pipeline de GitHub Actions) es un requisito que K3s cumple y kubeadm no.

**3. Certificación CNCF garantiza que la inversión en arquitectura es transferible.** Todos los componentes del stack (ingress-nginx, cert-manager, ArgoCD, Prometheus, Grafana, Helm) funcionan sobre K3s sin modificaciones, porque K3s pasa el mismo test suite de conformidad que Kubernetes estándar.

**4. La comunidad más activa de distribuciones ligeras reduce el riesgo técnico del proyecto.** Con >27.000 GitHub stars y millones de instalaciones activas, la probabilidad de encontrar documentación y soluciones a los problemas que surjan durante el desarrollo es significativamente mayor que con MicroK8s o k0s.

**5. El modelo de crecimiento es coherente con la hoja de ruta del proyecto.** En la proyección futura del estudio AWS, se contempla incorporar más Workers, redimensionar instancias y potencialmente migrar a etcd para HA. K3s soporta todas estas evoluciones sin cambiar de orquestador.

### Resumen ejecutivo

| Parámetro | Valor |
|---|---|
| Orquestador | **K3s** (SUSE/Rancher Labs, certificado CNCF) |
| Versión | Canal `stable` (última versión estable) |
| Backend de estado | SQLite embebido (fase actual) → etcd (si HA futura) |
| CNI | Flannel (incluido en K3s) |
| Ingress Controller | **ingress-nginx** (Traefik desactivado con `--disable traefik`) |
| Nodos del clúster | 1 servidor (Master) + 2 agentes (Worker, Worker 2) |
| Nodo DDBB | Fuera del clúster K3s (MariaDB directamente sobre EC2) |
| Alternativas descartadas | kubeadm (recursos), EKS (coste + Educate), MicroK8s (snap), k0s (comunidad menor) |
