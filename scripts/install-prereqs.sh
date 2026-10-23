#!/usr/bin/env bash
# Installs Docker Engine, minikube, kubectl, Helm and git on Ubuntu (README sections 4 and 5).
# Usage: ./scripts/install-prereqs.sh
set -euo pipefail

echo "==> Removing conflicting packages"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" 2>/dev/null || true
done

echo "==> Configuring the official Docker repository"
sudo apt-get update
sudo apt-get install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOT
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOT
sudo apt-get update

if ! apt-cache policy docker-ce | grep -q "Candidate: [0-9]"; then
  echo "ERROR: docker-ce is not available for ${CODENAME}. Check the apt-get update output." >&2
  exit 1
fi

echo "==> Installing Docker"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"

echo "==> Installing minikube"
curl -fsSLo /tmp/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install /tmp/minikube /usr/local/bin/minikube && rm /tmp/minikube

echo "==> Installing kubectl"
KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && rm /tmp/kubectl

echo "==> Installing Helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo
echo "Installation complete."
echo "Log out and back in over SSH (or run 'newgrp docker'), then verify with:"
echo "  docker run hello-world"
echo "  minikube version && kubectl version --client && helm version"
