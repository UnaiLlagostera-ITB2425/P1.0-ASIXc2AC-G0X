# Elección de Almacenamiento
## Introducción y Objetivo
Los contenedores en Kubernetes son efímeros, es decir, si un contenedor se reinicia pierde todos sus datos. Para evitarlo, se usa almacenamiento persistente: un espacio de almacenamiento externo al contenedor que sobrevive a reinicios y fallos.

El objetivo de esta sección es evaluar y seleccionar la solución de persistencia más adecuada para nuestro clúster Kubernetes, considerando rendimiento, disponibilidad, coste y portabilidad.

Se han evaluado tres soluciones: AWS EBS, NFS Local y Longhorn.

## Conceptos previos
Antes de entrar en las soluciones, es útil conocer dos términos clave de Kubernetes:
- **PV (Persistent Volume):** El "disco" que se reserva en el clúster para guardar datos.
- **PVC (Persistent Volume Claim):** La "solicitud" que hace una aplicación para usar ese disco.
- **Modos de acceso:**
    - **RWO** — Solo un nodo puede leer y escribir a la vez.
    - **RWX** — Varios nodos pueden leer y escribir al mismo tiempo.

## Soluciones Evaluadas
- **AWS EBS (Elastic Block Store):** Disco virtual gestionado por Amazon. Funciona como un pendrive que se conecta a un servidor en la nube de AWS.
  | Puntos fuertes       | Puntos débiles              |
  | -------------------- | --------------------------- |
  | Fácil de usar en AWS | Solo funciona en AWS        |
  | Alto rendimiento     | Solo un nodo a la vez (RWO) |
  | Backups automáticos  | Coste elevado               |
  - **Conclusión:** Muy bueno si usas AWS, pero nos ata a ese proveedor.

- **NFS Local (Network File System):** Servidor de archivos compartido en red. Funciona como una carpeta compartida a la que todos los nodos del clúster pueden acceder a la vez.
  | Puntos fuertes                           | Puntos débiles                      |
  | ---------------------------------------- | ----------------------------------- |
  | Acceso desde varios nodos a la vez (RWX) | Si el servidor cae, todo falla      |
  | Compatible con cualquier entorno         | Bajo rendimiento en cargas intensas |
  | Muy barato y fácil de montar             | Sin alta disponibilidad nativa      |
  - **Conclusión:** Ideal para compartir archivos entre contenedores, no para bases de datos.

- **Longhorn:** Solución de almacenamiento distribuido diseñada específicamente para Kubernetes. Reparte y replica los datos automáticamente entre los nodos del clúster.
  | Puntos fuertes                      | Puntos débiles                |
  | ----------------------------------- | ----------------------------- |
  | Gratuito y open source              | Necesita mínimo 3 nodos       |
  | Alta disponibilidad automática      | Consume más red en escrituras |
  | Panel web visual integrado          | Más complejo que NFS          |
  | Backups automáticos a S3            | —                             |
  | Sin dependencia de ningún proveedor | —                             |
  - **Conclusión:** La opción más completa y alineada con nuestro proyecto.