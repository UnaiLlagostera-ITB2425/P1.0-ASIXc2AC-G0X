# Manual de Levantamiento de Infraestructura AWS

## 1. Arquitectura General

La infraestructura se distribuye en tres cuentas AWS Educate independientes. Cada cuenta opera su propia VPC en la región `us-east-1`. La comunicación entre cuentas se establece mediante VPC Peering. No se utilizan servicios gestionados de AWS más allá de instancias EC2, volúmenes EBS y recursos de red de la VPC.

| Instancia  | Tipo      | IP Privada | Subred       | Rol                          |
|------------|-----------|------------|--------------|------------------------------|
| ec2-master | t3.medium | 10.0.1.118 | 10.0.0.0/16  | Kubernetes Master (Cuenta A) |
| ec2-worker | t3.medium | 10.1.2.96  | 10.1.0.0/16  | Kubernetes Worker (Cuenta B) |
| ec2-ddbb   | t3.small  | 10.2.2.154 | 10.2.2.0/24  | MariaDB dedicado (Cuenta C)  |

***

<div align="center">
  <img src="../../media/Diagrama VPC (V1.0.0).jpg" alt="Diagrama de estructura de VPC" />
</div>

***

## 2. Planificación de Red y CIDRs

Los bloques CIDR de cada VPC no deben solaparse. Esta es una restricción técnica del VPC Peering: si dos VPCs tienen rangos de direcciones que se superponen, la conexión de peering no puede establecerse.

| VPC     | CIDR         | Cuenta   | Instancias           |
|---------|--------------|----------|----------------------|
| VPC A   | 10.0.0.0/16  | Cuenta A | ec2-master           |
| VPC B   | 10.1.0.0/16  | Cuenta B | ec2-worker           |
| VPC C   | 10.2.0.0/16  | Cuenta C | ec2-ddbb             |

La topología de peering requiere tres conexiones independientes dado que el VPC Peering no es transitivo. El tráfico entre Unai y Manuel no puede atravesar la VPC de Master:

```
Cuenta A — Master  (10.0.0.0/16)
    ├── pcx-A-B ──► Cuenta B — Unai   (10.1.0.0/16)
    └── pcx-A-C ──► Cuenta C — Manuel (10.2.0.0/16)

Cuenta B — Unai   (10.1.0.0/16)
    └── pcx-B-C ──► Cuenta C — Manuel (10.2.0.0/16)
```

***

## 3. Cuenta A (Master) — VPC, Red y Nodo Master

### 3.1 Crear la VPC

**Ruta:** `Servicios → VPC → Your VPCs → Create VPC`

Seleccionar **VPC only**.

| Campo | Valor |
|---|---|
| Name tag | `vpc-proyecto-k8s` |
| IPv4 CIDR block | `10.0.0.0/16` |
| IPv6 CIDR block | No IPv6 CIDR block |
| Tenancy | Default |

Hacer clic en **Create VPC**. Anotar el **VPC ID** generado — se necesitará para configurar el peering con Unai y Manuel.

***

<div align="center">
  <img src="../../media/pantalla_gui_vpc.png" alt="Vista de estructura de VPC" />
</div>

***

### 3.2 Crear las subredes

**Ruta:** `VPC → Subnets → Create subnet`

Seleccionar `vpc-proyecto-k8s` y agregar dos subredes:

**Subred pública:**

| Campo | Valor |
|---|---|
| Subnet name | `subnet-publica-frontend` |
| Availability Zone | `us-east-1a` |
| IPv4 CIDR block | `10.0.1.0/24` |

Hacer clic en **Add new subnet** antes de guardar.

**Subred privada:**

| Campo | Valor |
|---|---|
| Subnet name | `subnet-privada-backend` |
| Availability Zone | `us-east-1a` |
| IPv4 CIDR block | `10.0.2.0/24` |

Hacer clic en **Create subnet**.

**Habilitar IP pública automática en la subred pública:**

1. Seleccionar `subnet-publica-frontend`
2. **Actions → Edit subnet settings**
3. Activar **Enable auto-assign public IPv4 address**
4. **Save**

***

<div align="center">
  <img src="../../media/vista_subredes_lista.png" alt="DLista de subredes" />
</div>

***

### 3.3 Internet Gateway

**Ruta:** `VPC → Internet Gateways → Create internet gateway`

| Campo | Valor |
|---|---|
| Name tag | `igw-proyecto-k8s` |

**Actions → Attach to a VPC** → seleccionar `vpc-proyecto-k8s` → **Attach internet gateway**.

### 3.4 Tablas de enrutamiento

**Route Table pública (`rtb-publica`):**

1. Localizar la Route Table generada automáticamente para `vpc-proyecto-k8s`
2. **Tags → Edit tags** → asignar nombre `rtb-publica`
3. **Routes → Edit routes → Add route:**

| Destination | Target |
|---|---|
| `0.0.0.0/0` | `igw-proyecto-k8s` |
| `10.1.0.0/16` | `pcx-A-B` (se completa en el Paso 6) |
| `10.2.0.0/16` | `pcx-A-C` (se completa en el Paso 6) |

4. **Subnet associations** → asociar `subnet-publica-frontend`

**Route Table privada (`rtb-privada`):**

`Route Tables → Create route table`:

| Campo | Valor |
|---|---|
| Name | `rtb-privada` |
| VPC | `vpc-proyecto-k8s` |

Agregar las mismas rutas de peering (sin la ruta `0.0.0.0/0` al IGW). Asociar `subnet-privada-backend`.

***

<div align="center">
  <img src="../../media/tablas_enrutamiento.png" alt="Tablas de enrutamiento" />
</div>

***

### 3.5 Security Groups

**Ruta:** `VPC → Security Groups → Create security group`

#### SG-Master-Public

| Campo | Valor |
|---|---|
| Security group name | `SG-Master-Public` |
| Description | `Reglas de acceso para el nodo Master` |
| VPC | `vpc-proyecto-k8s` |

**Inbound rules:**

| Type | Protocol | Port | Source | Descripción |
|---|---|---|---|---|
| Custom TCP | TCP | `443` | `0.0.0.0/0` | HTTPS clientes desde Internet |
| Custom TCP | TCP | `6443` | `10.1.0.0/16` | Kubelet Workers de Unai → API Server |
| Custom TCP | TCP | `10250` | `10.1.0.0/16` | Respuesta Kubelet Workers de Unai |
| SSH | TCP | `22` | `<IP-Local>/32` | Acceso administrativo SSH de Master |

**Outbound rules:** dejar la regla por defecto (`All traffic → 0.0.0.0/0`).

***

<div align="center">
  <img src="../../media/grupos_seguridad.png" alt="Grupos de seguridad" />
</div>


***

### 3.6 Key Pair

**Ruta:** `EC2 → Key Pairs → Create key pair`

| Campo | Valor |
|---|---|
| Name | `keypair-proyecto-k8s` |
| Key pair type | RSA |
| Private key file format | `.pem` |

```bash
chmod 400 keypair-proyecto-k8s.pem
```

### 3.7 Lanzar EC2 Master

**Ruta:** `EC2 → Instances → Launch instances`

| Campo | Valor |
|---|---|
| Name | `EC2-Master` |
| AMI | Ubuntu Server 22.04 LTS — x86_64 |
| Instance type | `t3.small` |
| Key pair | `keypair-proyecto-k8s` |
| VPC | `vpc-proyecto-k8s` |
| Subnet | `subnet-publica-frontend` |
| Auto-assign public IP | Enable |
| Security group | `SG-Master-Public` |
| Storage (raíz) | 20 GiB — gp3 |

***

<div align="center">
  <img src="../../media/instancia_master_up.png" alt="Vista de informacion de la instancia Master" />
</div>


***

## 4. Cuenta B (Unai) — VPC, Red y Nodos Worker

### 4.1 Crear la VPC

| Campo | Valor |
|---|---|
| Name tag | `vpc-proyecto-k8s-B` |
| IPv4 CIDR block | `10.1.0.0/16` |
| IPv6 CIDR block | No IPv6 CIDR block |
| Tenancy | Default |

Anotar el **VPC ID** y el **Account ID** de Unai — necesarios para que Master y BBDD configuren el peering.

### 4.2 Crear la subred privada

Unai no necesita subred pública. Ambos Workers operan en subred privada y reciben tráfico exclusivamente desde el Master de Master a través del peering.

| Campo | Valor |
|---|---|
| Subnet name | `subnet-privada-B` |
| Availability Zone | `us-east-1a` |
| IPv4 CIDR block | `10.1.2.0/24` |

### 4.3 Tabla de enrutamiento privada

`Route Tables → Create route table`:

| Campo | Valor |
|---|---|
| Name | `rtb-privada-B` |
| VPC | `vpc-proyecto-k8s-B` |

**Routes → Edit routes:**

| Destination | Target |
|---|---|
| `10.0.0.0/16` | `pcx-A-B` (se completa en el Paso 6) |
| `10.2.0.0/16` | `pcx-B-C` (se completa en el Paso 6) |

Asociar `subnet-privada-B`.

### 4.4 Security Groups

#### SG-Workers-Private-B

| Campo | Valor |
|---|---|
| Security group name | `SG-Workers-Private-B` |
| Description | `Reglas para nodos Worker de Unai` |
| VPC | `vpc-proyecto-k8s-B` |

**Inbound rules:**

| Type | Protocol | Port | Source | Descripción |
|---|---|---|---|---|
| Custom TCP | TCP | `8080` | `10.0.0.0/16` | Tráfico aplicación desde NGINX del Master |
| Custom TCP | TCP | `10250` | `10.0.0.0/16` | Órdenes API Server desde Master |
| Custom TCP | TCP | `30000-32767` | `10.0.0.0/16` | Rango NodePort Kubernetes |
| SSH | TCP | `22` | `10.0.0.0/16` | Acceso SSH desde Master |

***

## 5. Cuenta C (Manuel) — VPC, Red, Bastion y Nodo DDBB

### 5.1 Crear la VPC

| Campo | Valor |
|---|---|
| Name tag | `vpc-proyecto-k8s-C` |
| IPv4 CIDR block | `10.2.0.0/16` |
| IPv6 CIDR block | No IPv6 CIDR block |
| Tenancy | Default |

Anotar el **VPC ID** y el **Account ID** de Manuel.

### 5.2 Crear las subredes

**Subred pública (para el Bastion):**

| Campo | Valor |
|---|---|
| Subnet name | `subnet-publica-C` |
| Availability Zone | `us-east-1a` |
| IPv4 CIDR block | `10.2.1.0/24` |

Habilitar **Auto-assign public IPv4 address** en `subnet-publica-C`.

**Subred privada (para el EC2 DDBB):**

| Campo | Valor |
|---|---|
| Subnet name | `subnet-privada-C` |
| Availability Zone | `us-east-1a` |
| IPv4 CIDR block | `10.2.2.0/24` |

### 5.3 Internet Gateway

| Campo | Valor |
|---|---|
| Name tag | `igw-proyecto-k8s-C` |

Adjuntar a `vpc-proyecto-k8s-C`.

### 5.4 Tablas de enrutamiento

**Route Table pública (`rtb-publica-C`):**

| Destination | Target |
|---|---|
| `0.0.0.0/0` | `igw-proyecto-k8s-C` |
| `10.0.0.0/16` | `pcx-A-C` (se completa en el Paso 6) |
| `10.1.0.0/16` | `pcx-B-C` (se completa en el Paso 6) |

Asociar `subnet-publica-C`.

**Route Table privada (`rtb-privada-C`):**

| Destination | Target |
|---|---|
| `10.0.0.0/16` | `pcx-A-C` (se completa en el Paso 6) |
| `10.1.0.0/16` | `pcx-B-C` (se completa en el Paso 6) |

Sin ruta `0.0.0.0/0`. Asociar `subnet-privada-C`.

***

### 5.5 Security Groups

#### SG-DDBB-Private-C

| Campo | Valor |
|---|---|
| Security group name | `SG-DDBB-Private-C` |
| Description | `Reglas para el nodo de base de datos de Manuel` |
| VPC | `vpc-proyecto-k8s-C` |

**Inbound rules:**

| Type | Protocol | Port | Source | Descripción |
|---|---|---|---|---|
| MySQL/Aurora | TCP | `3306` | `10.1.0.0/16` | Consultas SQL desde Workers de Unai |
| SSH | TCP | `22` | `10.0.0.0/16` | SSH desde Master|

***

## 6. Interconexión entre Cuentas — VPC Peering

### Datos previos requeridos

Antes de crear cualquier peering, cada miembro debe compartir con el equipo:

| Dato | Master (Cuenta A) | Worker (Cuenta B) | BBDD (Cuenta C) |
|---|---|---|---|
| Account ID | `AAAAAAAAAAAA` | `BBBBBBBBBBBB` | `CCCCCCCCCCCC` |
| VPC ID | `vpc-AAAA` | `vpc-BBBB` | `vpc-CCCC` |
| VPC CIDR | `10.0.0.0/16` | `10.1.0.0/16` | `10.2.0.0/16` |

### 6.1 Peering Master ↔ Worker (pcx-A-B)

**En Cuenta A (Master) — Solicitar:**

**Ruta:** `VPC → Peering connections → Create peering connection`

| Campo | Valor |
|---|---|
| Name | `pcx-Master-a-Worker` |
| VPC ID (Requester) | VPC ID de Master |
| Account | Another account |
| Account ID | Account ID de Worker |
| Region | `us-east-1` |
| VPC ID (Accepter) | VPC ID de Worker |

**En Cuenta B (Unai) — Aceptar:**

`VPC → Peering connections` → localizar solicitud en estado `Pending acceptance` desde Master → **Actions → Accept request**.

### 6.2 Peering Master ↔ BBDD (pcx-A-C)

**En Cuenta A (Master) — Solicitar:**

| Campo | Valor |
|---|---|
| Name | `pcx-Master-a-BBDD` |
| VPC ID (Requester) | VPC ID de Master |
| Account ID | Account ID de BBDD |
| VPC ID (Accepter) | VPC ID de BBDD |

**En Cuenta C (Manuel) — Aceptar** siguiendo el mismo procedimiento.

### 6.3 Peering Unai ↔ Manuel (pcx-B-C)

**En Cuenta B (Unai) — Solicitar:**

| Campo | Valor |
|---|---|
| Name | `pcx-Unai-a-Manuel` |
| VPC ID (Requester) | VPC ID de Unai |
| Account ID | Account ID de Manuel |
| VPC ID (Accepter) | VPC ID de Manuel |

**En Cuenta C (Manuel) — Aceptar** siguiendo el mismo procedimiento.

***

<div align="center">
  <img src="../../media/peering.png" alt="Vista de Interconexiones" />
</div>



***

### 6.4 Completar Route Tables con IDs de peering

Una vez los tres peerings están en estado `Active`, completar las rutas pendientes en cada cuenta:

**Cuenta A (Master) — `rtb-publica` y `rtb-privada`:**

| Destination | Target |
|---|---|
| `10.1.0.0/16` | `pcx-Master-a-Worker` |
| `10.2.0.0/16` | `pcx-Master-a-BBDD` |

**Cuenta B (Worker) — `rtb-privada-B`:**

| Destination | Target |
|---|---|
| `10.0.0.0/16` | `pcx-Master-a-Worker` |
| `10.2.0.0/16` | `pcx-Worker-a-BBDD` |

**Cuenta C (BBDD) — `rtb-publica-C` y `rtb-privada-C`:**

| Destination | Target |
|---|---|
| `10.0.0.0/16` | `pcx-Master-a-BBDD` |
| `10.1.0.0/16` | `pcx-Worker-a-BBDD` |

***

***

## 7. Verificación de Conectividad

Verificar con `ping` usando IPs privadas de cada instancia. El peering opera exclusivamente sobre IPs privadas.

**Desde EC2-Master:**

```bash
# Alcance a Workers de Unai
ping -c 4 10.1.2.X   # EC2-Worker
ping -c 4 10.1.2.Y   # EC2-Worker-2

# Alcance a DDBB de Manuel
ping -c 4 10.2.2.X   # EC2-DDBB
```

**Desde EC2-Worker (Unai) — accedido a través del Master de Erick:**

```bash
# Alcance a Master
ping -c 4 10.0.1.X

# Alcance a BBDD
ping -c 4 10.2.2.X
```

**Desde EC2-DDBB (Manuel) — accedido a través del Bastion:**

```bash
# Alcance a Master
ping -c 4 10.0.1.X

# Alcance a Workers
ping -c 4 10.1.2.X
```

***

## 8. Acceso SSH entre Nodos

Todos los nodos salvo el Master están en subredes privadas sin IP pública. El acceso SSH se realiza mediante saltos a través de los nodos con IP pública.

### Acceso de Master a los Workers

```bash
# En la máquina local de Master — agregar claves al agente SSH
ssh-add keypair-proyecto-k8s.pem
ssh-add keypair-proyecto-k8s-B.pem

# Conectar al Master con agent forwarding
ssh -A -i keypair-proyecto-k8s.pem ubuntu@<IP-PUBLICA-MASTER>

# Desde el Master, saltar a cualquier Worker de Unai
ssh ubuntu@10.1.2.X   # EC2-Worker
ssh ubuntu@10.1.2.Y   # EC2-Worker-2
```

### Acceso de Mster a la BBDD

```bash
# Copiar la clave de Manuel al Master (desde la máquina local)
scp -i keypair-proyecto-k8s.pem keypair-proyecto-k8s-C.pem \
    ubuntu@<IP-PUBLICA-MASTER>:~/.ssh/

# Conectar al Master
ssh -i keypair-proyecto-k8s.pem ubuntu@<IP-PUBLICA-MASTER>

# Desde el Master, ajustar permisos y saltar a la BBDD
chmod 400 ~/.ssh/keypair-proyecto-k8s-C.pem
ssh -i ~/.ssh/keypair-proyecto-k8s-C.pem ubuntu@10.2.2.X
```
