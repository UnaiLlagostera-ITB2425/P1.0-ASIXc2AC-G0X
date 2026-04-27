# Pruebas del proyecto
## 1. Prueba de dominio y DNS
Demuestra que el dominio meu-project.me resuelve correctamente
```sql
nslookup meu-project.me
curl -I http://meu-project.me
curl -I https://meu-project.me
```
- **Resultado esperado:** resolución a 54.163.235.144 y respuesta HTTP del Ingress Controller.

## 2. Prueba de conectividad entre cuentas (VPC Peering)
Demuestra que la red inter-cuenta funciona correctamente.
```sql
# Desde la EC2 Master (Erick) → hacer ping a la EC2 DDBB de Manuel
ping 10.2.2.154

# Desde un Worker (Unai) → hacer ping a la EC2 DDBB
ping 10.2.2.154
```
- **Resultado esperado:** respuesta de ping desde ambos nodos hacia la BBDD.

## 3. Prueba de acceso SQL desde red interna
Demuestra que MariaDB acepta conexiones desde los nodos del clúster
```sql
# Desde un Worker o Master hacia la BBDD
mariadb -h 10.2.2.154 -u app_admin -p plataforma_hosting
```
- **Resultado esperado:** acceso a la base plataforma_hosting sin errores.

## 4. Prueba de persistencia EBS
Demuestra que los datos sobreviven a un reinicio de la instancia
```sql
# En la EC2 DDBB — insertar un dato de prueba
sudo mariadb -e "INSERT INTO plataforma_hosting.clientes (nombre, email) VALUES ('Cliente Test', 'test@test.com');"

# Reiniciar la instancia
sudo reboot

# Tras el reinicio — comprobar que el dato sigue
sudo mariadb -e "SELECT * FROM plataforma_hosting.clientes;"
```
- **Resultado esperado:** el registro persiste tras el reinicio.

## 5. Prueba de acceso denegado desde exterior
Demuestra que el Security Group bloquea accesos no autorizados
```sql
# Desde tu máquina local (fuera de la VPC) intentar conectar al puerto 3306
nc -zv IP_PUBLICA_O_PRIVADA_DDBB 3306
```
- **Resultado esperado:** Connection refused o timeout — confirma que la BBDD no es accesible desde fuera.

## 6. Prueba de volumen EBS
Demuestra que el datadir de MariaDB usa el volumen dedicado, no el disco raíz
```sql
df -h /var/lib/mysql
# Debe mostrar /dev/nvme1n1 con 9.8G
```