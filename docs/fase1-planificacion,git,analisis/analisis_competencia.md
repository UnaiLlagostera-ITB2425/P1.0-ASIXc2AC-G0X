# Análisis de Competencia
## Introducción y Objetivo
El siguiente análisis identifica y compara las principales plataformas de hosting web, con el fin de establecer un marco de referencia funcional para el diseño de nuestra propia plataforma.

## Segmentos Evaluados
Para este análisis se han evaluado proveedores de tres segmentos: hosting compartido, hosting gestionado y cloud IaaS.
- **Hosting compartido/estándar:** Recursos compartidos entre clientes. Orientado a pequeñas empresas o sitios de bajo tráfico.
- **Hosting gestionado:** El proveedor gestiona infraestructura, seguridad y optimización. Orientado a empresas medianas/grandes.
- **Cloud / IaaS para desarrolladores:** Alta personalización, el cliente gestiona la configuración. Orientado a equipos técnicos.

## Proveedores Analizados
- **Hostinger**
  - Categoría: Hosting compartido / Planes business.
  - Sede: Lituania.
  - Presencia global: +178 países.
  - Descripción: Uno de los proveedores más populares a nivel mundial por su relación calidad-precio. Ofrece desde planes básicos hasta VPS y cloud hosting.
    | Puntos fuertes                             | Puntos debiles                                 |
    | ------------------------------------------ | ---------------------------------------------- |
    | Precio competitivo (Desde ~2,99 €/mes)     | Sin Kubernetes ni orquestación                 |
    | Interfaz intuitiva                         | Staging limitado (copia exacta y privada de tu sitio web real, utilizada como entorno de pruebas seguro)  |
    | Buen rendimiento para el segmento          | No apto para entornos críticos (NO permite fallos)  |

- **IONOS (1&1)**
  - Categoría: Hosting compartido / VPS / Cloud.
  - Sede: Alemania.
  - Presencia global: Europa y Norteamérica.
  - Descripción: Proveedor europeo de referencia con amplia gama de productos, desde hosting básico hasta servidores dedicados y cloud privado.
    | Puntos fuertes                             | Puntos debiles                                                                    |
    | ------------------------------------------ | --------------------------------------------------------------------------------- |
    | Fuerte presencia en España y Europa        | Panel menos moderno                                                               |
    | Buena atención telefónica                  | Opciones DevOps limitadas en planes básicos                                       |
    | Infraestructura propia                     | Precios de renovación (Terminado el periodo promocional suben bastante lo costos) |

- **SiteGround**
  - Categoría: Hosting gestionado (WordPress/PHP). 
  - Sede: Bulgaria. 
  - Presencia global: Datacenters en USA, Europa, Asia y Australia.
  - Descripción: Referente en hosting gestionado para WordPress. Conocido por su rendimiento y seguridad proactiva.
    | Puntos fuertes                                   | Puntos debiles                                            |
    | ------------------------------------------------ | --------------------------------------------------------- |
    | Excelente seguridad proactiva                    | Almacenamiento limitado en planes básicos                 |
    | Staging nativo                                   | renovaciones caras                                        |
    | CDN enterprise incluido (Content Delivery Network, es una red global de servidores distribuida geográficamente que acelera la entrega de sitios web, aplicaciones y contenido multimedia al acercarlo a los usuarios) | Dependencia de Google Cloud (Aporta velocidad, pero depende de un tercero) |

- **Kinsta**
  - Categoría: Hosting gestionado enterprise (WordPress)
  - Sede: EE.UU. (con infraestructura en GCP)
  - Presencia global: 37 datacenters (Google Cloud Platform)
  - Descripción: Plataforma premium de hosting gestionado construida sobre Google Cloud. Referente del mercado enterprise WordPress.
    | Puntos fuertes                  | Puntos debiles                        |
    | ------------------------------- | ------------------------------------- |
    | Infraestructura GCP             | Precio elevado                        |
    | APM nativo                      | Orientado exclusivamente a WordPress  |
    | CDN enterprise                  | Precios elevados (Desde ~35 €/mes)    |
    | Entornos staging avanzados      | Límites en los recursos               |

## Conclusiones del Análisis
- **Estándar mínimo del mercado:** SSL automático, backups diarios, CDN, firewall y soporte 24/7 son características universales.
- **Diferenciación enterprise:** El escalado automático, staging nativo, APM y API completa marcan la línea entre plataformas básicas y enterprise.
- **Kubernetes y IaC** solo están presentes de forma nativa en plataformas cloud puras (DigitalOcean, AWS), no en hostings gestionados tradicionales — esto representa la principal oportunidad de diferenciación de nuestra plataforma.
- **Referencia más cercana al proyecto:** DigitalOcean, por su soporte nativo de Kubernetes, Terraform y API completa.
- **Seguridad por diseño:** El aislamiento de entornos por contenedor (presente en Kinsta y WP Engine) es una práctica clave a implementar desde el inicio.
