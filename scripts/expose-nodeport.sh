#!/usr/bin/env bash
# Exposes the demo frontend-proxy as NodePort 30080 (README section 9.1).
# Rerun after every `helm upgrade` of the demo.
# Usage: ./scripts/expose-nodeport.sh [namespace]   (default: otel-demo)
set -euo pipefail

NS="${1:-otel-demo}"
NODEPORT=30080

kubectl patch svc frontend-proxy -n "$NS" \
  -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":8080,\"targetPort\":8080,\"nodePort\":${NODEPORT}}]}}"

IP=$(minikube ip)
echo "frontend-proxy exposed at http://${IP}:${NODEPORT}"
curl -sI "http://${IP}:${NODEPORT}" | head -1
