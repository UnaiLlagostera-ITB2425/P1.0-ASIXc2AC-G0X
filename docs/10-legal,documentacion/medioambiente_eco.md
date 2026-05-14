# Documentación Medioambiental y Económica del Proyecto 

## 1. Introducción

Este documento analiza el impacto ambiental (huella de carbono) y los costes operativos asociados a la plataforma de hosting SaaS sobre Kubernetes cuando se escala a **1.000 clientes (inquilinos)** con funcionamiento **24 horas al día, 7 días a la semana (24/7)**. Se parte de la arquitectura definida en el proyecto (Kubernetes auto‑gestionado sobre EC2, MariaDB autohospedada, almacenamiento EBS, balanceador NLB) y se proyecta a un entorno productivo realista.

**Objetivos:**
- Estimar las emisiones de CO₂e derivadas del consumo eléctrico de la infraestructura.
- Calcular los costes mensuales en AWS (región `us-east-1`) con precios on‑demand.
- Proponer medidas de optimización (económicas y ambientales).

---

## 2. Arquitectura escalada para 1.000 clientes

| Componente | Tipo de instancia | Cantidad | vCPU | RAM (GB) | Uso (h/mes) |
|------------|-------------------|----------|------|----------|-------------|
| Plano de control (HA) | `t3.medium` | 3 | 2 | 4 | 720 |
| Nodos worker | `t3.large` | 20 | 2 | 8 | 720 |
| Base de datos autogestionada | `r6g.large` (Graviton) | 1 | 2 | 16 | 720 |

**Justificación de la cantidad de nodos worker:**
- Cada pod de cliente (Nginx + PHP‑FPM) consume ~128 MB de RAM.
- Un nodo `t3.large` dispone de 8 GB RAM → capacidad teórica ≈ 60 pods, se limita a 50 por nodo para margen de seguridad y sistema.
- 20 nodos × 50 pods = **1.000 pods** = capacidad perfecta.

**Almacenamiento EBS:**
- Discos raíz: (3 + 20 + 1) × 20 GB = 480 GB (gp3)
- Volúmenes adicionales para clientes (código PHP + logs): 1.000 clientes × 2 GB = 2.000 GB (gp3)
- Volumen `datadir` de MariaDB: 100 GB (gp3)

**Transferencia de datos estimada por cliente:**
- Salida a Internet (tráfico web): 10 GB/mes (sitios pequeños).
- Tráfico interno entre servicios (pods ↔ DB, balanceo, logs): 5 GB/mes, de los cuales ≈10% es cross‑AZ.

---

## 3. Huella de carbono (medioambiental)

### 3.1 Consumo energético de instancias EC2 (24/7, 720 h/mes)

Los valores de consumo medio en watts se basan en mediciones de **Cloud Carbon Footprint** y datos de AWS:

| Instancia | Consumo medio (W) | kWh/h | kWh/mes (720h) | Cantidad | Total kWh/mes |
|-----------|-----------------|-------|----------------|----------|---------------|
| `t3.medium` | 24 | 0,024 | 17,28 | 3 | 51,84 |
| `t3.large` | 38 | 0,038 | 27,36 | 20 | 547,20 |
| `r6g.large` | 30 | 0,030 | 21,60 | 1 | 21,60 |
| **Subtotal EC2** | | | | | **620,64 kWh** |

### 3.2 Consumo de almacenamiento EBS

EBS gp3 tiene un consumo base de **0,0008 kWh por GB-mes** (valor estándar para SSD de uso general, extraído de la calculadora de carbono de Google Cloud adaptada a AWS).

| Concepto | GB-mes | kWh/GB-mes | Total kWh/mes |
|----------|--------|-------------|---------------|
| Discos raíz | 480 | 0,0008 | 0,384 |
| Volúmenes clientes | 2.000 | 0,0008 | 1,600 |
| Datadir MySQL | 100 | 0,0008 | 0,080 |
| **Total EBS** | | | **2,064 kWh** |

### 3.3 Balanceador de carga (NLB) y red interna

- **NLB**: Consumo estimado de 0,005 kWh/h por LCU activa (basado en documentación de AWS sobre huella de red). Para 21 LCU promedio: 21 × 0,005 × 720 = **75,6 kWh**.
- **Overhead de transferencia de datos**: 0,001 kWh por GB transferido internamente (enrutamiento, conmutación). Tráfico interno estimado ≈ 5.000 GB/mes → 5 kWh.

**Total red + NLB:** 75,6 + 5 = **80,6 kWh/mes**.

### 3.4 Total energía mensual

| Componente | kWh/mes |
|------------|---------|
| EC2 | 620,64 |
| EBS | 2,06 |
| NLB + red | 80,60 |
| **Total** | **703,30 kWh** |

### 3.5 Emisiones de CO₂e (región `us-east-1`)

Factor de emisión promedio para **us-east-1** (Norte de Virginia): **0,34 kg CO₂e/kWh** (fuente: EPA eGRID 2024, región RFC East).

- Emisiones mensuales: 703,30 × 0,34 = **239,12 kg CO₂e/mes**
- Emisiones anuales: 239,12 × 12 = **2.869,44 kg CO₂e/año** (≈ 2,87 toneladas)

> **Equivalencia:** 2,87 toneladas CO₂e equivalen a **un coche de gasolina recorriendo ~14.000 km** (0,2 kg CO₂e/km) o a **la huella anual de 0,3 habitantes españoles** (media ~5,5 t CO₂e/persona).

### 3.6 Potencial de reducción de emisiones

| Medida | Reducción estimada | Emisiones finales (anuales) |
|--------|-------------------|-----------------------------|
| Migrar a `us-west-2` (Oregón), factor 0,15 kg CO₂e/kWh | -56% | 1.262 kg CO₂e |
| Usar instancias Graviton (`t4g.large` en lugar de `t3.large`) | -20% en consumo | ~2.295 kg CO₂e |
| Aplicar ambas medidas | ~65% | **~1.000 kg CO₂e** |

---

## 4. Simulación de costes económicos (on‑demand, 24/7)

### 4.1 Instancias EC2 (precios `us-east-1`, mayo 2026)

| Tipo | Cantidad | Precio on‑demand (USD/h) | Horas/mes | Coste mensual (USD) |
|------|----------|--------------------------|-----------|---------------------|
| `t3.medium` | 3 | 0,0416 | 720 | 3 × 0,0416 × 720 = 89,86 |
| `t3.large` | 20 | 0,0832 | 720 | 20 × 0,0832 × 720 = 1.198,08 |
| `r6g.large` | 1 | 0,1008 | 720 | 72,58 |
| **Subtotal EC2** | | | | **1.360,52 USD** |

### 4.2 Almacenamiento EBS (gp3)

| Concepto | GB totales | Precio (USD/GB-mes) | Coste mensual (USD) |
|----------|------------|---------------------|---------------------|
| Discos raíz | 480 | 0,08 | 38,40 |
| Volúmenes clientes | 2.000 | 0,08 | 160,00 |
| Datadir MySQL | 100 | 0,08 | 8,00 |
| **Total EBS** | | | **206,40 USD** |

### 4.3 Transferencia de datos

- **Salida a Internet**: 1.000 clientes × 10 GB = 10.000 GB.  
  Precio primeros 10 TB = 0,09 USD/GB → 9.999 × 0,09 = **899,91 USD** (≈ 900 USD).
- **Tráfico entre Availability Zones (cross‑AZ)**: Tráfico interno total = 5.000 GB/mes. Estimación de 10% cross‑AZ = 500 GB × 0,01 USD/GB = **5 USD**.
- **Total transferencia:** **905 USD**.

### 4.4 Network Load Balancer (NLB)

- **Coste por hora del NLB**: 0,0225 USD/h × 720 h = **16,20 USD**.
- **Unidades de capacidad (LCU)**: Cada LCU procesa 1 GB por hora (actualización 2026, valor estándar). Tráfico total procesado ≈ salida a Internet + tráfico interno = 15.000 GB/mes → tasa media = 20,83 GB/h → 20,83 LCU/h.  
  Coste por LCU/h = 0,006 USD → 20,83 × 0,006 × 720 = **90,00 USD**.
- **Total NLB:** 16,20 + 90,00 = **106,20 USD**.

### 4.5 Monitorización, logs y backups

| Servicio | Detalle | Coste (USD) |
|----------|---------|-------------|
| CloudWatch métricas | 30 métricas extra a 0,30 USD | 9,00 |
| CloudWatch logs | 10 GB logs a 0,50 USD/GB | 5,00 |
| S3 backups | Snapshots EBS + dumps MySQL (500 GB a 0,023 USD/GB) | 11,50 |
| **Total** | | **25,50 USD** |

### 4.6 Resumen coste mensual total (on‑demand, 24/7)

| Categoría | USD/mes |
|-----------|---------|
| EC2 | 1.360,52 |
| EBS | 206,40 |
| Transferencia de datos | 905,00 |
| NLB | 106,20 |
| Monitorización y extras | 25,50 |
| **TOTAL** | **2.603,62 USD** |

- **Coste medio por cliente al mes:** 2.603,62 / 1.000 = **2,60 USD/cliente-mes**.
- **Coste anual total (on‑demand):** 2.603,62 × 12 = **31.243,44 USD**.

### 4.7 Optimizaciones económicas

| Estrategia | Descuento aproximado | Coste mensual optimizado |
|------------|----------------------|--------------------------|
| **Savings Plans (1 año, sin upfront)** | 30% sobre EC2 + NLB | EC2: 1.360,52 × 0,70 = 952,36; NLB: 106,20 × 0,70 = 74,34; EBS+transferencia sin cambio. Total = 952,36 + 206,40 + 905,00 + 74,34 + 25,50 = **2.163,60 USD** → 2,16 USD/cliente |
| **Savings Plans + instancias Graviton** (cambiar `t3.large` → `t4g.large` | 15% adicional sobre cómputo | EC2 ≈ 950 USD × 0,85 = 807,50; total ≈ **1.900 USD** → 1,90 USD/cliente |
| **Uso de Spot para workers** (adicional, solo para cargas tolerantes) | Hasta 70% | Podría bajar a **~1.400 USD/mes**, pero con riesgo de interrupción (no recomendado para producción sin plan de contingencia) |

**Recomendación para producción real:** Aplicar Savings Plans de 1 año e instancias Graviton. Coste objetivo ≈ **2.000 USD/mes (2,00 USD/cliente-mes)**.

---

## 5. Conclusiones integradas (medioambiente + economía)

- **Huella de carbono (24/7, us-east-1):** ~2,87 toneladas CO₂e/año. Migrando a Oregón (`us-west-2`) se reduce a ~1,26 toneladas/año.
- **Coste operativo on‑demand:** 2.603 USD/mes (2,60 USD/cliente). Con Savings Plans + Graviton baja a **~2.000 USD/mes (2,00 USD/cliente)**.
- **La arquitectura escalada es eficiente:** 20 nodos `t3.large` albergan 1.000 pods sin sobredimensionamiento.
- **El modelo de negocio es viable:** Si se cobra al cliente 10 €/mes, el margen bruto mensual es de 10.000 € - 2.600 USD ≈ 7.400 €, suficiente para cubrir personal y beneficios.

**Acciones recomendadas:**
1. Desplegar siempre en regiones con energía limpia (Oregón, norte de Europa).
2. Usar instancias Graviton (t4g, r6g) para reducir coste y emisiones.
3. Comprar Savings Plans de 1 año para cargas estables.
4. Implementar right‑sizing continuo para ajustar el tamaño de los nodos a la carga real.
5. Monitorizar la huella de carbono con **AWS Customer Carbon Footprint Tool**.

---

*Documento elaborado por el equipo de arquitectura del proyecto Kubernetes SaaS. Fecha: 5 de mayo de 2026.*