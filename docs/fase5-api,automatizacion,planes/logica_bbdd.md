# Lógica: Base de Datos

---

## Contexto y justificación

Cada cliente del SaaS necesita su propia base de datos y su propio usuario MariaDB con permisos exclusivos sobre ella. Esta función es llamada por la API en el momento de crear un nuevo cliente, justo antes de desplegar los recursos Kubernetes.

El objetivo es que cada cliente esté completamente aislado a nivel de datos: el usuario del cliente A no puede ver ni modificar la base de datos del cliente B.

### ¿Por qué base de datos lógica y no un servidor MariaDB por cliente?

| Opción | Problema |
|--------|----------|
| **Un MariaDB por cliente** | Muy costoso en recursos. Para 50 clientes serían 50 contenedores MariaDB activos permanentemente |
| **Base de datos lógica por cliente** ✅ | Un único servidor MariaDB compartido con una BBDD y un usuario aislado por cliente. Mucho más eficiente |
| **Esquema dentro de una sola BBDD** | Sin aislamiento real. Un error de permisos expone todos los datos |

Con la base de datos lógica conseguimos:
- **Aislamiento**: el usuario de cada cliente solo tiene permisos sobre su propia BBDD.
- **Eficiencia**: un solo servidor MariaDB para todos los clientes.
- **Gestión sencilla**: crear, eliminar o hacer backup de un cliente es operar sobre una sola BBDD.

---

## Arquitectura de la capa de datos

```text
[API — k8s-master]
   ↓ llama a función create_client_database(client_name)
[MariaDB — k8s-master o pod dedicado]
   ├── BBDD: saas_acme       ← datos del cliente acme
   │     └── usuario: acme   ← solo tiene acceso a saas_acme
   ├── BBDD: saas_beta       ← datos del cliente beta
   │     └── usuario: beta   ← solo tiene acceso a saas_beta
   └── BBDD: saas_gamma      ← datos del cliente gamma
         └── usuario: gamma  ← solo tiene acceso a saas_gamma
```

---

## Convenciones de nomenclatura

| Elemento | Formato | Ejemplo |
|----------|---------|---------|
| Base de datos | `saas_{client_name}` | `saas_acme` |
| Usuario MariaDB | `{client_name}` | `acme` |
| Contraseña | Generada aleatoriamente (32 chars) | `aX9kP2...` |
| Host permitido | `%` (cualquier IP interna del cluster) | `%` |

> ⚠️ El host `%` permite conexiones desde cualquier IP. En un entorno de producción estricto se limitaría a la subnet del cluster (`10.244.0.0/16`), pero para este SaaS en Kubernetes es la opción más práctica ya que los pods tienen IPs dinámicas.

---

## Función `create_client_database`

**Para qué sirve:** Recibe el nombre del cliente y una contraseña, se conecta a MariaDB como root y ejecuta tres operaciones atómicas: crear la base de datos, crear el usuario y asignar todos los permisos sobre esa base de datos al usuario.

```python
import mysql.connector
import secrets
import string

def generate_password(length=32):
    """Genera una contraseña aleatoria segura."""
    alphabet = string.ascii_letters + string.digits + "!@#$%^&*"
    return ''.join(secrets.choice(alphabet) for _ in range(length))

def create_client_database(client_name: str, db_password: str = None):
    """
    Crea una base de datos y un usuario MariaDB para un cliente nuevo.

    Args:
        client_name: Nombre corto del cliente (ej: 'acme')
        db_password: Contraseña del usuario. Si no se pasa, se genera automáticamente.

    Returns:
        dict con las credenciales creadas.
    """
    db_name = f"saas_{client_name}"
    db_user = client_name
    db_pass = db_password or generate_password()

    # Conectar a MariaDB como root
    conn = mysql.connector.connect(
        host="127.0.0.1",       # IP del servidor MariaDB
        port=3306,
        user="root",
        password="ROOT_PASSWORD_AQUI"
    )
    cursor = conn.cursor()

    try:
        # 1. Crear la base de datos del cliente
        cursor.execute(f"CREATE DATABASE IF NOT EXISTS `{db_name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")

        # 2. Crear el usuario del cliente
        cursor.execute(f"CREATE USER IF NOT EXISTS `{db_user}`@`%` IDENTIFIED BY '{db_pass}';")

        # 3. Asignar permisos exclusivos sobre su propia BBDD
        cursor.execute(f"GRANT ALL PRIVILEGES ON `{db_name}`.* TO `{db_user}`@`%`;")

        # 4. Aplicar los cambios de privilegios
        cursor.execute("FLUSH PRIVILEGES;")

        conn.commit()
        print(f"[OK] Base de datos '{db_name}' y usuario '{db_user}' creados correctamente.")

        return {
            "db_name": db_name,
            "db_user": db_user,
            "db_password": db_pass,
            "db_host": "mariadb-service",   # Nombre del Service Kubernetes de MariaDB
            "db_port": 3306
        }

    except Exception as e:
        conn.rollback()
        print(f"[ERROR] No se pudo crear la base de datos: {e}")
        raise

    finally:
        cursor.close()
        conn.close()
```

### Qué hace cada paso

| Paso | SQL ejecutado | Función |
|------|--------------|---------|
| 1 | `CREATE DATABASE IF NOT EXISTS saas_acme` | Crea la BBDD con charset UTF-8 completo |
| 2 | `CREATE USER IF NOT EXISTS acme@% IDENTIFIED BY '...'` | Crea el usuario MariaDB del cliente |
| 3 | `GRANT ALL PRIVILEGES ON saas_acme.* TO acme@%` | El usuario solo puede acceder a su BBDD |
| 4 | `FLUSH PRIVILEGES` | Aplica los cambios de privilegios inmediatamente |

> ℹ️ `IF NOT EXISTS` en CREATE DATABASE y CREATE USER hace que la función sea **idempotente**: si se llama dos veces con el mismo cliente, no falla. Esto es importante para reintentos automáticos desde la API.

---

## Función `delete_client_database`

**Para qué sirve:** Elimina completamente la base de datos y el usuario de un cliente cuando se da de baja. Es llamada por la API junto con `helm uninstall`.

```python
def delete_client_database(client_name: str):
    """
    Elimina la base de datos y el usuario MariaDB de un cliente.

    Args:
        client_name: Nombre corto del cliente (ej: 'acme')
    """
    db_name = f"saas_{client_name}"
    db_user = client_name

    conn = mysql.connector.connect(
        host="127.0.0.1",
        port=3306,
        user="root",
        password="ROOT_PASSWORD_AQUI"
    )
    cursor = conn.cursor()

    try:
        # 1. Revocar privilegios
        cursor.execute(f"REVOKE ALL PRIVILEGES ON `{db_name}`.* FROM `{db_user}`@`%`;")

        # 2. Eliminar el usuario
        cursor.execute(f"DROP USER IF EXISTS `{db_user}`@`%`;")

        # 3. Eliminar la base de datos (con todos sus datos)
        cursor.execute(f"DROP DATABASE IF EXISTS `{db_name}`;")

        cursor.execute("FLUSH PRIVILEGES;")
        conn.commit()

        print(f"[OK] Base de datos '{db_name}' y usuario '{db_user}' eliminados.")

    except Exception as e:
        conn.rollback()
        print(f"[ERROR] No se pudo eliminar la base de datos: {e}")
        raise

    finally:
        cursor.close()
        conn.close()
```

> ⚠️ `DROP DATABASE` es **irreversible**. Antes de ejecutar esta función, la API debe hacer un backup de la BBDD del cliente.

---
