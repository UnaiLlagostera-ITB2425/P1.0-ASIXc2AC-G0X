# Cumplimiento RGPD

> ⚠️ **Nota:** Esta fase recoge las **propuestas técnicas** del equipo para cumplir con el RGPD. Por restricciones de tiempo no han sido implementadas en el alcance actual del proyecto, pero quedan documentadas como hoja de ruta para una versión futura del SaaS.

---

## Contexto y justificación

El Reglamento General de Protección de Datos (RGPD) obliga a cualquier servicio que procese datos de ciudadanos de la UE a garantizar la confidencialidad e integridad de esos datos. Para este SaaS hemos identificado dos obligaciones concretas que habría que cubrir antes de una puesta en producción real:

1. **Cifrado de datos en reposo** — Los datos almacenados en disco deben estar cifrados con AES-256.
2. **Consentimiento de cookies** — Cualquier web de cliente que use cookies debe mostrar un banner de consentimiento antes de activarlas.

El incumplimiento puede suponer multas de hasta el 4% de la facturación anual global o 20 millones de euros.

---

## Propuesta 1 — Cifrado AES-256 en reposo

### ¿Qué es AES-256?

AES-256 (Advanced Encryption Standard con clave de 256 bits) es el estándar de cifrado simétrico más extendido para proteger datos en reposo. AWS lo implementa de forma completamente transparente: los datos se cifran antes de escribirse en disco y se descifran automáticamente al leerse, sin que la aplicación tenga que modificar nada en su código.

### Por qué es necesario en este proyecto

En una plataforma SaaS multitenant, los datos de todos los clientes conviven en la misma infraestructura física. Si alguien accediera a un volumen de disco sin pasar por el sistema operativo — por ejemplo, a través de un snapshot filtrado o un acceso no autorizado a AWS — podría leer los datos en texto plano sin cifrado. El cifrado AES-256 hace que esos datos sean completamente ilegibles sin la clave de descifrado correspondiente.

### Qué habría que cifrar

| Recurso | Justificación |
|---------|--------------|
| Volúmenes EBS de `k8s-master`, `k8s-submaster` y `worker1` | Son los discos donde vive el sistema operativo, los datos de Kubernetes, la base de datos MariaDB y los ficheros de los clientes |
| Snapshots de EBS | Los backups del disco heredarían el cifrado del volumen origen automáticamente |
| Buckets S3 (si se usan para ficheros de cliente) | Cualquier archivo subido por los clientes quedaría protegido en reposo |

### Cómo se podría implementar

AWS ofrece cifrado nativo en EBS y S3 a través de su servicio KMS (Key Management Service). La activación sería una configuración a nivel de cuenta AWS, sin cambios en el código ni en la arquitectura del clúster. Para los volúmenes existentes habría que hacer una migración, ya que AWS no cifra retroactivamente los volúmenes ya creados.

---

## Propuesta 2 — Banner de cookies

### Base legal

El RGPD y la Directiva ePrivacy (conocida como Ley de Cookies) exigen que las cookies no esenciales no se activen hasta obtener el consentimiento explícito del usuario. El banner debe cumplir unos requisitos mínimos:

- Las cookies no pueden cargarse antes de que el usuario decida.
- El rechazo debe ser igual de fácil que la aceptación.
- No puede haber opciones pre-marcadas.
- El consentimiento debe quedar registrado.

### Por qué hay que implementarlo en la imagen base

Dado que el SaaS despliega webs para múltiples clientes, la forma más eficiente y coherente de garantizar el cumplimiento es incluir el mecanismo de consentimiento directamente en la imagen Docker base `saas-php:8.3`. Así, cualquier cliente que se despliegue en la plataforma hereda automáticamente el banner sin necesidad de configuración adicional.

### Tipos de cookies

| Tipo | ¿Requiere consentimiento? |
|------|--------------------------|
| Estrictamente necesarias (sesión, CSRF) | ❌ No |
| Funcionales (preferencias de idioma) | ✅ Sí |
| Analíticas (Google Analytics) | ✅ Sí |
| Marketing (Facebook Pixel, remarketing) | ✅ Sí |

### Cómo se podría implementar

La solución propuesta es un script JavaScript ligero que se incluiría en la imagen base. Este script verificaría si el usuario ya ha dado su consentimiento en visitas anteriores (almacenado en `localStorage`), y en caso negativo mostraría el banner. Solo si el usuario acepta se cargarían los scripts de terceros como analíticas o marketing. Si rechaza, no se cargaría nada.

El consentimiento quedaría registrado con un campo de versión, lo que permitiría invalidar decisiones anteriores si la política de cookies cambiase en el futuro.

### Página de Política de Cookies

Además del banner, el RGPD exige una página accesible que detalle qué cookies se usan, para qué sirven, quién las gestiona y cómo revocar el consentimiento. Esta página debería existir en cada instalación de cliente y estar enlazada desde el propio banner.

---

## Diagrama de flujo del consentimiento

```text
Usuario entra en acme.meu-project.me
   ↓
¿Existe consentimiento previo guardado?
   ├── No → mostrar banner
   │         ├── Acepta → registrar consentimiento + cargar analytics
   │         └── Rechaza → registrar rechazo (no cargar nada)
   └── Sí
         ├── Aceptó → cargar analytics directamente (sin banner)
         └── Rechazó → no cargar nada (sin banner)
```

---

## Por qué estas dos propuestas cubren el RGPD

El RGPD no exige una implementación técnica concreta, sino que los datos estén protegidos y que el consentimiento se gestione correctamente. Con estas dos medidas:

- **El cifrado AES-256** garantiza que los datos en reposo son ilegibles para cualquiera que no tenga la clave, cumpliendo el artículo 32 del RGPD sobre seguridad del tratamiento.
- **El banner de cookies** garantiza que no se procesan datos de navegación sin consentimiento previo, cumpliendo el artículo 7 sobre condiciones del consentimiento.

Juntas cubren los dos vectores de riesgo más críticos de este SaaS desde el punto de vista regulatorio.