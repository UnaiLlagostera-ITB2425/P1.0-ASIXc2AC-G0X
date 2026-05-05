#!/bin/bash
# =============================================================================
# 02-init-cluster.sh
# Inicializar el clúster Kubernetes en el Master
# Ejecutar como usuario ubuntu (con sudo cuando sea necesario)
# =============================================================================

set -euo pipefail
MASTER_IP="10.0.1.204"
POD_CIDR="192.168.0.0/16"      # Calico
SERVICE_CIDR="10.96.0.0/12"

echo "======================================================"
echo " PASO 1 — Inicializar clúster con kubeadm"
echo "======================================================"

sudo kubeadm init \
  --apiserver-advertise-address=${MASTER_IP} \
  --pod-network-cidr=${POD_CIDR} \
  --service-cidr=${SERVICE_CIDR} \
  --node-name=k8s-master 2>&1 | tee ~/kubeadm-init.log

echo ""
echo "======================================================"
echo " PASO 2 — Configurar kubectl para el usuario ubuntu"
echo "======================================================"

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verificar nodo
kubectl get nodes

echo ""
echo "======================================================"
echo " PASO 3 — Instalar CNI Calico"
echo "======================================================"

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

echo "Esperando a que Calico esté listo (60s)..."
sleep 60
kubectl get pods -n kube-system | grep calico

echo ""
echo "======================================================"
echo " PASO 4 — Guardar el join command para el Worker"
echo "======================================================"

# El join command está al final del kubeadm init output
grep -A 2 "kubeadm join" ~/kubeadm-init.log > ~/worker-join-command.txt
cat ~/worker-join-command.txt

echo ""
echo "⚠️  Guarda el join command de arriba — lo necesita Unai para el Worker"
echo "✅ Clúster inicializado. Continúa con: 03-addons.sh"
