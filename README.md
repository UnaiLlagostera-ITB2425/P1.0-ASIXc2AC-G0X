# P1.0 MEU
### Plataforma SaaS de Hosting Web sobre AWS y Kubernetes

> Proyecto final de ASIXc con perfil de ciberseguridad, centrado en el diseño y despliegue de una plataforma de hosting web segura, automatizada, escalable y bien documentada.

---

## Sobre el proyecto

P1.0 MEU es nuestro proyecto final de ASIXc. La propuesta consiste en construir una plataforma SaaS de hosting web sobre AWS y Kubernetes K3s, pensada para alojar sitios de forma centralizada, mantener el aislamiento entre clientes y facilitar la administración del entorno desde una base técnica ordenada.

Más que presentar servicios sueltos, el objetivo es reunir en un mismo proyecto la infraestructura cloud, la persistencia de datos, la automatización del aprovisionamiento, la seguridad, la observabilidad y la documentación. La idea es que el repositorio sirva tanto como base técnica del sistema como guía clara del trabajo realizado durante el desarrollo.

---

## Qué queremos conseguir

- Diseñar una infraestructura cloud orientada a hosting web multicliente.
- Desplegar una arquitectura segura sobre AWS con red segmentada, control de accesos y servicios bien separados.
- Orquestar el entorno con Kubernetes K3s.
- Centralizar la gestión de datos y la persistencia.
- Automatizar la creación y administración de nuevos servicios.
- Aplicar medidas reales de seguridad, monitorización y copias de respaldo.
- Dejar una documentación clara, útil y fácil de seguir.

---

## Índice

Este README es el punto de entrada al proyecto. Cada fase tiene su propio directorio con la documentación correspondiente. Los links apuntan directamente a cada documento.

### Fase 1 — Planificación, Git y análisis
> Decisiones iniciales, estudio del stack tecnológico, análisis de alternativas y flujo de trabajo con Git.

| Documento | Descripción |
|---|---|
| [analisis_competencia.md](docs/01-planificacion,git,analisis/analisis_competencia.md) | Estudio de plataformas de hosting existentes en el mercado |
| [analisis_orquestador.md](docs/01-planificacion,git,analisis/analisis_orquestador.md) | Comparativa y elección del orquestador de contenedores |
| [analisis_solucion_stack.md](docs/01-planificacion,git,analisis/analisis_solucion_stack.md) | Justificación del stack tecnológico elegido |
| [analisis_topologia_solucion.md](docs/01-planificacion,git,analisis/analisis_topologia_solucion.md) | Diseño de la topología de red y arquitectura general |
| [eleccion_almacenamiento.md](docs/01-planificacion,git,analisis/eleccion_almacenamiento.md) | Decisión sobre la solución de almacenamiento persistente |
| [estudio_aws.md](docs/01-planificacion,git,analisis/estudio_aws.md) | Análisis de servicios AWS utilizados en el proyecto |
| [github_workflow.md](docs/01-planificacion,git,analisis/github_workflow.md) | Flujo de trabajo en Git, ramas y convenciones |
| [justificacion_runtime.md](docs/01-planificacion,git,analisis/justificacion_runtime.md) | Justificación del runtime de contenedores seleccionado |

### Fase 2 — Infraestructura AWS
> Despliegue de la infraestructura cloud: instancias, red, accesos y seguridad perimetral.

| Documento | Descripción |
|---|---|
| [IAM.md](docs/02-infraestructuraaws/IAM.md) | Configuración de usuarios, roles y políticas IAM |
| [infraestructura_aws_instancias.md](docs/02-infraestructuraaws/infraestructura_aws_instancias.md) | Creación y configuración de instancias EC2 y VPC |

### Fase 3 — Configuración del clúster
> Puesta en marcha del clúster Kubernetes K3s, Ingress, TLS y gestión de dominios.

| Documento | Descripción |
|---|---|
| [configuracion_nginx_k8s_tls.md](docs/03-configuracioncluster/configuracion_nginx_k8s_tls.md) | Configuración de Nginx Ingress con TLS y Cert-Manager |
| [configurar-dominio.md](docs/03-configuracioncluster/configurar-dominio.md) | Asociación de dominios al clúster y gestión DNS |

### Fase 4 — Core de datos
> Base de datos MariaDB en clúster, persistencia y administración.

| Documento | Descripción |
|---|---|
| [configuracion_instancia_BD.md](docs/04-coredatos/configuracion_instancia_BD.md) | Configuración de la instancia de base de datos |
| [despliegue_cluster_mariadb.md](docs/04-coredatos/despliegue_cluster_mariadb.md) | Despliegue del clúster MariaDB en Kubernetes |
| [despliegue_phpMyAdmin.md](docs/04-coredatos/despliegue_phpMyAdmin.md) | Despliegue y configuración de phpMyAdmin |
| [levantar_instancia_BD.md](docs/04-coredatos/levantar_instancia_BD.md) | Procedimiento para iniciar la instancia de base de datos |

### Fase 5 — API, automatización y planes
> Backend de la plataforma, lógica de aprovisionamiento y gestión de clientes.

| Documento | Descripción |
|---|---|
| [desarrollo_api.md](docs/05-api,automatizacion,planes/desarrollo_api.md) | Diseño y desarrollo de la API REST del sistema |
| [dockerfile_base.md](docs/05-api,automatizacion,planes/dockerfile_base.md) | Imagen Docker base para los sitios alojados |
| [logica_bbdd.md](docs/05-api,automatizacion,planes/logica_bbdd.md) | Lógica de gestión de bases de datos por cliente |
| [logica_kubectl.md](docs/05-api,automatizacion,planes/logica_kubectl.md) | Automatización de recursos Kubernetes vía API |
| [template_maestro.md](docs/05-api,automatizacion,planes/template_maestro.md) | Template maestro para el aprovisionamiento de nuevos sitios |

### Fase 6 — Frontend
> Paneles de administración, panel de cliente y definición de planes de hosting.

| Documento | Descripción |
|---|---|
| [frontend.md](docs/06-frontend/frontend.md) | Arquitectura del frontend y integración con LDAP |
| [planes_hosting.md](docs/06-frontend/planes_hosting.md) | Definición y configuración de los planes de hosting |

### Fase 7 — Seguridad y pruebas
> Hardening, autenticación centralizada, seguridad de contenedores y QA.

| Documento | Descripción |
|---|---|
| [configuracion_ldap.md](docs/07-seguridad,pruebas/configuracion_ldap.md) | Configuración del servidor LDAP y usuarios admin |
| [configuracion_seguridad_contenedores.md](docs/07-seguridad,pruebas/configuracion_seguridad_contenedores.md) | Hardening y políticas de seguridad en contenedores |
| [contextualizacion_pruebas_qa.md](docs/07-seguridad,pruebas/contextualizacion_pruebas_qa.md) | Planificación y contexto de las pruebas de calidad |
| [securizacion_servicios_web.md](docs/07-seguridad,pruebas/securizacion_servicios_web.md) | Securización de los servicios web expuestos |

### Fase 8 — Observabilidad y logs
> Métricas, dashboards, agregación de logs y alertas.

| Documento | Descripción |
|---|---|
| [despleguar_grafana_prometheus.md](docs/08-observabilidad,Logs/despleguar_grafana_prometheus.md) | Despliegue y configuración de Grafana y Prometheus |
| [despliegue_loki_alloy.md](docs/08-observabilidad,Logs/despliegue_loki_alloy.md) | Despliegue de Loki y Alloy para agregación de logs |

### Fase 10 — Legal y documentación final
> Cumplimiento normativo, sostenibilidad y documentación de cierre del proyecto.

| Documento | Descripción |
|---|---|
| [cumplimiento_rgpd.md](docs/10-legal,documentacion/cumplimiento_rgpd.md) | Análisis de cumplimiento con el RGPD |
| [medioambiente_eco.md](docs/10-legal,documentacion/medioambiente_eco.md) | Impacto medioambiental y criterios de sostenibilidad |
| [riesgos_laborales.md](docs/10-legal,documentacion/riesgos_laborales.md) | Evaluación de riesgos laborales del proyecto |

### Manuales
> Guías de instalación, uso y administración del sistema.

| Documento | Descripción |
|---|---|
| [manual_admin.md](docs/manuales/manual_admin.md) | Manual de administración del sistema |
| [manual_user.md](docs/manuales/manual_user.md) | Manual de uso para el cliente final |

### Sprint Planning y Reviews
> Planificación iterativa y revisiones de cada sprint del proyecto.

| Documento | Descripción |
|---|---|
| [sprint_planning_review.md](docs/sprint-planning_review/sprint_planning_review.md) | Registro de planificaciones y revisiones de sprint |

---

## Tecnologías principales

| Área | Tecnologías |
|---|---|
| Cloud | AWS · VPC · EC2 · S3 · Security Groups |
| Orquestación | Kubernetes K3s · Helm · Nginx Ingress · Cert-Manager |
| Contenedores | Docker |
| Datos | MariaDB · almacenamiento persistente |
| Seguridad | ModSecurity · Fail2Ban · RBAC · Trivy · Sealed Secrets |
| Observabilidad | Prometheus · Grafana · Loki · Alloy · Alertmanager |
| Automatización | API backend · GitHub Actions · ArgoCD |
| Backups | Velero · S3 |

---

## Enfoque del repositorio

La documentación está organizada por fases para que el proyecto se pueda seguir con una lógica clara, desde la planificación inicial hasta la entrega final. Esto permite separar cada bloque de trabajo, mantener el contenido ordenado y navegar el repositorio de forma directa sin necesidad de explorar carpetas manualmente.

El objetivo no es solo que el proyecto funcione, sino que también se entienda: cada decisión técnica está documentada, cada servicio desplegado tiene su guía, y el conjunto refleja un trabajo riguroso tanto en infraestructura como en proceso.
