# Manual de Seguridad de los Servicios de la Aplicación Web

## 1. Visión General de la Seguridad

Este documento describe las capas de seguridad implementadas en los servicios de la aplicación web `meu-project.me`, desplegada sobre Kubernetes `kubeadm` en AWS y actualizada conforme a la arquitectura final basada en **Calico + Ingress NGINX + cert-manager + TLS**. La seguridad ya no se articula alrededor de un proxy NGINX Docker externo como punto principal de exposición, sino directamente sobre el clúster Kubernetes, donde el Ingress Controller recibe el tráfico desde Internet en los puertos estándar 80 y 443 sobre el nodo `k8s-submaster` con Elastic IP.

La protección se aplica en múltiples niveles complementarios: Internet, Security Groups de AWS, exposición controlada del Ingress NGINX, cifrado TLS gestionado por cert-manager, segmentación de tráfico entre pods mediante Calico y endurecimiento lógico de los propios servicios de aplicación. Esta aproximación mantiene el principio de defensa en profundidad, pero elimina una capa intermedia innecesaria que en la arquitectura anterior añadía complejidad y superficie operativa adicional.

---

## 2. Seguridad en AWS Security Groups

Los Security Groups de AWS actúan como firewall stateful a nivel de instancia EC2. En la arquitectura actual, los puertos públicos deben estar abiertos únicamente en el nodo `k8s-submaster`, ya que es el nodo donde se ejecuta `ingress-nginx-controller` y al que apunta el DNS del dominio y el wildcard `*.meu-project.me`. El nodo `k8s-master` ya no debe exponerse como punto de entrada HTTP/HTTPS de la aplicación.  

### 2.1 Security Group del nodo público `k8s-submaster`

| Puerto | Protocolo | Origen | Propósito |
|---|---|---|---|
| 22 | TCP | IP admin/VPN | SSH de administración   |
| 80 | TCP | 0.0.0.0/0 | HTTP público para redirección a HTTPS y challenge ACME HTTP-01   |
| 443 | TCP | 0.0.0.0/0 | HTTPS público con terminación TLS en Ingress NGINX   |
| 10250 | TCP | Nodos autorizados del clúster | Kubelet, solo tráfico interno de administración   |
| 179 | TCP | Nodos del clúster / SG interno | BGP de Calico entre nodos   |

**Principio de mínimo privilegio:** solo el nodo que ejecuta el Ingress debe exponer 80 y 443. Esta decisión reduce la superficie pública al mínimo imprescindible y evita que otros nodos del clúster reciban tráfico de aplicación directamente desde Internet.  

### 2.2 Security Groups de nodos internos

Los nodos internos del clúster no requieren exposición pública de servicios de aplicación. Sus reglas deben permitir únicamente la comunicación estrictamente necesaria para el control plane, la red del clúster y los backends de datos. Entre ellas destacan `6443/TCP` para el API Server, `10250/TCP` para Kubelet, `179/TCP` para BGP de Calico y `3306/TCP` para acceso a la base de datos desde los pods autorizados.  

La apertura del puerto `179/TCP` es especialmente crítica en esta arquitectura porque Calico usa BGP para distribuir rutas entre nodos. Si este puerto no está permitido entre instancias, BIRD no establece vecindades y la red de pods queda rota, lo que deriva en indisponibilidad de servicios incluso aunque los pods estén aparentemente desplegados.  

---

## 3. Seguridad en Ingress NGINX y TLS

### 3.1 Cambio de modelo de exposición

Con la migración completa a Kubernetes, el **Ingress NGINX Controller** gestiona el tráfico directamente desde Internet y escucha en los puertos 80 y 443 expuestos como NodePorts ampliados dentro del clúster. Esto sustituye la arquitectura anterior basada en NGINX Docker externo y traslada las funciones de routing, redirección HTTPS y terminación TLS al propio plano de servicios de Kubernetes.  

Desde el punto de vista de seguridad, esta decisión aporta tres ventajas: menos componentes expuestos, una sola capa de control HTTP/HTTPS administrada por Kubernetes y una integración nativa con cert-manager para el ciclo de vida del certificado. También elimina el riesgo operativo de inconsistencias entre configuraciones duplicadas en un proxy externo y en el Ingress Controller. -

### 3.2 Exposición en puertos estándar 80/443

Por defecto, Kubernetes solo permite NodePorts en el rango `30000-32767`, pero en esta solución se amplía explícitamente el rango del `kube-apiserver` para incluir 80 y 443. La razón de seguridad y diseño es que el tráfico público debe entrar por puertos estándar, evitando soluciones ad hoc con reglas locales de `iptables` o DNAT que en AWS no resultan fiables debido a cómo las Elastic IP son tratadas en la infraestructura antes de llegar al kernel del nodo.  

Este cambio no es meramente funcional: también simplifica el modelo de exposición pública, mejora la trazabilidad del flujo HTTP/HTTPS y reduce errores derivados de puertos no convencionales o de traducciones intermedias que complican el troubleshooting de certificados y redirecciones.  

### 3.3 Configuración TLS segura

La terminación TLS se realiza directamente en el Ingress NGINX Controller usando certificados emitidos por Let’s Encrypt y almacenados en Secrets de Kubernetes. El recurso Ingress referencia esos certificados mediante `secretName`, lo que permite centralizar el cifrado en un punto coherente con el routing de aplicación.  

Las medidas mínimas de securización asociadas al Ingress incluyen mantener `ssl-redirect: true` para forzar HTTPS, garantizar que el puerto 80 solo quede expuesto para la redirección y los challenges ACME, y evitar certificados autofirmados persistentes en producción. En caso de error `ERR_CERT_AUTHORITY_INVALID`, el manual documenta la comprobación del issuer real del Secret TLS y su regeneración mediante cert-manager.  

### 3.4 Cabeceras de seguridad y cabeceras de proxy

El Ingress actual añade anotaciones y `configuration-snippet` para propagar correctamente el contexto de seguridad hacia la aplicación. En particular, `X-Forwarded-Proto: https` y `X-Forwarded-Ssl: on` son esenciales porque el Ingress termina TLS y después reenvía la solicitud al backend en HTTP interno; sin estas cabeceras, aplicaciones como phpMyAdmin o frameworks web pueden interpretar erróneamente que la conexión original fue insegura.  

Estas cabeceras no solo evitan errores funcionales de cookies y redirecciones, sino que forman parte del endurecimiento lógico de la aplicación. Permiten que el backend genere cookies `Secure`, construya URLs canónicas HTTPS y aplique correctamente políticas de sesión que dependen del esquema original de la petición.  

### 3.5 Rate limiting y restricciones del Ingress

El Ingress de la aplicación puede aplicar políticas de limitación a nivel de recurso mediante anotaciones como `nginx.ingress.kubernetes.io/limit-rps`, `nginx.ingress.kubernetes.io/limit-connections`, `nginx.ingress.kubernetes.io/proxy-body-size` y timeouts explícitos. Estas directivas permiten imponer un control de volumen razonable de peticiones, reducir el impacto de abusos básicos y limitar uploads excesivos que podrían afectar al backend o agotar recursos. 

A diferencia del modelo anterior, estas políticas ya no deben aplicarse en un proxy Docker externo, sino directamente donde reside la lógica real de exposición del servicio. Esto mejora la coherencia entre seguridad, routing y despliegue declarativo del clúster. -

---

## 4. Seguridad en cert-manager y gestión del certificado TLS

### 4.1 Ciclo de vida seguro del certificado

`cert-manager` es el operador de Kubernetes encargado de automatizar la solicitud, validación, emisión y renovación de certificados TLS. En la arquitectura actual se integra con el Ingress NGINX usando un `ClusterIssuer` de Let’s Encrypt y el método `HTTP-01`, de modo que todo el flujo de confianza se resuelve dentro del clúster sin necesidad de exportar manualmente certificados a un proxy externo.  

El certificado emitido se almacena como un Secret de tipo `kubernetes.io/tls`, conteniendo `tls.crt` y `tls.key` en base64. Esto permite que la clave privada permanezca encapsulada en el modelo de secretos del clúster y evita la dispersión de material criptográfico en hosts o contenedores fuera de Kubernetes.  

### 4.2 Justificación de seguridad del flujo HTTP-01

La validación `HTTP-01` requiere que Let’s Encrypt acceda por HTTP al dominio y reciba el token servido por un pod temporal gestionado por cert-manager. En la arquitectura actual, esa ruta entra por la IP pública del `submaster`, pasa por el Ingress NGINX y es atendida por el challenge pod desplegado temporalmente. Esta integración directa reduce piezas intermedias y simplifica la cadena de confianza.  

El manual también documenta una limitación crítica: `HTTP-01` no permite emitir wildcard certificates, por lo que cada subdominio de cliente debe tener su propio recurso `Certificate` o resolverse con otro método como `DNS-01`. Desde el punto de vista de seguridad, esta decisión evita sobredimensionar privilegios DNS innecesarios y mantiene un aislamiento más claro entre dominios certificados individualmente.  

### 4.3 Renovación automática y reducción de riesgo operativo

Los certificados de Let’s Encrypt tienen una validez de 90 días y cert-manager inicia la renovación automática cuando quedan 30 días para la expiración. Esto reduce de forma importante el riesgo de indisponibilidad por expiración manual olvidada y elimina la necesidad de intervención humana recurrente sobre claves y certificados del frontend público.  

La automatización también mejora la seguridad operativa porque la rotación frecuente de certificados se convierte en parte del comportamiento normal del sistema. Un procedimiento automatizado y verificable siempre es preferible a una renovación manual que depende de copiar ficheros o reiniciar proxies externos con material criptográfico fuera del control declarativo de Kubernetes.  

---

## 5. Seguridad de la aplicación y de los servicios internos

### 5.1 Secrets de Kubernetes para credenciales

Las credenciales de la aplicación, como contraseñas de base de datos, claves de aplicación y otros secretos, no deben incorporarse ni al código fuente ni a las imágenes de contenedor. En el modelo final, estas credenciales se gestionan como **Secrets de Kubernetes**, que después se consumen desde los Deployments mediante `env.valueFrom.secretKeyRef`. 

Esta decisión refuerza la separación entre artefacto de despliegue y material sensible. Además, permite rotar secretos sin reconstruir imágenes y mantiene las credenciales bajo el mismo modelo de gobernanza que el resto de recursos del clúster. 

### 5.2 Exposición mínima de servicios

Los servicios internos de aplicación deben mantenerse como `ClusterIP` siempre que no exista una justificación explícita para su exposición. El ejemplo más claro es `phpMyAdmin`, cuyo acceso se publica a través de un Ingress específico, evitando exponerlo como `NodePort` o como servicio público indiscriminado.  

Este patrón es crucial para reducir superficie de ataque. En lugar de abrir puertos arbitrarios por servicio, toda la entrada queda centralizada en Ingress NGINX, donde se aplican reglas homogéneas de TLS, whitelist, redirección y headers.  

### 5.3 Restricción de acceso a phpMyAdmin

`phpMyAdmin` es una interfaz de administración de alto riesgo porque proporciona acceso directo a la base de datos. En la arquitectura actual su protección se basa en tres medidas: exposición solo mediante Ingress, restricción opcional por IP con `nginx.ingress.kubernetes.io/whitelist-source-range` y funcionamiento correcto de sesión bajo HTTPS gracias a `proxy-cookie-flags`, `X-Forwarded-Proto` y `X-Forwarded-Ssl`.  

La anotación de whitelist permite que solo la IP pública del administrador llegue al recurso. Esto convierte al Ingress en una frontera lógica de acceso, muy superior a publicar phpMyAdmin globalmente y confiar únicamente en la autenticación de la propia aplicación.  

### 5.4 Cookies seguras y semántica HTTPS real

Aplicaciones basadas en sesiones, como phpMyAdmin y muchas apps PHP, dependen de detectar que la conexión original del cliente fue HTTPS para establecer correctamente cookies seguras. Como el TLS termina en el Ingress y el backend recibe tráfico HTTP interno, la configuración del Ingress debe reenviar el contexto de seguridad mediante cabeceras adecuadas; de lo contrario, aparecen errores como `Failed to set session cookie`.  

Esta es una medida de seguridad importante porque una mala semántica de proxy puede degradar el modelo de sesión aunque el certificado sea válido. El endurecimiento de la cadena `cliente -> Ingress -> backend` es, por tanto, tanto funcional como criptográfico.  

---

## 6. Seguridad de red con Calico CNI

### 6.1 Calico como capa de aislamiento interno

Calico es el CNI del clúster y proporciona la conectividad entre pods, pero también habilita la base de una política de aislamiento de red a nivel interno. Su uso se justifica no solo por conectividad, sino por su capacidad de segmentar tráfico entre workloads y de controlar el movimiento lateral dentro del clúster mediante políticas de red.  

En la arquitectura desplegada, Calico utiliza BGP para distribuir rutas entre nodos y `IP-in-IP CrossSubnet` cuando el tráfico cruza subredes en AWS. Esto resuelve una limitación estructural de la VPC: la nube no conoce de forma nativa las rutas de los pods, por lo que la overlay de Calico pasa a ser un elemento central de seguridad y disponibilidad del clúster.  

### 6.2 Seguridad operativa del bootstrap de Calico

El manual documenta un problema real de seguridad y disponibilidad en el bootstrap: el init container `install-cni` de Calico puede quedar bloqueado si intenta consultar la API del clúster sin que exista aún red CNI funcional. La solución aplicada consiste en precrear manualmente el `calico-kubeconfig` en todos los nodos, rompiendo la dependencia circular del arranque.  

Desde una perspectiva de securización, este ajuste evita despliegues inconsistentes en los que parte del clúster queda sin conectividad o en estado parcialmente funcional. Un clúster con red rota no solo es inestable; también invalida cualquier política posterior de segmentación o protección entre servicios.  

### 6.3 Puerto BGP y dependencia de seguridad

El puerto `179/TCP` debe estar autorizado entre nodos porque Calico lo usa para sus sesiones BGP. Esta apertura no contradice el principio de mínimo privilegio: es una excepción estrictamente interna y controlada, sin exposición a Internet, indispensable para sostener la conectividad segura entre servicios y pods del clúster.  

Si se omite este puerto, los pods pueden quedar en estados aparentemente saludables pero sin conectividad real entre nodos. La disponibilidad de los servicios web depende por tanto no solo del Ingress y del TLS, sino también de este canal interno de control de rutas.  

---

## 7. Checklist de securización actualizado

### 7.1 Controles que deben estar activos

- El dominio raíz y los subdominios deben resolver a la Elastic IP del `k8s-submaster`, no al `k8s-master`.  
- Solo el nodo público debe exponer `80/TCP` y `443/TCP` a Internet.  
- El servicio `ingress-nginx-controller` debe estar operativo con NodePorts `80` y `443`.  
- El `ClusterIssuer` de Let’s Encrypt debe estar en estado `READY=True`.  
- Los certificados deben aparecer como `READY=True` y con `issuer` de Let’s Encrypt.  
- `phpMyAdmin` debe publicarse solo por Ingress y, si procede, con `whitelist-source-range`.  
- Calico debe tener todos sus pods en `Running` y las sesiones BGP establecidas.  

### 7.2 Verificación rápida

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
kubectl get svc -n ingress-nginx
kubectl get pods -n ingress-nginx -o wide
kubectl get pods -n cert-manager
kubectl get clusterissuer
kubectl get certificate -A
curl -I http://meu-project.me
curl -I https://meu-project.me
openssl s_client -connect meu-project.me:443 </dev/null | openssl x509 -noout -subject -issuer -dates
```

El estado esperado es: nodos `Ready`, pods de Calico `1/1 Running`, Ingress operativo, `ClusterIssuer` listo, certificados en `READY=True`, redirección HTTP `301` y respuesta HTTPS válida `200` con emisor Let’s Encrypt.  

---

## 8. Troubleshooting de seguridad relevante

### 8.1 Challenge HTTP-01 no valida

Si el challenge queda en estado `pending` o `invalid`, las causas más probables son: DNS apuntando al nodo incorrecto, puerto 80 inaccesible desde Internet o una política de redirección HTTPS mal aplicada en el momento de la emisión. En la arquitectura actual, el dominio raíz debe apuntar al `submaster`, ya que es donde corre el Ingress Controller; si apunta al `master`, Let’s Encrypt consulta un nodo que no sirve el challenge.  

### 8.2 Error de cookie segura en phpMyAdmin

Si aparece `Failed to set session cookie`, el problema no está en el certificado sino en la semántica de proxy. Deben revisarse las anotaciones `proxy-cookie-flags`, `configuration-snippet` y las cabeceras `X-Forwarded-Proto` / `X-Forwarded-Ssl`, porque la aplicación necesita saber que el cliente original accedió mediante HTTPS.  

### 8.3 Certificado inválido o autofirmado

Si el navegador muestra `ERR_CERT_AUTHORITY_INVALID`, hay que inspeccionar el contenido del Secret TLS y verificar su `issuer`. Si el Secret contiene un certificado antiguo o autofirmado, debe eliminarse junto al recurso `Certificate` para que cert-manager regenere automáticamente el material correcto.  

### 8.4 Servicios caídos por problema de red interna

Si el Ingress responde pero el backend no, conviene revisar el estado de Calico y especialmente el establecimiento de BGP entre nodos. Un fallo en el puerto `179/TCP` o en el bootstrap del CNI puede romper la conectividad pod-a-pod y generar síntomas de caída de servicio que no se resuelven revisando solo el frontend HTTPS.  

---

## 9. Apéndices

### Apéndice A. Referencia de puertos

| Puerto | Protocolo | Componente | Descripción |
|---|---|---|---|
| 80 | TCP | Ingress NGINX NodePort | HTTP público, redirección a HTTPS y challenge ACME   |
| 443 | TCP | Ingress NGINX NodePort | HTTPS público, terminación TLS con cert-manager/Let’s Encrypt   |
| 179 | TCP | Calico BGP | Sesiones BGP entre nodos, obligatorio para la conectividad del clúster   |
| 6443 | TCP | kube-apiserver | API de Kubernetes control plane   |
| 10250 | TCP | kubelet | Comunicación interna entre nodos del clúster   |
| 3306 | TCP | MySQL/MariaDB | Acceso desde servicios autorizados a la base de datos   |

### Apéndice B. Ficheros y recursos clave

| Recurso/Fichero | Ubicación | Descripción |
|---|---|---|
| `kube-apiserver.yaml` | `/etc/kubernetes/manifests` | Manifiesto del static pod del API Server, incluye el rango ampliado de NodePorts   |
| `calico-kubeconfig` | `/etc/cni/net.d` en cada nodo | Kubeconfig del plugin CNI usado para el bootstrap de Calico   |
| `letsencrypt-prod` | `ClusterIssuer` | Emisor ACME de producción de Let’s Encrypt   |
| `meu-project-tls` | Secret TLS en Kubernetes | Certificado y clave privada usados por el Ingress   |
| `phpmyadmin-ingress` | Recurso Ingress | Punto de publicación restringido de phpMyAdmin   |

### Webgrafía

- Kubernetes Project. (2024, 17 de septiembre). *Ports and protocols*. Kubernetes Documentation. [https://kubernetes.io/docs/reference/networking/ports-and-protocols/](https://kubernetes.io/docs/reference/networking/ports-and-protocols/)
- Kubernetes Project. (s.f.). *Ingress*. Kubernetes Documentation. [https://kubernetes.io/docs/concepts/services-networking/ingress/](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- cert-manager. (s.f.). *Documentation*. [https://cert-manager.io/docs/](https://cert-manager.io/docs/)
- cert-manager. (s.f.). *ACME HTTP01*. [https://cert-manager.io/docs/configuration/acme/http01/](https://cert-manager.io/docs/configuration/acme/http01/)
- Project Calico. (s.f.). *Networking*. [https://docs.tigera.io/calico/latest/networking/](https://docs.tigera.io/calico/latest/networking/)
- Project Calico. (s.f.). *Configure BGP peering*. [https://docs.tigera.io/calico/latest/networking/configuring/bgp](https://docs.tigera.io/calico/latest/networking/configuring/bgp)
- Let’s Encrypt. (s.f.). *How It Works*. [https://letsencrypt.org/how-it-works/](https://letsencrypt.org/how-it-works/)
