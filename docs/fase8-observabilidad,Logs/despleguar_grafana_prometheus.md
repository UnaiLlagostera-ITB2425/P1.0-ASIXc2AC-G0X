# Monitoreo: Despliegue de Prometheus + Grafana

## Objetivo
Desplegar Prometheus y Grafana en el clúster K3s para recolectar métricas de nodos, pods y servicios, y visualizarlas en un dashboard de consumo comercial. El despliegue se realizó de forma incremental: primero Grafana para validar la capa visual, y después Prometheus como recolector de métricas.

## Stack desplegado
| Componente              | Herramienta                        | Namespace      |
| ----------------------- | ---------------------------------- | -------------- |
| Visualización           | Grafana (Helm)                     | `monitoring`   |
| Recolección de métricas | Prometheus (kube-prometheus-stack) | `monitoring`   |
| Certificados TLS        | cert-manager + Let's Encrypt       | `cert-manager` |
| Ingress                 | ingress-nginx                      | `monitoring`   |

## Nodo de despliegue
Tanto Grafana como Prometheus corren en `k8s-submaster`, nodo worker principal del clúster, etiquetado con `role=apps`. El nodo `k8s-master` queda reservado exclusivamente para el plano de control.

```bash
kubectl label nodes k8s-submaster role=apps --overwrite
```

## Grafana
### Instalación
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install grafana grafana/grafana -n monitoring --create-namespace \
  --set persistence.enabled=true \
  --set persistence.size=8Gi \
  --set adminPassword=meu2026strongpass
```

### Ajuste de nodeSelector
```bash
kubectl patch deployment grafana -n monitoring --type='json' -p='[
  {"op": "remove", "path": "/spec/template/spec/nodeSelector/kubernetes.io~1hostname"},
  {"op": "add", "path": "/spec/template/spec/nodeSelector/role", "value": "apps"}
]'

kubectl rollout restart deployment/grafana -n monitoring
```

### Ingress
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  rules:
  - host: grafana.meu-project.me
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 80
  tls:
  - hosts:
    - grafana.meu-project.me
    secretName: grafana-tls
```

### Verificación
```bash
kubectl get pods -n monitoring -o wide
kubectl get svc -n monitoring
kubectl get ingress -n monitoring
kubectl get certificate -n monitoring
```

---

## Prometheus
> **Estado:** Pendiente de integración. Se desplegará una vez resuelto el acceso HTTPS saliente del nodo `k8s-submaster`.

### Values preparados
Ubicación: `~/saas-hosting/k8s/monitoring/kube-prometheus-values.yaml`

```yaml
grafana:
  enabled: false

prometheus:
  prometheusSpec:
    retention: 10d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: "local-path"
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi

alertmanager:
  enabled: false

prometheusOperator:
  admissionWebhooks:
    enabled: false

kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
```

### Instalación (pendiente)
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f ~/saas-hosting/k8s/monitoring/kube-prometheus-values.yaml \
  --timeout=10m0s
```

### Verificación (pendiente)
```bash
kubectl get pods -n monitoring -o wide
kubectl get pvc -n monitoring
```

## Estado
- Grafana desplegado y corriendo en `k8s-submaster`
- Ingress `grafana.meu-project.me` configurado
- Certificado TLS pendiente — Security Group del `k8s-submaster` sin salida `TCP 443`
- Prometheus pendiente de despliegue — values preparados en `k8s/monitoring/`
- Dashboard de consumo pendiente — se configura tras integrar Prometheus