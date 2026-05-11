# Centralización de Logs: Loki + Promtail
## Objetivo
Centralizar los logs de pods, Ingress y sistema del clúster en Loki, con Promtail como agente recolector en cada nodo. Grafana actúa como frontend de consulta una vez integrado Loki como datasource.

## Por qué Loki + Promtail
ELK fue descartado por su alto consumo de memoria, incompatible con las instancias `t3.small` del clúster. Loki indexa solo metadatos y no el contenido de los logs, lo que lo hace adecuado para este entorno con RAM limitada. Promtail es el agente oficial de Loki, se despliega como DaemonSet y recoge logs directamente de `/var/log/pods/`.

## Stack desplegado
| Componente             | Herramienta                  | Nodo            |
| ---------------------- | ---------------------------- | --------------- |
| Almacenamiento de logs | Loki `3.6.7` (SingleBinary)  | `k8s-submaster` |
| Agente recolector      | Promtail `3.5.1` (DaemonSet) | `k8s-submaster` + `worker1` |
| Visualización          | Grafana (ya desplegado)      | `k8s-submaster` |


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
El service discovery de Kubernetes fue desactivado en Promtail porque el nodo `k8s-submaster` no tiene acceso al API server (`10.96.0.1:443`). Los logs se recogen directamente de `/var/log/pods/` mediante `static_configs`.

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

## Verificación
```bash
kubectl get pods -n monitoring -o wide
kubectl logs -n monitoring loki-0
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail
```

## Integración con Grafana
Pendiente de realizar una vez Grafana sea accesible vía HTTPS:

1. **Connections → Data sources → Add new data source → Loki**
2. URL: `http://loki.monitoring.svc.cluster.local:3100`
3. Save & Test → `Data source connected`

## Estado
- Loki desplegado en modo SingleBinary en `k8s-submaster` con persistencia `local-path`
- Promtail corriendo como DaemonSet en `k8s-submaster` y `worker1`
- Logs de pods y Nginx-Ingress recolectados via ficheros estáticos
- Integración Loki datasource en Grafana pendiente — requiere acceso HTTPS a Grafana