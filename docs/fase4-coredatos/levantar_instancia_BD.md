# Levantar Instancia EC2 BBDD
## Descripción
Lanzamiento de la instancia EC2 destinada a alojar MariaDB directamente en el sistema operativo, fuera del clúster K3s. Esta instancia actúa como nodo de base de datos centralizado para toda la plataforma de hosting multicliente.

## Decisiones aplicadas
- **MariaDB corre en el SO del EC2 DDBB**, NO como pod de Kubernetes — decisión previa del proyecto para evitar overhead y simplificar la gestión del datadir.

- **Sin IP pública** — instancia ubicada en subred privada, solo accesible desde los nodos internos del clúster.

- **Almacenamiento EBS gp3** — único modelo de almacenamiento adoptado; volumen adicional de 10 GB reservado para /var/lib/mysql.

## Especificaciones de la instancia
| Parámetro      | Valor                                                     |
| -------------- | --------------------------------------------------------- |
| Nombre         | BD-Proyecte-MEU                                           |
| Tipo           | t3.small                                                  |
| RAM            | 2 GB                                                      |
| Región         | us-east-1                                                 |
| AMI            | Ubuntu 22.04 LTS                                          |
| Subred         | Privada (sin IP pública)                                  |
| Security Group | SG-DataBase-Private — puerto 3306 TCP solo CIDR interno   |
| Volumen raíz   | EBS gp3, 20 GB                                            |
| Volumen datos  | EBS gp3, 10 GB → pendiente montar en /var/lib/mysql       |

## Implementación
- Nombre de instancia:

 ![Nombre de la instancia (creacion)](../../media/creacion_instanciaBD1.png)

- AMI de instancia:

![Imagen de la instancia](../../media/creacion_instanciaBD2.png)

- Tip de instancia y claves:

![Tipo de instancia y claves de inicio de sesion](../../media/creacion_instanciaBD3.png)

- Configuración de red de la instancia:

![Configuracion de la red](../../media/creacion_instanciaBD4.png)

- Configuración de almacenamiento de la instancia:

![Configuracion de almacenamiento](../../media/creacion_instanciaBD5.png)

- Confirmación de que ha funcionado:

![Imagen que muestra que se creo correctamente](../../media/creacion_instanciaBD6.png)

## Estado
  - Instancia lanzada y en estado running
  - Volumen EBS adicional montado en /var/lib/mysql
  - MariaDB instalado y configurado
  - Security Group validado desde nodos internos
  - Secrets y ConfigMap (my.cnf) aplicados


---


# Despliegue y configuración de MariaDB
Instalación, securización y configuración de MariaDB directamente en el sistema operativo de la instancia ec2-ddbb, fuera del clúster K3s, siguiendo la arquitectura definida para el proyecto. La instancia reside en la subred privada subnet-privada-backend (10.2.2.0/24) de la VPC vpc-proyecto-meu, sin IP pública.

## Configuración inicial aplicada
- Instalación de MariaDB
  ```sql
  sudo apt update
  sudo apt install mariadb-server
  ```
  ![Instalacion MariaDB](../../media/instalacion_mariaDB.png)

- Arranque y habilitación del servicio
  ```sql
  sudo systemctl start mariadb
  sudo systemctl enable mariadb
  sudo systemctl status mariadb
  ```
  ![Arranque servicio](../../media/arranque_servicio_mariaDB.png)

- Securización inicial
  ```sql
  sudo mysql_secure_installation
  ```
  ![securizacion inicial](../../media/securizacion_inicial_mariaDB.png)
  - Acciones aplicadas:
    - Autenticación mantenida por contraseña (no unix_socket)
    - Eliminación de usuarios anónimos
    - Root remoto deshabilitado — solo acceso local
    - Base de datos test eliminada
    - Tablas de privilegios recargadas

- Configuración de red — bind-address
  ```sql
  # Archivo: /etc/mysql/mariadb.conf.d/50-server.cnf
  bind-address = 10.2.2.X   # IP privada de la instancia
  ```
  ![securizacion inicial](../../media/ajustes_red_BD.png)

- Creación de base de datos inicial
  ```sql
  CREATE DATABASE plataforma_hosting CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  ```
  ![securizacion inicial](../../media/creacion_BD.png)

- Creación de usuario de aplicación
  ```sql
  CREATE USER 'meu_admin'@'10.2.2.%' IDENTIFIED BY '***';
  GRANT ALL PRIVILEGES ON plataforma_hosting.* TO 'meu_admin'@'10.2.2.%';
  FLUSH PRIVILEGES;
  ```
  ![securizacion inicial](../../media/verificacion_usuario_BD.png)


---

# Configuración avanzada aplicada
## Montaje de volumen EBS
Creación, adjunción y montaje de un volumen EBS gp3 dedicado de 10 GiB en la instancia ec2-ddbb, destinado exclusivamente al datadir de MariaDB (/var/lib/mysql). Esto separa los datos de la base de datos del disco raíz del sistema operativo, alineándose con la arquitectura de almacenamiento definida en el proyecto.

## Decisiones aplicadas
  - **EBS gp3 exclusivamente** — descartados Longhorn y NFS según decisión previa del proyecto.
  - Volumen separado del disco raíz para **independencia de datos** — si la instancia se reemplaza, el volumen de datos persiste.
  - **nofail** en **fstab** para evitar bloqueo del arranque si el volumen tarda en adjuntarse.
  - Datos migrados con **rsync** desde el datadir original antes de remontar, sin pérdida de datos.

## Pasos ejecutados
  - Creación del volumen en AWS: Ya añadido en la creación de la instancia.
  - Comandos usados:
    ```sql
    # Verificación del disco en el SO
    lsblk
    
    # Formateo
    sudo mkfs.ext4 /dev/nvme1n1

    # Parada de MariaDB
    sudo systemctl stop mariadb

    # Copia de datos al nuevo volumen
    sudo mkdir /mnt/ebs-mysql
    sudo mount /dev/nvme1n1 /mnt/ebs-mysql
    sudo rsync -av /var/lib/mysql/ /mnt/ebs-mysql/

    # Montaje definitivo en /var/lib/mysql
    sudo umount /mnt/ebs-mysql
    sudo mount /dev/nvme1n1 /var/lib/mysql

    # Persistencia en fstab (Archivo: /etc/fstab)
    UUID=f5f49a33-6ed7-473d-9b3d-cc00f45395a9  /var/lib/mysql  ext4  defaults,nofail  0  2

    # Verificación
    sudo mount -a
    sudo systemctl start mariadb
    sudo systemctl status mariadb
    df -h /var/lib/mysql
    ```
    ![securizacion inicial](../../media/arrancar_mariaDB.png)
    ![securizacion inicial](../../media/comprovacion.png)

## Estado
   - Volumen EBS gp3 de 10 GiB creado en us-east-1c
   - Volumen adjuntado a ec2-ddbb como /dev/nvme1n1
   - Formateado con ext4
   - Datos migrados desde datadir original con rsync
   - Montado permanentemente en /var/lib/mysql vía fstab
   - MariaDB arrancado y operativo sobre el nuevo volumen
   - Verificado: 9.2G disponibles, 125M usados