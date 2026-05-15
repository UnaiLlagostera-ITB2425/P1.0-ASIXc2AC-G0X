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

Grafana se instaló de forma independiente para validar el acceso web y la persistencia básica, mientras que Prometheus se preparó como parte del stack de monitorización del clúster.


## Entorno de despliegue
El despliegue se realizó en el clúster K3s, usando monitoring como namespace dedicado para separar los recursos de observabilidad del resto de servicios.

Para el almacenamiento, se confirmó que local-path quedara como StorageClass por defecto, mientras que nfs-client se mantuvo solo como provisioner para otros usos del proyecto.

Esto permitió que Grafana y Prometheus usaran volúmenes locales sin depender del NFS compartido.

## Nodo de despliegue
Tanto Grafana como Prometheus corren en `k8s-submaster`, nodo worker principal del clúster, etiquetado con `role=apps`. El nodo `k8s-master` queda reservado exclusivamente para el plano de control.

```bash
kubectl label nodes k8s-submaster role=apps --overwrite
```

## Grafana
Grafana se instaló primero con Helm, usando un adminPassword definido y persistencia activada para validar la interfaz y el acceso inicial.

Durante la prueba, el PVC quedó en estado Pending cuando la persistencia estaba activada, por lo que se realizó una instalación temporal sin persistencia para confirmar que el pod arrancaba correctamente.

Una vez verificado el acceso, Grafana quedó funcionando y fue accesible mediante port-forward desde el nodo donde se ejecutó el comando.


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

## Prometheus
Prometheus se desplegó mediante kube-prometheus-stack con una configuración mínima, ajustada a los recursos del clúster y con almacenamiento persistente sobre local-path para evitar dependencias del NFS compartido. Se redujo la configuración al núcleo necesario para mantener el stack estable, desactivando componentes no esenciales del operador y priorizando la recogida de métricas básicas del clúster para alimentar el dashboard de consumo comercial.

> **Estado:** Desplegado y operativo dentro de `kube-prometheus-stack`.

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

### Instalación
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
- Grafana desplegado y accesible en grafana.meu-project.me.
- Prometheus desplegado en el namespace monitoring con retención de 10 días y PVC sobre local-path.
- monitoring usado como namespace único para el stack de monitorización.
- El dashboard de consumo comercial queda alimentado por las métricas de Prometheus y visualizado en Grafana.

