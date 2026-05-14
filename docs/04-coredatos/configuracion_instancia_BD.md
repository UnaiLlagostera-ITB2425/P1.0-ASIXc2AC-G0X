# Script SQL de Inicialización

## 1. Descripción

Creación del esquema base de la plataforma de hosting multicliente en la base de datos `plataforma_hosting`. Este esquema actúa como **base de control operativo** de la plataforma — no almacena contenido web de clientes, sino los metadatos necesarios para gestionar clientes, sitios, bases de datos asignadas, despliegues y auditoría.

Diseñado para ser reutilizable en la automatización Python/Bash del proyecto.

---

## 2. Decisiones de diseño

| Decisión | Detalle |
|----------|---------|
| Motor **InnoDB** | ACID, MVCC y claves foráneas — perfil OLTP del proyecto |
| `utf8mb4` + `utf8mb4_unicode_ci` | Compatibilidad completa con caracteres especiales en una plataforma web multicliente |
| `ON DELETE CASCADE / SET NULL` | Integridad referencial automática al eliminar clientes o sitios |
| `created_at` / `updated_at` | Auditoría básica gestionada por el propio motor con `CURRENT_TIMESTAMP` |
| `CREATE TABLE IF NOT EXISTS` | Script idempotente — se puede volver a ejecutar sin romper datos existentes |
| `sudo mariadb` | Root de MariaDB vinculado a autenticación local del sistema en Ubuntu 22.04 — acceso con `-p` bloqueado por diseño |

---

## 3. Tablas creadas

| Tabla                 | Propósito                                                       |
|-----------------------|-----------------------------------------------------------------|
| `clientes`            | Registro de clientes de la plataforma con estado                |
| `usuarios_panel`      | Usuarios administrativos y de cliente con roles                 |
| `sitios`              | Sitios web asociados a clientes, con dominio, imagen y estado   |
| `bases_datos_cliente` | Credenciales y datos de la BD asignada a cada sitio             |
| `despliegues`         | Trazabilidad de aprovisionamientos y versiones                  |
| `auditoria_eventos`   | Registro de acciones del sistema y del panel                    |

### Diagrama de relaciones

```
clientes (1) ────────< usuarios_panel (N)
clientes (1) ────────< sitios (N)
sitios   (1) ────────< bases_datos_cliente (N)
sitios   (1) ────────< despliegues (N)
sitios   (1) ────────< auditoria_eventos (N)
usuarios_panel (1) ──< auditoria_eventos (N)
```

---

## 4. Script SQL — init_plataforma.sql

**Ubicación en servidor:** `/home/meu_db1/init_plataforma.sql`

```sql
CREATE DATABASE IF NOT EXISTS plataforma_hosting
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE plataforma_hosting;

-- ─────────────────────────────────────────────
-- Tabla: clientes
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS clientes (
  id         BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  nombre     VARCHAR(150)    NOT NULL,
  email      VARCHAR(190)    NOT NULL UNIQUE,
  telefono   VARCHAR(30)     NULL,
  estado     ENUM('activo','suspendido','baja') NOT NULL DEFAULT 'activo',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─────────────────────────────────────────────
-- Tabla: usuarios_panel
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS usuarios_panel (
  id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  cliente_id    BIGINT UNSIGNED NULL,
  username      VARCHAR(80)     NOT NULL UNIQUE,
  email         VARCHAR(190)    NOT NULL UNIQUE,
  password_hash VARCHAR(255)    NOT NULL,
  rol           ENUM('superadmin','admin','cliente') NOT NULL DEFAULT 'cliente',
  ultimo_login  TIMESTAMP NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_usuarios_panel_cliente
    FOREIGN KEY (cliente_id) REFERENCES clientes(id)
    ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─────────────────────────────────────────────
-- Tabla: sitios
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sitios (
  id                  BIGINT UNSIGNED  AUTO_INCREMENT PRIMARY KEY,
  cliente_id          BIGINT UNSIGNED  NOT NULL,
  nombre              VARCHAR(150)     NOT NULL,
  dominio_principal   VARCHAR(190)     NOT NULL UNIQUE,
  subdominio_interno  VARCHAR(190)     NULL UNIQUE,
  ruta_repo           VARCHAR(255)     NULL,
  imagen_contenedor   VARCHAR(255)     NULL,
  version_actual      VARCHAR(100)     NULL,
  estado              ENUM('pendiente','activo','suspendido','error') NOT NULL DEFAULT 'pendiente',
  php_version         VARCHAR(20)      NULL,
  replicas            SMALLINT UNSIGNED NOT NULL DEFAULT 1,
  ssl_activo          TINYINT(1)       NOT NULL DEFAULT 0,
  created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_sitios_cliente
    FOREIGN KEY (cliente_id) REFERENCES clientes(id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─────────────────────────────────────────────
-- Tabla: bases_datos_cliente
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bases_datos_cliente (
  id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  sitio_id      BIGINT UNSIGNED NOT NULL,
  nombre_bd     VARCHAR(120)    NOT NULL UNIQUE,
  usuario_bd    VARCHAR(120)    NOT NULL UNIQUE,
  password_hash VARCHAR(255)    NOT NULL,
  host_bd       VARCHAR(120)    NOT NULL DEFAULT '10.2.2.154',
  puerto_bd     INT             NOT NULL DEFAULT 3306,
  estado        ENUM('activa','suspendida','eliminada') NOT NULL DEFAULT 'activa',
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_bases_datos_sitio
    FOREIGN KEY (sitio_id) REFERENCES sitios(id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─────────────────────────────────────────────
-- Tabla: despliegues
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS despliegues (
  id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  sitio_id            BIGINT UNSIGNED NOT NULL,
  entorno             ENUM('dev','staging','prod') NOT NULL DEFAULT 'prod',
  version_desplegada  VARCHAR(100)    NOT NULL,
  commit_hash         VARCHAR(64)     NULL,
  resultado           ENUM('pendiente','ok','fallido') NOT NULL DEFAULT 'pendiente',
  detalle             TEXT            NULL,
  fecha_despliegue    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_despliegues_sitio
    FOREIGN KEY (sitio_id) REFERENCES sitios(id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─────────────────────────────────────────────
-- Tabla: auditoria_eventos
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS auditoria_eventos (
  id               BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  sitio_id         BIGINT UNSIGNED NULL,
  usuario_panel_id BIGINT UNSIGNED NULL,
  tipo_evento      VARCHAR(100)    NOT NULL,
  descripcion      TEXT            NOT NULL,
  ip_origen        VARCHAR(45)     NULL,
  created_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_auditoria_sitio
    FOREIGN KEY (sitio_id) REFERENCES sitios(id)
    ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_auditoria_usuario
    FOREIGN KEY (usuario_panel_id) REFERENCES usuarios_panel(id)
    ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

---

## 5. Pasos de ejecución

```bash
# 1. Crear el archivo SQL en el servidor
nano /home/meu_db1/init_plataforma.sql
# (pegar el contenido del script del apartado 4)

# 2. Acceder a MariaDB como root del sistema
sudo mariadb
```

```sql
-- 3. Cargar el script
SOURCE /home/meu_db1/init_plataforma.sql;

-- 4. Verificar las tablas creadas
USE plataforma_hosting;
SHOW TABLES;
```

Resultado esperado:
```
+------------------------------+
| Tables_in_plataforma_hosting |
+------------------------------+
| auditoria_eventos            |
| bases_datos_cliente          |
| clientes                     |
| despliegues                  |
| sitios                       |
| usuarios_panel               |
+------------------------------+
6 rows in set
```

---

## 6. Estado

- [x] Esquema `plataforma_hosting` creado con 6 tablas
- [x] Motor InnoDB, utf8mb4, claves foráneas e integridad referencial verificados
- [x] Script verificado con `SHOW TABLES`
- [ ] Script movido al repositorio del proyecto para control de versiones
- [ ] Datos de prueba insertados para validar relaciones
- [ ] Integrado en automatización Python/Bash de aprovisionamiento

---