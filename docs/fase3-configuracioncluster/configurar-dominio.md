# Configuración del dominio `meu-project.me`

## 1. Objetivo

El objetivo de esta configuración es hacer que el dominio público `meu-project.me` apunte a la infraestructura del proyecto para que el tráfico web entre directamente por el **master de Kubernetes**, identificado por la IP elástica `52.91.73.172`. Esta solución permite centralizar la entrada de tráfico en un único punto, simplificar la gestión del acceso web y preparar la plataforma para su posterior distribución interna mediante Ingress y los servicios de Kubernetes.

## 2. Resumen de la arquitectura

La arquitectura DNS implementada es sencilla y funcional. El dominio se ha registrado en **Namecheap** y se ha configurado para resolver hacia la **Elastic IP** asociada al nodo master de AWS. A nivel operativo, esto significa que cuando un usuario escribe `meu-project.me` o `www.meu-project.me`, el proveedor DNS devuelve la IP pública fija `52.91.73.172`, que es la puerta de entrada del clúster.

El uso de una **Elastic IP** es una decisión importante porque evita depender de una dirección pública cambiante. En entornos cloud, una IP pública normal puede modificarse si la instancia se detiene o se recrea, mientras que una Elastic IP permanece estable y mantiene el dominio siempre apuntando al mismo destino.

## 3. Justificación de la solución

Esta configuración se ha elegido por varios motivos técnicos y operativos:

- Proporciona un dominio propio, más profesional y fácil de recordar.
- Permite separar claramente la capa pública de acceso de la capa interna del clúster.
- Facilita pruebas, demostraciones y despliegues posteriores sin necesidad de cambiar la URL.
- Reduce errores derivados de utilizar una IP temporal.
- Encaja mejor con una arquitectura Kubernetes, donde el master actúa como punto de entrada y el tráfico se distribuye después mediante Ingress.

Para un proyecto de hosting web sobre Kubernetes, esta solución es especialmente adecuada porque da una imagen de servicio real y estable, sin complicar en exceso la fase inicial.

## 4. Proveedor y gestión DNS

El dominio se gestiona en **Namecheap**, que actúa como registrador y panel DNS del proyecto. Aunque el dominio se haya obtenido o activado desde una promoción asociada a GitHub Student, la administración real del DNS se realiza en el panel de Namecheap.

La configuración se ha hecho directamente en la zona DNS del dominio, no mediante una redirección web. Esta diferencia es importante:

- **Redirección**: envía al usuario a otra URL.
- **Registro DNS tipo A**: resuelve el dominio hacia una dirección IP concreta.

En este proyecto se ha usado la segunda opción, que es la correcta para apuntar el dominio a un servidor propio.

## 5. Registros configurados

La configuración DNS aplicada es la siguiente:

| Tipo | Host | Valor |
|---|---|---|
| A | `@` | `52.91.73.172` |
| A | `www` | `52.91.73.172` |

El host `@` representa el dominio raíz, es decir, `meu-project.me`. El host `www` permite que también funcione `www.meu-project.me`, manteniendo ambas variantes dirigidas al mismo servidor.

El TTL se ha dejado en valor automático, lo que resulta adecuado para una configuración estándar y evita complicaciones innecesarias.

## 6. Flujo de acceso

Una vez aplicada la configuración, el recorrido del tráfico es el siguiente:

1. El usuario escribe `meu-project.me` en el navegador.
2. El navegador consulta el DNS y obtiene la IP `52.91.73.172`.
3. Esa IP corresponde a la Elastic IP del master de Kubernetes.
4. El tráfico llega al nodo master.
5. El master recibe la petición y la gestiona mediante la capa de entrada del clúster.
6. Kubernetes distribuye la petición al servicio o aplicación correspondiente.

Este flujo convierte al master en el punto de entrada lógico del proyecto, mientras que la aplicación real puede estar organizada internamente en pods, servicios y namespaces.

## 7. Relación con Kubernetes

Aunque el dominio apunta físicamente al master, la intención real es que el **Ingress Controller** sea quien gestione las peticiones web. El dominio no entrega directamente la aplicación; solo proporciona una puerta de entrada estable hacia el clúster.

Esto encaja con una arquitectura típica de Kubernetes:

- DNS público.
- IP fija del master.
- Ingress como puerta de entrada HTTP/HTTPS.
- Servicios internos para distribuir el tráfico.
- Pods que ejecutan las aplicaciones finales.

De esta forma, el dominio queda desacoplado de los detalles internos del despliegue, lo que mejora la mantenibilidad del sistema.

## 8. Seguridad y estabilidad

La elección de una Elastic IP aporta estabilidad, pero la seguridad depende de una configuración correcta en AWS y Kubernetes. Para que el dominio funcione de forma adecuada, el master debe tener abiertos únicamente los puertos necesarios para el acceso público, normalmente **80** y **443**. Otros servicios administrativos, como SSH o la API de Kubernetes, deberían restringirse a IPs concretas.

También conviene evitar cambios frecuentes en los registros DNS una vez que la configuración esté validada. Cuantos menos cambios haya en la fase final, menos riesgo existe de problemas de propagación o de inconsistencias entre el dominio y la infraestructura.

## 9. Verificación esperada

Tras la configuración, el comportamiento esperado es el siguiente:

- `meu-project.me` debe resolver a `52.91.73.172`.
- `www.meu-project.me` debe resolver a la misma IP.
- El navegador debe llegar al master sin errores de DNS.
- Si el Ingress está correctamente configurado, el dominio debe mostrar la aplicación o panel previsto.
- Si la aplicación todavía no está publicada, el dominio al menos debe llegar al servidor y responder a nivel HTTP/HTTPS.

## 10. Posibles incidencias

Las incidencias más habituales en este tipo de configuración son:

- **Propagación DNS incompleta**: el cambio todavía no se refleja en todos los servidores.
- **Puertos cerrados en AWS**: el master recibe DNS correctamente, pero no responde por falta de reglas de seguridad.
- **Ingress no desplegado**: el dominio resuelve bien, pero Kubernetes todavía no está preparado para servir la aplicación.
- **Conflicto con registros antiguos**: si existían registros previos, pueden interferir con la nueva configuración.

En caso de fallo, lo primero es comprobar que el dominio resuelve a la IP correcta y que la Elastic IP sigue asociada al master.

## 11. Conclusión

La configuración de `meu-project.me` en Namecheap apuntando a la Elastic IP `52.91.73.172` proporciona una base sólida, estable y profesional para el proyecto. Esta solución permite centralizar el acceso en el master de Kubernetes, mantener una URL fija para el desarrollo y la presentación, y preparar la infraestructura para un despliegue más completo mediante Ingress y servicios internos.

Si quieres, el siguiente paso puede ser convertir este texto en una versión más formal de memoria técnica, con estilo de TFG y formato aún más académico.