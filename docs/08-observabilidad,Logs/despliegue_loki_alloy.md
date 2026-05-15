# Centralización de Logs: Loki + Alloy

## Objetivo
Centralizar los logs de pods, Ingress y sistema del clúster en Loki, con Alloy como agente recolector en cada nodo. Grafana actúa como frontend de consulta una vez integrado Loki como datasource.

## Por qué Loki + Promtail
ELK fue descartado por su alto consumo de memoria, incompatible con las instancias `t3.small` del clúster. Loki indexa solo metadatos y no el contenido de los logs, lo que lo hace adecuado para este entorno con RAM limitada. En la fase inicial se utilizó Promtail como agente de recogida de logs porque permitía validar rápidamente el flujo de ingestión hacia Loki.

## Stack desplegado
| Componente             | Herramienta             | Nodo                    |
| ---------------------- | ----------------------- | ----------------------- |
| Almacenamiento de logs | Loki 3.6.7              | k8s-submaster           |
| Agente recolector      | Promtail 3.5.1 / Alloy  | k8s-submaster + workers |
| Visualización          | Grafana                 | k8s-submaster           |

## Loki
### Values
Ubicación: `~/saas-hosting/k8s/monitoring/loki-values.yaml`
```yaml
deploymentMode: SingleBinary

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

singleBinary:
  replicas: 1
  nodeSelector:
    role: apps
  persistence:
    enabled: true
    storageClass: local-path
    size: 10Gi

gateway:
  enabled: false

chunksCache:
  enabled: false

resultsCache:
  enabled: false

monitoring:
  selfMonitoring:
    enabled: false
  lokiCanary:
    enabled: false

sidecar:
  rules:
    enabled: false

test:
  enabled: false

backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
```

### Instalación
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  -f ~/saas-hosting/k8s/monitoring/loki-values.yaml \
  --timeout=10m0s
```

## Promtail
La primera versión del stack usó Promtail como DaemonSet para recoger logs directamente de `/var/log/pods/` y enviarlos a Loki. El service discovery de Kubernetes se desactivó porque el nodo `k8s-submaster` no tenía acceso al API server (`10.96.0.1:443`), así que la recogida se apoyó en `static_configs`.

### Values
Ubicación: `~/saas-hosting/k8s/monitoring/promtail-values.yaml`
```yaml
config:
  clients:
    - url: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push

  snippets:
    pipelineStages:
      - docker: {}

    scrapeConfigs: |
      - job_name: kubernetes-pods-static
        static_configs:
          - labels:
              job: kubernetes-pods
              __path__: /var/log/pods/*/*/*.log

      - job_name: nginx-access
        static_configs:
          - labels:
              job: nginx-access
              __path__: /var/log/containers/*ingress-nginx*.log
```

### Instalación
```bash
helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  -f ~/saas-hosting/k8s/monitoring/promtail-values.yaml \
  --timeout=5m0s
```

### Verificación
```bash
kubectl get pods -n monitoring -o wide
kubectl logs -n monitoring loki-0
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail
```

## Por qué se descartó Promtail
Promtail se descartó porque Grafana lo dejó en fase de deprecación y el camino recomendado para nuevos despliegues pasó a ser Alloy. Además, ya existía una migración preparada con `alloy convert`, así que mantener Promtail no aportaba ventajas frente a la nueva configuración. Por eso se eliminó el DaemonSet antiguo y se sustituyó por Alloy manteniendo Loki sin cambios.

## Alloy
La configuración nueva usa Grafana Alloy como agente unificado para recoger logs y enviarlos a Loki. El despliegue se aplicó como `DaemonSet` en el namespace `monitoring`, con descubrimiento de Kubernetes, relabeling de labels útiles y envío a Loki mediante `loki.write`.

### Despliegue
```bash
bash manifests/delete-promtail.sh
kubectl apply -f manifests/alloy-logs.yaml
```

### Verificación
```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy -o wide
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=100
```

### Flujo de Alloy
- `discovery.kubernetes` detecta los pods.
- `discovery.relabel` añade labels útiles como `namespace`, `pod`, `container` y `app`.
- `loki.write` envía los logs a `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`.

## Integración con Grafana
Pendiente de realizar una vez Grafana sea accesible vía HTTPS:

1. **Connections → Data sources → Add new data source → Loki**
2. URL: `http://loki.monitoring.svc.cluster.local:3100`
3. Save & Test → `Data source connected`

## Estado
- Loki desplegado correctamente en k8s-submaster con persistencia local-path.
- Promtail se utilizó inicialmente para validar la recogida de logs.
- Alloy sustituyó a Promtail como agente final de logs.
- La integración con Grafana queda lista para usar una vez se añada el datasource, y el despliegue y la recolección ya están validados.