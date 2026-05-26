#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
STORAGE_TOPOLOGY="${STORAGE_TOPOLOGY:-block-4-2}"

log() {
    echo "[INFO] $*"
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"
}

need_cmd kubectl
need_cmd helm

log "Checking Kubernetes cluster..."
kubectl cluster-info >/dev/null

log "Current nodes:"
kubectl get nodes -o wide

log "Current StorageClasses:"
kubectl get storageclass || true

log "Adding YDB Helm repository..."
helm repo add ydb https://charts.ydb.tech/ >/dev/null 2>&1 || true
helm repo update

log "Installing YDB operator..."
helm upgrade --install ydb-operator ydb/ydb-operator \
  --namespace "$NAMESPACE"

log "Waiting for YDB operator pod..."
kubectl wait \
  --namespace "$NAMESPACE" \
  --for=condition=Ready pod \
  -l app.kubernetes.io/name=ydb-operator \
  --timeout=180s || true

log "Deploying YDB storage nodes..."

case "$STORAGE_TOPOLOGY" in
    block-4-2)
        kubectl apply -n "$NAMESPACE" \
          -f https://raw.githubusercontent.com/ydb-platform/ydb-kubernetes-operator/master/samples/storage-block-4-2.yaml
        ;;
    mirror-3-dc)
        kubectl apply -n "$NAMESPACE" \
          -f https://raw.githubusercontent.com/ydb-platform/ydb-kubernetes-operator/master/samples/storage-mirror-3dc.yaml
        ;;
    *)
        die "Unknown STORAGE_TOPOLOGY=$STORAGE_TOPOLOGY. Use block-4-2 or mirror-3-dc."
        ;;
esac

log "Waiting for Storage resource to become Ready..."
log "This can take several minutes."

until kubectl get storage.ydb.tech storage-sample -n "$NAMESPACE" \
    -o jsonpath='{.status.state}' 2>/dev/null | grep -q "Ready"; do
    kubectl get storage.ydb.tech -n "$NAMESPACE" || true
    kubectl get pods -n "$NAMESPACE" | grep -E 'storage|ydb' || true
    sleep 10
done

log "Storage is Ready."

log "Deploying YDB database and dynamic nodes..."
kubectl apply -n "$NAMESPACE" \
  -f https://raw.githubusercontent.com/ydb-platform/ydb-kubernetes-operator/master/samples/database.yaml

log "Waiting for Database resource to become Ready..."

until kubectl get database.ydb.tech database-sample -n "$NAMESPACE" \
    -o jsonpath='{.status.state}' 2>/dev/null | grep -q "Ready"; do
    kubectl get database.ydb.tech -n "$NAMESPACE" || true
    kubectl get pods -n "$NAMESPACE" | grep -E 'database|storage|ydb' || true
    sleep 10
done

log "Database is Ready."

log "Cluster pods:"
kubectl get pods -n "$NAMESPACE"

log "Services:"
kubectl get svc -n "$NAMESPACE"

cat <<EOF

YDB has been deployed.

Inside Kubernetes:
  endpoint: grpc://database-sample-grpc:2135
  database: /Root/database-sample

From host:
  kubectl port-forward -n $NAMESPACE svc/database-sample-grpc 2135:2135

Then connect:
  grpc://localhost:2135/Root/database-sample

Test from inside Kubernetes:
  kubectl run -it --image=cr.yandex/crptqonuodf51kdj7a7d/ydb:24.4.4.2 --rm ydb-cli bash

Inside pod:
  /opt/ydb/bin/ydb \\
    --endpoint grpc://database-sample-grpc:2135 \\
    --database /Root/database-sample \\
    sql -s 'SELECT 2 + 2;'

EOF
