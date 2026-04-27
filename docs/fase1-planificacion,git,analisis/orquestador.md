# Elección del orquestador de contenedores: Kubernetes (K8s)

## Introducción

La elección del orquestador de contenedores es la decisión más crítica de este proyecto. Tras analizar las opciones, se ha optado por **Kubernetes nativo (distribuido mediante kubeadm)**. A diferencia de las distribuciones "ligeras" o simplificadas, Kubernetes estándar ofrece el mayor grado de control, transparencia y fidelidad a los estándares de la industria, garantizando que la arquitectura sea 100% portable a cualquier proveedor de nube sin dependencias de terceros (como Rancher o Canonical).

Este documento justifica la elección de **K8s** bajo las restricciones de las cuentas **AWS Educate Starter** (150 USD, región **us-east-1**, instancias **t3.small**), detallando cómo se optimizará el sistema para operar en 2 GB de RAM.

---

## 1. Contexto y restricciones del entorno

### 1.1 Infraestructura disponible
El despliegue se realiza sobre cuatro instancias **t3.small** (2 vCPU, 2 GB RAM):

| Nodo | Subred | Rol K8s | Función principal |
|---|---|---|---|
| Control Plane | Pública | **Master** | API Server, Scheduler, Controller Manager, etcd, NGINX |
| Worker 1 | Privada | **Worker** | Ejecución de Pods de aplicación |
| Worker 2 | Privada | **Worker** | Ejecución de Pods de aplicación |
| DDBB | Privada | **Externo** | Nodo dedicado MariaDB (fuera del clúster) |

### 1.2 El desafío de los 2 GB de RAM
El requisito oficial de Kubernetes para el nodo Master es de 2 GB de RAM. En una instancia **t3.small**, esto deja poco margen. La elección de K8s nativo implica un compromiso con la **optimización extrema del sistema operativo** y la configuración manual de los componentes para asegurar la estabilidad del clúster.

---

## 2. Por qué Kubernetes "Vanilla" (kubeadm) sobre otras opciones

### 2.1 Comparativa Técnica

| Criterio | K8s (kubeadm) | K3s / k0s | MicroK8s |
|---|---|---|---|
| **Estandarización** | **Total (Referencia CNCF)** | Distribución modificada | Dependiente de Snaps |
| **Componentes** | Desacoplados (Pods estáticos) | Binario único (Todo-en-uno) | Servicios de sistema |
| **Backend de estado** | **etcd (Industrial)** | SQLite (por defecto) | Dqlite |
| **Transparencia** | Máxima (Logs individuales) | Opaca (Abstracción del binario) | Media |
| **Curva de aprendizaje** | Alta (Profesional) | Baja (Simplificada) | Media |

### 2.2 Razones del descarte de alternativas
* **K3s/k0s:** Aunque consumen menos recursos, ocultan la complejidad operativa. Para un proyecto de arquitectura, es vital entender el ciclo de vida de cada componente (etcd, scheduler, etc.) de forma independiente.
* **Amazon EKS:** Incompatible con el presupuesto de $150 (coste de $73/mes solo por el plano de control) y no disponible en cuentas Educate.
* **MicroK8s:** El uso de `snaps` en Amazon Linux 2023 genera conflictos de rendimiento y capas de abstracción innecesarias que complican el troubleshooting.

---

## 3. Análisis detallado de Kubernetes (kubeadm)

**kubeadm** es la herramienta estándar de la industria para crear clústeres de Kubernetes que sigan las mejores prácticas de seguridad y configuración.

### 3.1 Arquitectura del Plano de Control
A diferencia de las versiones ligeras, K8s despliega sus componentes como **Pods estáticos**. Esto permite:
1.  **Observabilidad:** Cada componente tiene su propio ciclo de vida y logs independientes en `/var/log/pods`.
2.  **Resiliencia:** Si el API Server falla, el Kubelet lo reinicia automáticamente como un contenedor independiente.
3.  **Seguridad:** Comunicación TLS nativa entre todos los componentes desde el segundo 1 de la instalación.

### 3.2 Gestión de Memoria en t3.small
El plano de control de K8s consume aproximadamente **1.2 GB - 1.5 GB** de RAM en reposo. Para que esto sea viable en una instancia de 2 GB, se aplicarán las siguientes estrategias:
* **Desactivación de Swap:** Obligatorio para K8s, lo que mejora la predictibilidad del rendimiento.
* **Kernel Tuning:** Optimización de parámetros de red y memoria en Amazon Linux 2023.
* **Aislamiento del Master:** El nodo Master tendrá un *taint* para evitar que pods de usuario consuman memoria, reservándola exclusivamente para la gestión del clúster y el Proxy NGINX de entrada.

---

## 4. Implementación y Automatización

La instalación se automatizará mediante scripts en **Python (Paramiko/Subprocess)** para asegurar la reproducibilidad sin errores manuales.

### 4.1 Secuencia de Despliegue
1.  **Pre-requisitos:** Instalación de `containerd` como runtime de contenedores (estándar de la industria).
2.  **Inicialización:** `kubeadm init` con el rango de IPs para la red de Pods.
3.  **Red (CNI):** Instalación de **Calico** o **Cilium**. Se elige Calico por su robustez en el manejo de Network Policies, fundamentales para la seguridad entre la subred pública y privada.
4.  **Join de Workers:** Los nodos esclavos se unen mediante el token generado, configurando el `kubelet` para reportar métricas al Master.

### 4.2 Configuración del Ingress Controller
Se instalará **ingress-nginx** mediante Helm. A diferencia de otras distribuciones que traen Traefik de serie, `ingress-nginx` es el estándar de facto, ofreciendo:
* Mejor integración con certificados de Let's Encrypt (vía cert-manager).
* Soporte nativo para anotaciones complejas de reescritura de URLs.

---

## 5. Viabilidad Económica (AWS Educate)

Utilizar K8s "Vanilla" es la opción más económica a largo plazo dentro de AWS Educate:
* **Coste del Plano de Control:** $0 (autogestionado en EC2).
* **Consumo Estimado:** 4 instancias t3.small encendidas 24/7 cuestan aprox. **$60/mes** en us-east-1.
* **Margen:** Con 150 USD de crédito, el proyecto puede mantenerse operativo durante **2.5 meses**, tiempo suficiente para el desarrollo, pruebas y entrega final.

---

## 6. Decisión Final: Kubernetes Nativo

**Se elige Kubernetes (kubeadm) por ser la opción que mejor prepara el proyecto para un entorno profesional real.**

### Resumen de la Decisión

| Componente | Selección | Justificación |
|---|---|---|
| **Distribución** | **Kubernetes Vanilla (v1.2x)** | Estándar de la CNCF, sin vendor lock-in. |
| **Herramienta** | **kubeadm** | Método oficial y más educativo para la gestión de clústeres. |
| **Runtime** | **containerd** | Sustituto moderno y ligero de Docker. |
| **Network Plugin** | **Calico** | Control granular de tráfico entre capas (Pública/Privada). |
| **Ingress** | **NGINX Ingress** | Coherencia técnica con el stack de los servidores web. |

> **Conclusión:** Aunque K3s es más ligero, **Kubernetes nativo** proporciona una arquitectura más robusta y alineada con los estándares de producción. Mediante la optimización del nodo Master y el uso de nodos dedicados para la base de datos, garantizamos estabilidad técnica y eficiencia de costes dentro de las limitaciones de AWS Educate.