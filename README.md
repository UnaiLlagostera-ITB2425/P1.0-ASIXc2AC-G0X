# P1.0 MEU
### Plataforma SaaS de Hosting Web sobre AWS y Kubernetes

> Proyecto final de ASIXc con perfil de ciberseguridad, centrado en el diseño y despliegue de una plataforma de hosting web segura, automatizada, escalable y bien documentada.

---

## Sobre el proyecto

P1.0 MEU es nuestro proyecto final de ASIXc. La propuesta consiste en construir una plataforma SaaS de hosting web sobre AWS y Kubernetes K3s, pensada para alojar sitios de forma centralizada, mantener el aislamiento entre clientes y facilitar la administración del entorno desde una base técnica ordenada.

Más que presentar servicios sueltos, el objetivo es reunir en un mismo proyecto la infraestructura cloud, la persistencia de datos, la automatización del aprovisionamiento, la seguridad, la observabilidad y la documentación. La idea es que el repositorio sirva tanto como base técnica del sistema como guía clara del trabajo realizado durante el desarrollo.

## Qué queremos conseguir

- Diseñar una infraestructura cloud orientada a hosting web multicliente.
- Desplegar una arquitectura segura sobre AWS con red segmentada, control de accesos y servicios bien separados.
- Orquestar el entorno con Kubernetes K3s.
- Centralizar la gestión de datos y la persistencia.
- Automatizar la creación y administración de nuevos servicios.
- Aplicar medidas reales de seguridad, monitorización y copias de respaldo.
- Dejar una documentación clara, útil y fácil de seguir.

## Indice

Este README está planteado como punto de entrada al proyecto. A medida que se complete la documentación de cada fase, los siguientes apartados servirán como índice navegable del repositorio.

| Bloque | Ruta prevista | Contenido |
|---|---|---|
| Fase 1 | [`docs/fase1-planificacion,git,analisis/index.md`](docs/fase1-planificacion,git,analisis/index.md) | Planificación, análisis inicial, Git y decisiones base |
| Fase 2 | [`docs/fase2-infraestructuraaws/index.md`](docs/fase2-infraestructuraaws/index.md) | Infraestructura en AWS, red, acceso y seguridad |
| Fase 3 | [`docs/fase3-configuracioncluster/index.md`](docs/fase3-configuracioncluster/index.md) | Configuración del clúster Kubernetes y servicios base |
| Fase 4 | [`docs/fase4-coredatos/index.md`](docs/fase4-coredatos/index.md) | Core de datos, persistencia y base de datos |
| Fase 5 | [`docs/fase5-api,automatizacion,planes/index.md`](docs/fase5-api,automatizacion,planes/index.md) | API, automatización y gestión de planes |
| Fase 6 | [`docs/fase6-frontend/index.md`](docs/fase6-frontend/index.md) | Paneles de administración y cliente |
| Fase 7 | [`docs/fase7-seguridad,pruebas/index.md`](docs/fase7-seguridad,pruebas/index.md) | Seguridad, hardening y pruebas |
| Fase 8 | [`docs/fase8-observabilidad,logs/index.md`](docs/fase8-observabilidad,logs/index.md) | Observabilidad, métricas, logs y alertas |
| Fase 9 | [`docs/fase9-backups/index.md`](docs/fase9-backups/index.md) | Backups y recuperación |
| Fase 10 | [`docs/fase10-gitops,ci,cd/index.md`](docs/fase10-gitops,ci,cd/index.md) | GitOps, integración y despliegue continuo |
| Fase 11 | [`docs/fase11-legal,documentacion/index.md`](docs/fase11-legal,documentacion/index.md) | Documentación final, RGPD y presentación |
| Manuales | [`docs/manuales/`](docs/manuales/) | Guías de instalación, uso y administración |

## Tecnologías principales

| Área | Tecnologías |
|---|---|
| Cloud | AWS, VPC, EC2, S3, Security Groups |
| Orquestación | Kubernetes K3s, Helm, Nginx Ingress, Cert-Manager |
| Contenedores | Docker |
| Datos | MariaDB y almacenamiento persistente |
| Seguridad | ModSecurity, Fail2Ban, RBAC, Trivy, Sealed Secrets |
| Observabilidad | Prometheus, Grafana, Loki o ELK, Alertmanager |
| Automatización | API backend, GitHub Actions, ArgoCD |
| Backups | Velero y almacenamiento en S3 |

## Enfoque del repositorio

La documentación está organizada por fases para que el proyecto se pueda seguir con una lógica clara, desde la planificación inicial hasta la entrega final. Esto nos permite separar cada bloque de trabajo, mantener mejor el contenido y preparar un índice real que facilite la navegación cuando todos los documentos estén terminados.

El objetivo no es solo que el proyecto funcione, sino que también se entienda. Por eso el repositorio está planteado como una base técnica ordenada, pensada para consultar decisiones, revisar configuraciones y seguir la evolución completa del trabajo.

## Agradecimiento

Al inicio del proyecto contamos con la ayuda de **Erik Garcia**, cuya participación fue importante para dar forma a las primeras ideas y orientar el planteamiento inicial. Más adelante tuvo que dejar el proyecto al incorporarse a sus prácticas, pero su aportación en esa primera etapa merece quedar reconocida aquí.