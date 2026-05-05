# Informe de Riesgos Laborales

## 1. Objetivo y alcance

El presente informe identifica, evalúa y propone medidas preventivas para los riesgos laborales a los que están expuestos los trabajadores (desarrolladores, administradores de sistemas, DevOps, personal de oficina) que participan en el desarrollo y operación de la plataforma de hosting SaaS sobre Kubernetes en AWS. El análisis cubre tanto el trabajo presencial (oficina, sala de servidores) como el teletrabajo, dado el carácter híbrido del equipo.

## 2. Metodología

Se ha utilizado un enfoque mixto: observación directa de las tareas, revisión de la documentación técnica del proyecto, entrevistas informales con los tres miembros del equipo (Unai, Erick, Manuel) y aplicación de la **Ley 31/1995 de Prevención de Riesgos Laborales** (LPRL) y el **RD 486/1997** sobre lugares de trabajo, complementado con la **Guía técnica del INSST** para trabajos con equipos con pantallas de visualización.

## 3. Identificación de riesgos

Se han clasificado los riesgos en cinco categorías:

### 3.1 Riesgos ergonómicos
- **Trabajo con pantallas de visualización (PVD)**: jornadas de más de 6 horas frente al ordenador, posturas forzadas (cuello y espalda), tecleo repetitivo.
- **Diseño inadecuado del puesto de trabajo**: sillas no regulables, mesas sin altura ajustable, falta de reposapiés.
- **Trabajo en teletrabajo**: monitores portátiles de pequeño tamaño, uso de sillas domésticas, iluminación deficiente.

### 3.2 Riesgos psicosociales
- **Carga mental elevada**: resolución de problemas complejos de Kubernetes, redes, DNS, TLS, debugging de YAML y scripts Python.
- **Presión de tiempo**: sprints de dos semanas (convertidos en un único sprint final), fechas límite ajustadas, cancelación del sprint 3 por imprevistos.
- **Multitarea y sobrecarga**: un mismo trabajador asume tareas de infraestructura AWS, despliegue K8s, desarrollo de API y documentación.
- **Aislamiento social** (en teletrabajo): comunicación exclusivamente por Slack/Meet sin contacto presencial.
- **Fatiga por decisión constante**: cada fallo de conectividad, error de certificado o bug de Helm requiere soluciones rápidas y creativas.

### 3.3 Riesgos físicos (entorno de oficina)
- **Posturas inadecuadas**: estar sentado más de 8 horas diarias sin pausas activas.
- **Iluminación insuficiente o deslumbramiento**: pantallas orientadas hacia ventanas o luces directas.
- **Ruido ambiental** (open space): conversaciones, impresoras, timbres.
- **Condiciones térmicas**: oficinas sin control de temperatura adecuado (frío/calor excesivo).

### 3.4 Riesgos eléctricos y de incendio (sala de servidores / laboratorio)
- **Manipulación de equipos de red**: conexión de switches, routers, acceso a instancias EC2 (aunque remoto, en oficina se usan equipos locales).
- **Acumulación de polvo en equipos eléctricos**: posible cortocircuito o sobrecalentamiento.
- **Cables sueltos** en el suelo: riesgo de tropiezo.
- **Falta de extintores** o señalización en la zona de trabajo con equipos eléctricos.
- **Sobrecarga de enchufes** (regletas múltiples).

### 3.5 Riesgos específicos del teletrabajo
- **Falta de evaluación ergonómica del domicilio**: el empleador tiene responsabilidad sobre el lugar de trabajo aunque sea el hogar del trabajador (según LPRL).
- **Aislamiento y dificultad para desconectar** (derecho a la desconexión digital).
- **Ciberseguridad doméstica**: uso de redes Wi-Fi no seguras, falta de VPN, posibilidad de fugas de credenciales AWS.

### 3.6 Riesgos relacionados con herramientas TIC y equipos
- **Exposición a radiaciones electromagnéticas** (bajas, pero con jornadas muy largas).
- **Fatiga visual**: pantallas de baja resolución, reflejos, falta de filtros de luz azul.
- **Estrés tecnológico** por fallos inesperados (p. ej., el problema de conectividad entre instancias que retrasó el Sprint 1).

### 3.7 Riesgos de seguridad y salud en desplazamientos
- **Desplazamientos ocasionales** a oficinas o centros de datos (si los hubiera). En este proyecto no hay centros de datos propios, pero sí posibles reuniones presenciales.

## 4. Evaluación de riesgos

Se ha utilizado una matriz de probabilidad (Baja, Media, Alta) y severidad (Leve, Moderada, Grave). Los riesgos más relevantes son:

| Riesgo | Probabilidad | Severidad | Nivel de riesgo |
|--------|--------------|-----------|----------------|
| Fatiga visual | Alta | Moderada | **Alto** |
| Trastornos musculoesqueléticos (espalda, cuello, muñecas) | Alta | Moderada | **Alto** |
| Estrés/ansiedad por sobrecarga y plazos | Media | Grave | **Alto** |
| Aislamiento social | Media | Moderada | **Medio-Alto** |
| Caídas por cables sueltos | Baja | Grave | Medio |
| Incendio por sobrecarga eléctrica | Baja | Grave | Medio |
| Ciberacoso / fatiga por videoconferencias | Media | Leve | Bajo-Medio |

> Nota: Los riesgos de nivel alto requieren medidas correctoras inmediatas.

## 5. Medidas preventivas

### 5.1 Ergonomía y puesto de trabajo
- **Revisión de sillas y mesas**: proporcionar sillas ergonómicas con apoyo lumbar, altura regulable y reposabrazos. Mesas con altura ajustable o elevadores.
- **Pantallas**: usar monitores de al menos 24", con inclinación y altura ajustable (el borde superior a la altura de los ojos). Evitar reflejos.
- **Teclado y ratón ergonómicos**: preferir teclados separados y ratones verticales. Uso de reposamuñecas.
- **Regla 20-20-20**: cada 20 minutos, mirar a 20 pies (~6 m) durante 20 segundos para descansar la vista.
- **Pausas activas**: realizar micropausas de 5 minutos cada hora (estiramientos, movilidad cervical).

### 5.2 Medidas psicosociales
- **Planificación realista de sprints**: evitar cancelaciones de sprints que concentran trabajo. Aplicar metodología ágil con revisiones de carga.
- **Límite de horas de reunión**: máximo 2 horas diarias de videoconferencia, descansos entre reuniones.
- **Fomentar la desconexión digital**: no enviar mensajes fuera del horario laboral salvo urgencias reales.
- **Soporte psicológico**: ofrecer acceso a servicio de atención psicológica (a través de la mutua).
- **Trabajo colaborativo con pair programming** para reducir la presión individual.

### 5.3 Medidas para teletrabajo
- **Acuerdo escrito de teletrabajo** que incluya la evaluación de riesgos del domicilio.
- **Provisión de equipo adecuado**: monitor externo, silla ergonómica, teclado y ratón (la empresa puede sufragar parte).
- **Recomendaciones de seguridad informática**: uso de VPN corporativa, autenticación MFA, no almacenar credenciales en equipos compartidos.
- **Derecho a la desconexión incluir en el convenio**.

### 5.4 Medidas en la oficina / sala de servidores (si aplica)
- **Gestión de cables**: uso de canaletas, bridas y organización bajo la mesa.
- **Revisión eléctrica**: no sobrepasar la potencia de las regletas; usar regletas con protección de sobretensión.
- **Extintor** de polvo ABC cerca de la zona de equipos eléctricos, revisado anualmente.
- **Señalización** de salidas de emergencia y punto de encuentro.
- **Limpiar periódicamente el polvo** de equipos y ventilaciones.

### 5.5 Formación y concienciación
- **Formación inicial en prevención de riesgos laborales** (genérica y específica para trabajos con pantallas).
- **Charlas periódicas sobre higiene postural y descansos** (cada 3-6 meses).
- **Formación en manejo del estrés** y detección precoz del burnout.
- **Instrucciones sobre uso seguro de AWS y Kubernetes** para evitar accidentes por mala configuración (p. ej., apertura involuntaria de puertos SSH a 0.0.0.0/0).

### 5.6 Vigilancia de la salud
- **Reconocimientos médicos anuales** que incluyan:
  - Examen oftalmológico (agudeza visual, fatiga ocular).
  - Evaluación musculoesquelética (columna, extremidades superiores).
  - Cuestionario de salud mental (ansiedad, depresión, burnout).
- **Protocolo de reincorporación** tras baja prolongada.

## 6. Plan de emergencia y primeros auxilios

- **Botiquín** visible y accesible (tanto en oficina como en domicilios – recomendar un botiquín básico).
- **Números de emergencia** (112, mutua, responsable de prevención) en lugar visible.
- **Simulacro de evacuación** al menos una vez al año si hay espacio físico de oficina.
- **Trabajador designado** para primeros auxilios (al menos uno por turno).

## 7. Responsabilidades y seguimiento

- **Empresa / responsable del proyecto**: debe proveer los medios materiales y organizativos, así como la formación.
- **Trabajadores**: cumplir las medidas preventivas, comunicar cualquier situación de riesgo o accidente.
- **Delegado de prevención** (si existe representación de los trabajadores) se encargará de velar por el cumplimiento.
- **Registro de accidentes e incidentes**: llevar un libro de incidencias donde se anoten casi accidentes (p. ej., golpe con cable, dolor de espalda intenso).

## 8. Conclusiones

El proyecto de desarrollo de una plataforma SaaS sobre Kubernetes en AWS presenta riesgos laborales significativos, sobre todo de tipo ergonómico y psicosocial debido a la alta carga mental y las largas jornadas frente a pantallas. La cancelación del Sprint 3 y la concentración del trabajo en dos sprints agravan la presión temporal. Se recomienda implementar las medidas preventivas descritas y realizar un seguimiento trimestral de la efectividad de las mismas. La empresa tiene la obligación legal y ética de proteger la salud de sus trabajadores, tanto en modalidad presencial como en teletrabajo.