#!/bin/bash
# =============================================================================
# 01-setup-master.sh
# Instalación base del nodo Master Kubernetes
# EC2-MASTER (Erick) — IP privada: 10.0.1.204 | IP pública: 54.144.217.31
# Ubuntu 24.04 LTS — t3.small
# =============================================================================

set -euo pipefail
echo "======================================================"
echo " PASO 1 — Preparación del sistema"
echo "======================================================"

# Actualizar sistema
sudo apt-get update -y && sudo apt-get upgrade -y

# Hostname
sudo hostnamectl set-hostname k8s-master
echo "127.0.0.1  k8s-master" | sudo tee -a /etc/hosts

# Deshabilitar swap (requerido por Kubernetes)
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Módulos del kernel necesarios
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Parámetros de red del kernel
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

echo ""
echo "======================================================"
echo " PASO 2 — Instalación de containerd"
echo "======================================================"

# Instalar dependencias
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Repositorio Docker (contiene containerd)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y containerd.io

# Configurar containerd con systemd cgroup driver
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

echo ""
echo "======================================================"
echo " PASO 3 — Instalación de kubeadm, kubelet, kubectl"
echo "======================================================"

sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable kubelet

echo ""
echo "======================================================"
echo " PASO 4 — Instalación de Docker (para builds)"
echo "======================================================"

sudo apt-get install -y docker-ce docker-ce-cli docker-compose-plugin
sudo usermod -aG docker ubuntu
sudo systemctl enable docker

echo ""
echo "✅ Sistema preparado. Continúa con: 02-init-cluster.sh"
