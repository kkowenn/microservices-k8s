# ArgoCD Demo

A microservices demo project with Kubernetes (Kustomize) and ArgoCD GitOps deployment.

## Architecture

```
User Browser
    │
    ▼
[ Ingress ] (demo.local)
    │
    ├── /      → [ Web Service ] → Node.js (port 8080)
    │                  │
    │             fetch('/api/items')
    │                  │
    └── /api/* → [ API Service ] → Go (port 3000)
                       │
                       ▼
                [ PostgreSQL ] (port 5432)
```

## Services

| Service | Language | Port | Description |
|---------|----------|------|-------------|
| Web | Node.js 20 | 8080 | Frontend HTML UI |
| API | Go 1.22 | 3000 | REST API with PostgreSQL |
| PostgreSQL | 16-alpine | 5432 | Database for items |

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (with Kubernetes enabled)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (optional)

### Install on macOS

```bash
# Install kubectl
brew install kubectl

# Install ArgoCD CLI (optional)
brew install argocd

# Install kustomize (optional, kubectl has it built-in)
brew install kustomize
```

### Install on Ubuntu/Debian

```bash
# kubectl
sudo apt update
sudo apt install -y apt-transport-https ca-certificates curl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update
sudo apt install -y kubectl

# Docker
sudo apt install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER

# ArgoCD CLI (optional)
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# kustomize (optional)
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
```

### Enable Kubernetes (Docker Desktop)

1. Open Docker Desktop
2. Go to **Settings > Kubernetes**
3. Check **Enable Kubernetes**
4. Click **Apply & Restart**
5. Verify: `kubectl cluster-info`

## Quick Start

### One-command setup

```bash
./scripts/setup.sh
```

This will: check prerequisites, build Docker images, deploy to K8s, install ArgoCD, and apply all configs.

### One-command cleanup

```bash
./scripts/cleanup.sh
```

This will: remove all demo apps, namespaces, and optionally ArgoCD + Docker images.

### Manual setup (step by step)

```bash
# 1. Build images
docker build -t api:latest services/api/
docker build -t web:latest services/web/

# 2. Deploy dev environment
kubectl apply -k k8s/overlays/dev
kubectl get pods -n demo-dev

# 3. Access the app
kubectl port-forward svc/web 8080:80 -n demo-dev
# Open http://localhost:8080

# 4. Install ArgoCD (optional)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

# 5. Get ArgoCD password & access UI
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
kubectl port-forward svc/argocd-server 8443:443 -n argocd
# Open https://localhost:8443 (user: admin)

# 6. Apply ArgoCD configs
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/app-dev.yaml
kubectl apply -f argocd/app-staging.yaml
kubectl apply -f argocd/app-prod.yaml
```

## Project Structure

```
argocd-demo/
├── scripts/
│   ├── setup.sh                # One-command setup
│   └── cleanup.sh              # One-command teardown
├── services/
│   ├── api/                    # Go REST API
│   │   ├── main.go
│   │   ├── go.mod
│   │   └── Dockerfile
│   └── web/                    # Node.js frontend
│       ├── server.js
│       └── Dockerfile
├── k8s/
│   ├── base/                   # Shared K8s manifests
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── api-deployment.yaml
│   │   ├── api-service.yaml
│   │   ├── web-deployment.yaml
│   │   ├── web-service.yaml
│   │   ├── ingress.yaml
│   │   ├── postgres-deployment.yaml
│   │   ├── postgres-service.yaml
│   │   ├── postgres-secret.yaml
│   │   ├── postgres-pvc.yaml
│   │   └── postgres-init-configmap.yaml
│   └── overlays/               # Environment-specific overrides
│       ├── dev/                # 1 replica, local images
│       ├── staging/            # 2 replicas, staging images
│       └── prod/               # 3 replicas, versioned images
└── argocd/                     # ArgoCD application configs
    ├── project.yaml
    ├── app-dev.yaml
    ├── app-staging.yaml
    └── app-prod.yaml
```

## Environments

| Environment | Namespace | Replicas | Sync Policy |
|-------------|-----------|----------|-------------|
| Dev | demo-dev | 1 | Auto (prune + self-heal) |
| Staging | demo-staging | 2 | Auto (prune + self-heal) |
| Prod | demo-prod | 3 | Manual |

