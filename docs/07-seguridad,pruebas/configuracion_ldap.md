# Integración LDAP — Gestión de Usuarios

## Descripción
Configuración de OpenLDAP como servidor de directorio local en la EC2 DDBB para centralizar
la autenticación de usuarios de la plataforma. MariaDB delega la validación de credenciales
a LDAP mediante el plugin PAM, usando un modelo de usuario proxy que permite escalar el
número de clientes sin crear un usuario MariaDB por cada uno.

## Contexto de la arquitectura
| Elemento              | Valor                                         |
|-----------------------|-----------------------------------------------|
| Servidor LDAP         | OpenLDAP `slapd` 2.6.10 — escucha en `ldap:///` y `ldapi:///` |
| Base DN               | `dc=meu,dc=local`                             |
| OU usuarios           | `ou=People,dc=meu,dc=local`                   |
| Cliente NSS/PAM       | `nslcd` 0.9.12 + `libpam-ldapd`               |
| Plugin MariaDB        | `auth_pam` (ACTIVE)                           |
| Usuario proxy cliente | `ldap_client@%` → `plataforma_hosting.*`      |
| Usuario proxy admin   | `ldap_admin@%` → `plataforma_hosting.*` (ALL) |

## Decisiones aplicadas
- Se eligió **OpenLDAP en el propio EC2 DDBB** en lugar de un servidor LDAP separado para evitar dependencias de red adicionales y mantener el coste de instancias bajo en AWS Academy.
- Se usa **modelo proxy** (`GRANT PROXY`) en lugar de usuarios directos: permite añadir usuarios en LDAP sin modificar permisos en MariaDB, escalando sin overhead operativo.
- `nss-ldap` (legacy) descartado en favor de `nslcd` + `libnss-ldapd` — paquete activo en Ubuntu 24.04, sin conflictos con `libpam-ldapd`.
- La URI de nslcd se configura con `ldap://127.0.0.1/` (loopback) para evitar dependencia del nombre DNS interno y fallos de resolución en red privada.

## Prerrequisitos
- EC2 DDBB operativa con MariaDB activo — `sudo systemctl status mariadb`
- Acceso SSH al EC2 DDBB desde Bastion (Cuenta C) o desde Master (Cuenta A) via VPC Peering
- Puerto 389 accesible en loopback (no expuesto externamente — Security Group no modificado)


## Pasos ejecutados
-  1. Instalación de paquetes NSS/PAM LDAP

    ```bash
    sudo apt update
    sudo apt install -y libnss-ldapd libpam-ldapd ldap-utils nscd slapd
    ```

    > `nss-ldap` y `libpam-ldap` generan conflicto con `libpam-ldapd` en Ubuntu 24.04.
    > Si estaban instalados previamente: `sudo apt remove --purge libpam-ldap libnss-ldap -y`

    Durante la instalación de `libnss-ldapd`:
    - **LDAP URI:** `ldap://127.0.0.1/`
    - **Name services:** `passwd`, `group`, `shadow` (solo estos tres)

- 2. Configuración de OpenLDAP — slapd
    ```bash
    sudo dpkg-reconfigure slapd
    ```

    Opciones seleccionadas:
    | Pregunta                        | Respuesta         |
    |---------------------------------|-------------------|
    | Omit OpenLDAP server config?    | No                |
    | DNS domain name                 | `meu.local`       |
    | Organization name               | `Meu Project`     |
    | Remove database on purge?       | No                |
    | Move old database?              | Yes               |


- 3. Corrección de /etc/nslcd.conf
    El instalador generó URI y base DN incorrectos. Se corrigieron manualmente:

    ```bash
    sudo nano /etc/nslcd.conf
    ```

    Valores corregidos:
    - uri ldap://127.0.0.1/
    - base dc=meu,dc=local
    - base passwd ou=People,dc=meu,dc=local
    - base shadow ou=People,dc=meu,dc=local


    ```bash
    sudo systemctl restart nslcd
    ```

- 4. Creación de estructura LDAP y usuarios
    Archivo `~/ldap/base-user.ldif`:

    ```ldif
    dn: ou=People,dc=meu,dc=local
    objectClass: organizationalUnit
    ou: People

    dn: uid=admin,ou=People,dc=meu,dc=local
    objectClass: inetOrgPerson
    objectClass: posixAccount
    objectClass: shadowAccount
    cn: Admin User
    sn: User
    uid: admin
    uidNumber: 10000
    gidNumber: 10000
    homeDirectory: /home/admin
    loginShell: /bin/bash
    mail: admin@meu-project.me
    userPassword: <password>

    dn: uid=demo,ou=People,dc=meu,dc=local
    objectClass: inetOrgPerson
    objectClass: posixAccount
    objectClass: shadowAccount
    cn: Demo User
    sn: User
    uid: demo
    uidNumber: 10001
    gidNumber: 10001
    homeDirectory: /home/demo
    loginShell: /bin/bash
    mail: demo@meu-project.me
    userPassword: <password>
    ```

    ```bash
    ldapadd -x -D "cn=admin,dc=meu,dc=local" -W -f ~/ldap/base-user.ldif
    ```

    > El usuario `admin` es el que utiliza `meu-api` para autenticar el acceso al panel.
    > El usuario `demo` se usa para pruebas y acceso MariaDB vía PAM.

- 5. Habilitación del plugin PAM en MariaDB
    ```sql
    INSTALL SONAME 'auth_pam';
    SELECT plugin_name, plugin_status FROM information_schema.plugins WHERE plugin_name = 'pam';
    -- → pam | ACTIVE
    ```

- 6. Creación de usuarios proxy en MariaDB
    ```sql
    CREATE USER 'ldap_client'@'%' IDENTIFIED BY '<password>';
    GRANT SELECT, INSERT, UPDATE, DELETE ON `plataforma_hosting`.* TO 'ldap_client'@'%';

    CREATE USER 'ldap_admin'@'%' IDENTIFIED BY '<password>';
    GRANT ALL PRIVILEGES ON `plataforma_hosting`.* TO 'ldap_admin'@'%';

    FLUSH PRIVILEGES;
    ```

- 7. Creación de usuario MariaDB autenticado vía PAM
    ```sql
    CREATE USER 'demo'@'%' IDENTIFIED VIA pam USING 'mariadb';
    GRANT PROXY ON 'ldap_client'@'%' TO 'demo'@'%';
    FLUSH PRIVILEGES;
    ```

- 8. Fichero PAM para MariaDB
    ```bash
    sudo nano /etc/pam.d/mariadb

    #%PAM-1.0
    auth required pam_ldap.so
    account required pam_ldap.so
    ```


- 9. Añadir mysql al grupo nslcd
    ```bash
    sudo usermod -aG nslcd mysql
    sudo systemctl restart mariadb
    ```

## Verificación

```bash
# LDAP operativo
sudo systemctl status slapd          # → active (running)
ldapsearch -x -b "dc=meu,dc=local" "(uid=demo)"  # → resultado OK

# NSS resuelve usuarios LDAP
getent passwd demo
# → demo:x:10001:10001:Demo User:/home/demo:/bin/bash

# Login MariaDB con credenciales LDAP
mysql -u demo -p -h 10.2.2.191
```

```sql
USE plataforma_hosting;
SHOW TABLES;
-- → 6 tablas: auditoria_eventos, bases_datos_cliente, clientes,
--             despliegues, sitios, usuarios_panel
```

---

## Estado
- `slapd` activo y sirviendo en `ldap:///` y `ldapi:///`
- Base DN `dc=meu,dc=local` creada y verificada con `slapcat`
- `ou=People` creada, usuarios `admin` y `demo` importados via LDIF
- `nslcd` corregido y resolviendo usuarios: `getent passwd demo` OK
- Plugin PAM instalado en MariaDB: `ACTIVE`
- Usuarios proxy `ldap_client` y `ldap_admin` creados con permisos correctos
- Login MariaDB con credenciales LDAP verificado
- Acceso a `plataforma_hosting` con 6 tablas confirmado
- Grant incorrecto `plataformahosting` (sin guión) eliminado
- Pendiente: añadir usuarios reales de clientes en LDAP
