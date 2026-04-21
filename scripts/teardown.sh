#!/usr/bin/env bash
# Tear down the full Strimzi Kafka + monitoring stack.
# Removes Helm releases, CRs, namespaces, and optionally the k3d cluster.
set -euo pipefail

NS_KAFKA="kafka"
NS_MONITORING="monitoring"
PASS=0
FAIL=0

step() { echo ""; echo "==> $1"; }
ok()   { echo "  [OK]  $1"; PASS=$((PASS + 1)); }
skip() { echo "  [--]  $1 (skipping)"; }
fail() { echo "  [ERR] $1"; FAIL=$((FAIL + 1)); }

# Run kubectl tolerating connection-refused (cluster may be partially down)
kube() { kubectl "$@" 2>/dev/null || true; }

# ── Safety check ─────────────────────────────────────────────────────────────
step "Verifying cluster context..."
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "none")
echo "    Current context: $CURRENT_CTX"

if [[ "$CURRENT_CTX" != "docker-desktop" && "$CURRENT_CTX" != k3d-* ]]; then
  echo ""
  echo "  WARNING: context '$CURRENT_CTX' is not docker-desktop or k3d-*"
  echo "  This script will DELETE namespaces, Helm releases, and CRDs."
  read -rp "  Continue? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ── Kill any lingering port-forwards ─────────────────────────────────────────
step "Killing port-forward processes (Grafana, Prometheus, Schema Registry)..."
for port in 3000 3001 8081 9090 9091 9308; do
  pids=$(lsof -ti :"$port" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    echo "$pids" | xargs kill -9 2>/dev/null || true
    ok "Killed process(es) on :$port (PIDs: $pids)"
  fi
done

# ── Clean up leftover test pods ───────────────────────────────────────────────
step "Removing leftover test/load pods from namespace: $NS_KAFKA..."
for pod in kafka-e2e kafka-producer-payments kafka-producer-inventory \
           kafka-producer-burst kafka-consumer-payments kafka-consumer-inventory \
           kafka-path-check kafka-lag-check kafka-check kafka-groups \
           kafka-offsets net-test; do
  if kube get pod "$pod" -n "$NS_KAFKA" | grep -q "$pod"; then
    kube delete pod "$pod" -n "$NS_KAFKA" --ignore-not-found
    ok "Deleted pod/$pod"
  fi
done

# ── Remove Kafka custom resources (operator deletes pods gracefully) ──────────
step "Removing KafkaConnector CRs..."
if kube get kafkaconnector -n "$NS_KAFKA" | grep -qv "^NAME"; then
  kube delete kafkaconnector --all -n "$NS_KAFKA" --ignore-not-found
  ok "KafkaConnectors deleted"
else
  skip "KafkaConnectors (none found)"
fi

step "Removing KafkaConnect CR..."
if kube get kafkaconnect production-connect -n "$NS_KAFKA" | grep -q production-connect; then
  kube delete kafkaconnect production-connect -n "$NS_KAFKA" --ignore-not-found
  ok "KafkaConnect deleted"
else
  skip "KafkaConnect (not found)"
fi

step "Removing KafkaTopic CRs..."
if kube get kafkatopic -n "$NS_KAFKA" | grep -qv "^NAME"; then
  kube delete kafkatopic --all -n "$NS_KAFKA" --ignore-not-found
  ok "KafkaTopics deleted"
else
  skip "KafkaTopics (none found)"
fi

step "Removing KafkaUser CRs..."
if kube get kafkauser -n "$NS_KAFKA" | grep -qv "^NAME"; then
  kube delete kafkauser --all -n "$NS_KAFKA" --ignore-not-found
  ok "KafkaUsers deleted"
else
  skip "KafkaUsers (none found)"
fi

step "Removing Kafka + KafkaNodePool CRs..."
kube delete kafka production-kafka  -n "$NS_KAFKA" --ignore-not-found && ok "Kafka CR deleted"       || skip "Kafka CR (not found)"
kube delete kafkanodepool --all     -n "$NS_KAFKA" --ignore-not-found && ok "KafkaNodePools deleted"  || skip "KafkaNodePools (none found)"

# ── Wait for broker pods to terminate ────────────────────────────────────────
step "Waiting for Kafka broker pods to terminate (up to 120s)..."
if kube get pods -n "$NS_KAFKA" -l strimzi.io/cluster=production-kafka --no-headers | grep -q .; then
  kubectl wait pods -n "$NS_KAFKA" \
    -l strimzi.io/cluster=production-kafka \
    --for=delete --timeout=120s 2>/dev/null && ok "Broker pods terminated" || fail "Broker pods did not terminate in time"
else
  ok "No broker pods found"
fi

# ── Uninstall Strimzi Helm release ───────────────────────────────────────────
step "Uninstalling Strimzi Helm release..."
if helm status strimzi-kafka-operator -n "$NS_KAFKA" &>/dev/null; then
  helm uninstall strimzi-kafka-operator -n "$NS_KAFKA"
  ok "Strimzi operator uninstalled"
else
  skip "Strimzi Helm release (not found)"
fi

# ── Remove monitoring CRs ────────────────────────────────────────────────────
step "Removing PrometheusRule CRs..."
kube delete prometheusrule kafka-alerts -n "$NS_MONITORING" --ignore-not-found && ok "PrometheusRule deleted" || skip "PrometheusRule (not found)"

step "Removing ServiceMonitor CRs..."
kube delete servicemonitor \
  kafka-servicemonitor kafka-connect-servicemonitor kafka-exporter-servicemonitor \
  -n "$NS_MONITORING" --ignore-not-found && ok "ServiceMonitors deleted" || skip "ServiceMonitors (not found)"

step "Removing Grafana dashboard and datasource ConfigMaps..."
kube delete configmap \
  grafana-dashboard-strimzi-kafka \
  grafana-dashboard-strimzi-kafka-exporter \
  grafana-dashboard-strimzi-kafka-connect \
  grafana-dashboard-strimzi-operators \
  grafana-datasource-prometheus \
  -n "$NS_MONITORING" --ignore-not-found && ok "Grafana ConfigMaps deleted" || skip "Grafana ConfigMaps (not found)"

step "Removing AlertManagerConfig CRs..."
kube delete alertmanagerconfig --all -n "$NS_MONITORING" --ignore-not-found && ok "AlertManagerConfigs deleted" || skip "AlertManagerConfig (none found)"

# ── Uninstall kube-prometheus-stack ──────────────────────────────────────────
step "Uninstalling kube-prometheus-stack Helm release..."
if helm status kube-prometheus-stack -n "$NS_MONITORING" &>/dev/null; then
  helm uninstall kube-prometheus-stack -n "$NS_MONITORING"
  ok "kube-prometheus-stack uninstalled"
else
  skip "kube-prometheus-stack Helm release (not found)"
fi

# ── Remove PVCs ───────────────────────────────────────────────────────────────
step "Removing PersistentVolumeClaims in $NS_KAFKA..."
pvcs=$(kube get pvc -n "$NS_KAFKA" --no-headers -o name)
if [[ -n "$pvcs" ]]; then
  kube delete pvc --all -n "$NS_KAFKA"
  ok "PVCs deleted in $NS_KAFKA"
else
  skip "No PVCs in $NS_KAFKA"
fi

step "Removing PersistentVolumeClaims in $NS_MONITORING..."
pvcs=$(kube get pvc -n "$NS_MONITORING" --no-headers -o name)
if [[ -n "$pvcs" ]]; then
  kube delete pvc --all -n "$NS_MONITORING"
  ok "PVCs deleted in $NS_MONITORING"
else
  skip "No PVCs in $NS_MONITORING"
fi

# ── Remove NetworkPolicies ────────────────────────────────────────────────────
step "Removing NetworkPolicies..."
kube delete networkpolicy --all -n "$NS_KAFKA"      --ignore-not-found && ok "kafka NetworkPolicies deleted"      || skip "kafka NetworkPolicies (none)"
kube delete networkpolicy --all -n "$NS_MONITORING" --ignore-not-found && ok "monitoring NetworkPolicies deleted" || skip "monitoring NetworkPolicies (none)"

# ── Remove Strimzi CRDs ───────────────────────────────────────────────────────
step "Removing Strimzi CRDs..."
strimzi_crds=$(kube get crd -o name | grep strimzi || true)
if [[ -n "$strimzi_crds" ]]; then
  echo "$strimzi_crds" | xargs kubectl delete 2>/dev/null || true
  ok "Strimzi CRDs removed"
else
  skip "Strimzi CRDs (not found)"
fi

# ── Remove Prometheus Operator CRDs ──────────────────────────────────────────
step "Removing Prometheus Operator CRDs..."
prom_crds=$(kube get crd -o name | grep monitoring.coreos.com || true)
if [[ -n "$prom_crds" ]]; then
  echo "$prom_crds" | xargs kubectl delete 2>/dev/null || true
  ok "Prometheus Operator CRDs removed"
else
  skip "Prometheus Operator CRDs (not found)"
fi

# ── Delete namespaces ─────────────────────────────────────────────────────────
step "Deleting namespace: $NS_KAFKA..."
if kube get namespace "$NS_KAFKA" | grep -q "$NS_KAFKA"; then
  kubectl delete namespace "$NS_KAFKA" 2>/dev/null || true
  ok "Namespace $NS_KAFKA deleted"
else
  skip "Namespace $NS_KAFKA (not found)"
fi

step "Deleting namespace: $NS_MONITORING..."
if kube get namespace "$NS_MONITORING" | grep -q "$NS_MONITORING"; then
  kubectl delete namespace "$NS_MONITORING" 2>/dev/null || true
  ok "Namespace $NS_MONITORING deleted"
else
  skip "Namespace $NS_MONITORING (not found)"
fi

# ── Destroy k3d cluster ───────────────────────────────────────────────────────
echo ""
read -rp "==> Delete the k3d cluster 'kafka-local' entirely? [y/N] " destroy_cluster
if [[ "$destroy_cluster" =~ ^[Yy]$ ]]; then
  if k3d cluster list 2>/dev/null | grep -q "kafka-local"; then
    k3d cluster delete kafka-local
    ok "k3d cluster 'kafka-local' deleted"
  else
    skip "k3d cluster 'kafka-local' (not found)"
  fi
else
  echo "  [--]  k3d cluster kept."
  echo "        Re-install with:  bash scripts/install.sh"
  echo "        Or recreate with: k3d cluster create kafka-local --image rancher/k3s:v1.31.6-k3s1 --servers 1 --agents 3"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " Teardown complete: $PASS steps OK, $FAIL failed"
echo "======================================================"
if [[ $FAIL -gt 0 ]]; then
  echo " Some steps failed — check output above."
  exit 1
fi
