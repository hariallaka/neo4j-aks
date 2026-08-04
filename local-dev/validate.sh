#!/usr/bin/env bash
# Validates the Kubernetes/Helm/Istio layer of terraform/neo4j.tf and
# terraform/ingress.tf against a local kind cluster. Does NOT validate
# anything Azure-specific (AKS control plane, Key Vault, Azure LB, Azure AD
# RBAC, real VM node pools) -- there is no local emulator for those; the
# closest you get is `terraform validate`/`terraform plan` against real
# Azure credentials.
#
# NOT run in the sandbox that authored this -- it had no docker daemon, no
# kind/kubectl/helm/istioctl installed, and no network path to any of the
# registries this script needs (registry.terraform.io, helm.neo4j.com,
# Docker Hub, istio.io). Review it before trusting it; report back what
# breaks.
#
# Usage:
#   ./validate.sh up       # create the kind cluster, install everything, verify
#   ./validate.sh down     # delete the kind cluster
#   ./validate.sh status   # re-print the verification summary for an existing run
#
# Env vars:
#   NEO4J_HELM_REPO_URL   default https://helm.neo4j.com/neo4j -- point at an
#                         internal mirror the same way terraform's
#                         neo4j_helm_repo_url would (see README's proxy-cache note)
#   SKIP_ISTIO=1          skip installing Istio and applying the Gateway/
#                         VirtualService manifests (just validates the neo4j
#                         chart/clustering layer)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="neo4j-aks-local"
NAMESPACE="neo4j"
NEO4J_HELM_REPO_URL="${NEO4J_HELM_REPO_URL:-https://helm.neo4j.com/neo4j}"
CLUSTER_SIZE=3

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH -- install it before running this script."
}

cmd_up() {
  require docker
  require kind
  require kubectl
  require helm

  log "Preflight: checking Docker is actually running"
  docker info >/dev/null 2>&1 || die "Docker daemon isn't reachable -- start Docker Desktop/colima/etc. first."

  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "kind cluster '$CLUSTER_NAME' already exists, reusing it (run './validate.sh down' first for a clean run)"
  else
    log "Creating kind cluster with taints/labels mirroring workloadsize=small|large"
    kind create cluster --config "$SCRIPT_DIR/kind-cluster.yaml"
  fi

  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

  log "Node labels/taints (confirm these landed -- should show workloadsize=small|large, one per worker)"
  kubectl get nodes -o custom-columns='NAME:.metadata.name,LABELS:.metadata.labels,TAINTS:.spec.taints'

  log "Adding the neo4j Helm repo ($NEO4J_HELM_REPO_URL)"
  helm repo add neo4j "$NEO4J_HELM_REPO_URL" >/dev/null 2>&1 || helm repo add neo4j "$NEO4J_HELM_REPO_URL"
  helm repo update >/dev/null

  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

  # A disposable password for this throwaway cluster only -- never reuse
  # this pattern for anything that isn't `kind delete cluster`-able.
  NEO4J_PASSWORD="$(openssl rand -hex 16 2>/dev/null || echo 'localValidationOnly123')"

  log "Installing $CLUSTER_SIZE neo4j cluster members (edition=enterprise, acceptLicenseAgreement=eval -- no real license needed for this)"
  for i in $(seq 0 $((CLUSTER_SIZE - 1))); do
    helm upgrade --install "neo4j-aks-local-$i" neo4j/neo4j \
      --namespace "$NAMESPACE" \
      -f "$SCRIPT_DIR/values/neo4j-values.yaml" \
      --set neo4j.password="$NEO4J_PASSWORD" \
      --wait --timeout 10m
  done

  log "Verifying the cluster actually formed (SHOW SERVERS via cypher-shell in the first pod)"
  kubectl -n "$NAMESPACE" exec "neo4j-aks-local-0-0" -- \
    cypher-shell -a bolt://localhost:7687 -u neo4j -p "$NEO4J_PASSWORD" "SHOW SERVERS;" \
    || warn "Couldn't run SHOW SERVERS -- check the pod name (helm's StatefulSet naming may differ) and pod readiness manually: kubectl -n $NAMESPACE get pods"

  log "PodDisruptionBudget (expect maxUnavailable matching (cluster_size-1)/2 -- create this by hand for local testing, terraform's kubernetes_pod_disruption_budget_v1 isn't reproduced here since it's a plain PDB resource, not a chart -- see README)"
  kubectl -n "$NAMESPACE" get pdb || true

  if [[ "${SKIP_ISTIO:-0}" == "1" ]]; then
    log "SKIP_ISTIO=1 set -- skipping Istio Gateway/VirtualService"
  else
    if command -v istioctl >/dev/null 2>&1; then
      if ! kubectl get namespace istio-system >/dev/null 2>&1; then
        log "Installing Istio (demo profile -- includes a real ingress gateway matching the default selector)"
        istioctl install --set profile=demo -y
      else
        log "istio-system namespace already exists, assuming Istio is already installed"
      fi
    else
      warn "istioctl not found -- applying the Gateway/VirtualService anyway will fail with 'no matches for kind Gateway' since Istio's CRDs aren't installed. Install istioctl (https://istio.io/latest/docs/setup/getting-started/) to actually validate these, or leave this as a documented gap."
    fi

    log "Applying Gateway + VirtualService"
    kubectl apply -f "$SCRIPT_DIR/manifests/gateway.yaml"
    kubectl apply -f "$SCRIPT_DIR/manifests/virtualservice.yaml"

    log "Gateway/VirtualService status"
    kubectl -n "$NAMESPACE" get gateway,virtualservice
  fi

  cmd_status
  log "Done. Cluster left running -- './validate.sh down' to tear it down, './validate.sh status' to re-check it later."
}

cmd_status() {
  log "Summary"
  kubectl -n "$NAMESPACE" get pods -o wide 2>/dev/null || warn "namespace $NAMESPACE not found -- run './validate.sh up' first"
  kubectl -n "$NAMESPACE" get pvc,svc 2>/dev/null || true
}

cmd_down() {
  require kind
  log "Deleting kind cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  *)      echo "Usage: $0 {up|down|status}"; exit 1 ;;
esac
