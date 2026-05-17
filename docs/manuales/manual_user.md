# Manual de Usuario — Plataforma MEU
### Guía para clientes del servicio de hosting gestionado
 
> **Versión:** 1.0 — Mayo 2026
> **Plataforma:** [meu-project.me](https://meu-project.me)
> **Soporte técnico:** soporte@meu-project.me
> **Contacto y contratación:** gestion@meu-project.me
 
---
 
## Índice
 
1. [Bienvenida a MEU](#1--bienvenida-a-meu)
2. [Planes de hosting disponibles](#2--planes-de-hosting-disponibles)
3. [Cómo contratar el servicio](#3--cómo-contratar-el-servicio)
4. [Cómo funciona el servicio](#4--cómo-funciona-el-servicio)
5. [Tu sitio web](#5--tu-sitio-web)
6. [Tu base de datos](#6--tu-base-de-datos)
7. [Dominio y certificado de seguridad](#7--dominio-y-certificado-de-seguridad)
8. [Seguridad de tu cuenta](#8--seguridad-de-tu-cuenta)
9. [Soporte y contacto](#9--soporte-y-contacto)
10. [Preguntas frecuentes](#10--preguntas-frecuentes)
11. [Glosario](#11--glosario)
---
 
## 1 — Bienvenida a MEU
 
**MEU** es una plataforma de hosting web gestionado. Está pensada para que puedas tener tu sitio web en línea de forma segura y fiable, sin necesidad de gestionar servidores ni configuraciones técnicas. El equipo de administración se encarga de toda la infraestructura y atiende tus peticiones de forma directa.
 
### Por qué MEU es una plataforma fiable
 
- **Infraestructura cloud profesional sobre AWS:** Tu sitio se aloja sobre Amazon Web Services, la misma infraestructura que usan empresas de referencia a nivel mundial.
- **Alta disponibilidad:** El sistema está diseñado para mantenerse en línea aunque falle algún componente.
- **Aislamiento total entre clientes:** Tu sitio y tus datos están completamente separados de los de otros clientes en todo momento.
- **HTTPS automático y gratuito:** Tu sitio tiene conexión cifrada desde el primer día, sin coste adicional.
- **Monitorización continua:** El equipo técnico supervisa la plataforma con herramientas de observabilidad en tiempo real. Las incidencias se detectan y se atienden de forma proactiva.
---
 
## 2 — Planes de hosting disponibles
 
MEU ofrece tres planes con diferentes niveles de recursos computacionales asignados a tu sitio:
 
| Característica | **Basic** | **Pro** | **Enterprise** |
|---|---|---|---|
| Recursos del sitio | Básicos | Intermedios | Altos |
| Base de datos MariaDB | ✓ incluida | ✓ incluida | ✓ incluida |
| Dominio personalizado | ✓ | ✓ | ✓ |
| Certificado HTTPS | ✓ automático | ✓ automático | ✓ automático |
| Soporte | Correo (48 h) | Correo (24 h) | Correo prioritario (8 h) |
 
> Los tres planes incluyen aprovisionamiento automático del sitio, base de datos y HTTPS desde el momento del alta.
 
Para consultar qué plan encaja mejor con tu proyecto, contacta con nosotros en **gestion@meu-project.me** o usa el formulario de contacto en la página principal.
 
---
 
## 3 — Cómo contratar el servicio
 
El alta en la plataforma la gestiona el equipo de administración.
 
**Para solicitar el alta:**
 
1. Envía un correo a **gestion@meu-project.me** con el asunto `Alta de servicio`, o usa el formulario de contacto en **meu-project.me**.
2. Indica:
   - Tu nombre o nombre de empresa.
   - El plan que te interesa (Basic, Pro o Enterprise).
   - El dominio que quieres usar, si ya tienes uno.
   - Una breve descripción del tipo de sitio que quieres alojar.
Una vez recibida la solicitud, el equipo preparará tu espacio y te enviará un **correo de confirmación** con los datos de acceso a tu base de datos y la información de tu servicio. El alta suele completarse en menos de **24 horas laborables**.
 
---
 
## 4 — Cómo funciona el servicio
 
MEU es un servicio **totalmente gestionado**. El equipo de administración se encarga de desplegar y mantener todo lo necesario para que tu sitio funcione: el servidor web, la base de datos, el dominio y el certificado HTTPS.
 
Para cualquier cambio en tu sitio (publicar contenido, modificar la base de datos, configurar el dominio), te pones en contacto con el equipo de soporte y ellos lo gestionan. Este modelo garantiza que la plataforma se mantiene segura y estable en todo momento.
 
### Qué gestiona el equipo por ti
 
| Acción | Cómo solicitarlo |
|---|---|
| Publicar o actualizar el contenido de tu sitio | Envía los archivos a soporte@meu-project.me |
| Modificar o importar datos en la base de datos | Escribe a soporte@meu-project.me con el archivo `.sql` o descripción del cambio |
| Configurar un dominio propio | Escribe a soporte@meu-project.me con el dominio |
| Cambiar de plan | Escribe a gestion@meu-project.me |
| Dar de baja el servicio | Escribe a gestion@meu-project.me — recibirás una copia de tus datos antes del cierre |
 
---
 
## 5 — Tu sitio web
 
Tu sitio web se sirve desde un espacio dedicado y aislado dentro de la infraestructura MEU. El contenido que publiques (HTML, CSS, imágenes, etc.) es gestionado por el equipo de administración bajo petición.
 
**Para publicar o actualizar tu sitio:**
 
1. Prepara los archivos de tu sitio web.
2. Envíalos a **soporte@meu-project.me** con el asunto `Actualización de contenido`. Puedes adjuntarlos directamente o compartir un enlace de descarga (WeTransfer, Google Drive, etc.).
3. Indica si quieres reemplazar todo el contenido o solo algunos archivos.
4. El equipo publicará los cambios y te confirmará cuando estén activos.
---
 
## 6 — Tu base de datos
 
Al dar de alta tu servicio, se crea automáticamente una base de datos MariaDB asociada a tu sitio. Puedes gestionarla a través de **phpMyAdmin**, una herramienta web que permite trabajar con bases de datos sin necesidad de conocimientos técnicos avanzados.
 
### Acceder a phpMyAdmin
 
Acceso directo: **https://meu-project.me/phpmyadmin**
 
Introduce el usuario y contraseña de tu base de datos. Los encontrarás en el correo de confirmación que te envió el equipo al darte de alta.
 
> Solo verás tu propia base de datos. No tienes acceso a los datos de otros clientes.
 
### Operaciones habituales en phpMyAdmin
 
**Importar datos desde un archivo `.sql`:**
1. Selecciona tu base de datos en el panel izquierdo.
2. Pestaña **Importar** → selecciona el archivo → **Continuar**.
**Exportar una copia manual de tu base de datos:**
1. Selecciona tu base de datos.
2. Pestaña **Exportar** → formato SQL → **Continuar**.
3. Se descarga el archivo en tu ordenador.
> Recomendamos exportar tu base de datos periódicamente y guardar una copia local, especialmente antes de hacer cambios importantes.
 
### Si necesitas ayuda con la base de datos
 
Para importaciones, cambios de estructura u otras operaciones más complejas, escribe a **soporte@meu-project.me** y el equipo te ayuda.
 
---
 
## 7 — Dominio y certificado de seguridad
 
### Usar un dominio propio
 
Si tienes un dominio registrado (en GoDaddy, Namecheap, etc.), el equipo puede configurarlo para que apunte a tu sitio en MEU:
 
1. Escribe a **soporte@meu-project.me** con el asunto `Configuración de dominio propio` e indica el dominio.
2. El equipo te facilitará los datos DNS que debes aplicar en el panel de tu registrador y completará el resto de la configuración.
La propagación DNS puede tardar entre 15 minutos y 48 horas.
 
### Certificado HTTPS automático
 
Una vez configurado el dominio, la plataforma genera, instala y renueva automáticamente el certificado de seguridad HTTPS. Sin coste adicional y sin ninguna acción por tu parte.
 
- Tu sitio estará disponible en `https://tudominio.com` en cuanto el dominio apunte correctamente.
- El certificado se renueva solo, no caducará sin aviso.
- Las visitas por HTTP se redirigen automáticamente a HTTPS.
Puedes verificar que HTTPS está activo buscando el candado 🔒 en la barra de direcciones. Si aparece algún aviso de seguridad, contacta con soporte.
 
---
 
## 8 — Seguridad de tu cuenta
 
Las credenciales de acceso a phpMyAdmin son personales. Recomendamos:
 
- No reutilizar la contraseña en otros servicios.
- No compartir las credenciales. Si otra persona necesita acceso, comunícalo al equipo.
- El equipo de MEU nunca te pedirá tu contraseña por correo electrónico.
Si crees que tus credenciales han sido comprometidas, escribe inmediatamente a **soporte@meu-project.me** con el asunto `Incidencia de seguridad`.
 
---
 
## 9 — Soporte y contacto
 
| Canal | Para qué | Tiempo de respuesta |
|---|---|---|
| **soporte@meu-project.me** | Incidencias técnicas, publicación de contenido, base de datos, dominio | Según plan (8–48 h) |
| **gestion@meu-project.me** | Contratación, cambios de plan, bajas, consultas generales | 24 h laborables |
| **Formulario web** | meu-project.me → Contacto | Igual que correo |
 
### Cómo reportar una incidencia eficazmente
 
Incluye siempre en tu correo:
 
1. El nombre de tu sitio o tu nombre de usuario.
2. Qué ha ocurrido y qué intentabas hacer.
3. Cuándo empezó el problema.
4. Capturas de pantalla si hay algún mensaje de error visible.
### Incidencias urgentes
 
Si tu sitio está completamente caído y afecta a tu actividad, añade **[URGENTE]** al asunto. El equipo monitoriza la plataforma de forma continua, pero la etiqueta prioriza la comunicación directa contigo.
 
---
 
## 10 — Preguntas frecuentes
 
**¿Puedo gestionar yo mismo los archivos de mi sitio?**
De momento las gestiones de contenido se realizan a través del equipo de administración. Envía tus archivos a soporte y ellos los publican.
 
**¿Puedo ver o editar mi base de datos directamente?**
Sí, a través de phpMyAdmin en **https://meu-project.me/phpmyadmin** con las credenciales que recibiste al darte de alta.
 
**¿Hay copias de seguridad automáticas?**
Actualmente no están implementadas. Te recomendamos exportar tu base de datos periódicamente desde phpMyAdmin como precaución.
 
**¿Hay tiempo de inactividad programado?**
Las actualizaciones de la plataforma se aplican sin interrumpir el servicio. En casos excepcionales que requieran tiempo de inactividad, el equipo avisará con al menos 24 horas de antelación.
 
**¿Qué pasa si mi dominio caduca?**
La renovación del dominio en tu registrador es tu responsabilidad. Si caduca, tu sitio dejará de ser accesible. Activa la renovación automática en tu registrador para evitarlo. El certificado HTTPS lo gestiona la plataforma automáticamente.
 
**¿Puedo cancelar en cualquier momento?**
Sí. Escribe a **gestion@meu-project.me** y el equipo te entregará una copia de tus datos antes de cerrar el servicio.
 
**¿La plataforma cumple con el RGPD?**
Sí. MEU tiene implementadas las medidas técnicas y organizativas necesarias: cifrado de comunicaciones, control de accesos y política de retención de datos.
 
---
 
## 11 — Glosario
 
| Término | Definición |
|---|---|
| **HTTPS** | Conexión cifrada entre el navegador y tu sitio. El candado 🔒 indica que está activo. |
| **Dominio** | La dirección de tu sitio web, por ejemplo `misitioweb.com`. |
| **DNS** | Sistema que traduce el nombre de tu dominio en la dirección del servidor. |
| **Base de datos** | Sistema donde se almacena la información estructurada de tu sitio. |
| **phpMyAdmin** | Herramienta web para gestionar tu base de datos sin comandos técnicos. |
| **Backup** | Copia de seguridad de tus archivos y base de datos. |
| **HTTPS / TLS** | El componente que hace posible la conexión cifrada. Se genera y renueva automáticamente. |
| **Servicio gestionado** | Modelo en el que el proveedor gestiona toda la infraestructura. El cliente interactúa con el servicio, no con el servidor. |
| **AWS** | Amazon Web Services. Infraestructura cloud profesional sobre la que se aloja la plataforma MEU. |
 
---
