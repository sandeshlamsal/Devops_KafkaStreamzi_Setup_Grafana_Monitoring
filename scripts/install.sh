#!/usr/bin/env bash
# Full install on docker-desktop cluster
set -euo pipefail

STRIMZI_VERSION="0.44.0"
PROMETHEUS_STACK_VERSION="58.0.0"
NS_KAFKA="kafka"
NS_MONITORING="monitoring"

echo "==> Verifying docker-desktop context..."
CURRENT_CTX=$(kubectl config current-context)
if [[ "$CURRENT_CTX" != "docker-desktop" ]]; then
  echo "ERROR: current context is '$CURRENT_CTX', expected 'docker-desktop'"
  echo "Run: kubectl config use-context docker-desktop"
  exit 1
fi
echo "    Context OK: $CURRENT_CTX"

echo "==> Creating namespaces..."
kubectl create namespace $NS_KAFKA      --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $NS_MONITORING --dry-run=client -o yaml | kubectl apply -f -

echo "==> Applying JMX metrics ConfigMap..."
kubectl apply -f monitoring/prometheus/kafka-metrics-configmap.yaml

echo "==> Installing Strimzi operator (v$STRIMZI_VERSION)..."
helm repo add strimzi https://strimzi.io/charts/ --force-update
helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace $NS_KAFKA \
  --version $STRIMZI_VERSION \
  --set watchNamespaces="{$NS_KAFKA}" \
  --set resources.requests.memory=256Mi \
  --set resources.requests.cpu=100m \
  --set resources.limits.memory=512Mi \
  --set resources.limits.cpu=500m \
  --wait --timeout 3m

echo "==> Deploying Kafka cluster (KRaft mode)..."
kubectl apply -f strimzi/cluster/node-pool.yaml  -n $NS_KAFKA
kubectl apply -f strimzi/cluster/kafka-cluster.yaml -n $NS_KAFKA

echo "    Waiting for Kafka cluster to become Ready (up to 10 min)..."
kubectl wait kafka/production-kafka \
  --for=condition=Ready \
  --timeout=600s \
  -n $NS_KAFKA

echo "==> Applying KafkaTopics..."
kubectl apply -f strimzi/topics/ -n $NS_KAFKA

echo "==> Applying KafkaUsers..."
kubectl apply -f strimzi/users/ -n $NS_KAFKA

echo "==> Installing kube-prometheus-stack (v$PROMETHEUS_STACK_VERSION)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace $NS_MONITORING \
  --version $PROMETHEUS_STACK_VERSION \
  -f monitoring/prometheus/prometheus-values.yaml \
  --wait --timeout 5m

echo "==> Applying ServiceMonitors and alert rules..."
kubectl apply -f monitoring/prometheus/servicemonitor-kafka.yaml
kubectl apply -f monitoring/prometheus/rules/kafka-alerts.yaml

echo ""
echo "======================================================"
echo " Install complete!"
echo "======================================================"
echo ""
echo "  Kafka bootstrap (internal plain):  production-kafka-kafka-bootstrap.$NS_KAFKA:9092"
echo "  Kafka bootstrap (internal TLS):    production-kafka-kafka-bootstrap.$NS_KAFKA:9093"
echo ""
echo "  Grafana:  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n $NS_MONITORING"
echo "            http://localhost:3000  (admin / admin)"
echo ""
echo "  Prometheus: kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n $NS_MONITORING"
echo "              http://localhost:9090"
echo ""
echo "  Run ./scripts/verify-cluster.sh to confirm health."
