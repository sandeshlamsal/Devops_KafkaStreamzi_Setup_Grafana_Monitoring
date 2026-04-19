#!/usr/bin/env bash
# Verify the Strimzi Kafka cluster health on docker-desktop
set -euo pipefail

NS_KAFKA="kafka"
NS_MONITORING="monitoring"
PASS=0
FAIL=0

check() {
  local label="$1"
  local cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo "  [OK]  $label"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] $label"
    FAIL=$((FAIL+1))
  fi
}

echo "==> Kafka Cluster"
check "Kafka CR Ready" \
  "kubectl get kafka production-kafka -n $NS_KAFKA -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

check "3 broker pods Running" \
  "[[ \$(kubectl get pods -n $NS_KAFKA -l strimzi.io/cluster=production-kafka --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -ge 3 ]]"

check "Entity operator Running" \
  "kubectl get pod -n $NS_KAFKA -l strimzi.io/name=production-kafka-entity-operator --field-selector=status.phase=Running --no-headers | grep -q entity-operator"

echo ""
echo "==> KafkaTopics"
check "payments.orders.created.v1 exists" \
  "kubectl get kafkatopic payments.orders.created.v1 -n $NS_KAFKA"
check "inventory.products.updated.v1 exists" \
  "kubectl get kafkatopic inventory.products.updated.v1 -n $NS_KAFKA"

echo ""
echo "==> KafkaUsers"
check "payments-service user exists" \
  "kubectl get kafkauser payments-service -n $NS_KAFKA"
check "inventory-service user exists" \
  "kubectl get kafkauser inventory-service -n $NS_KAFKA"

echo ""
echo "==> Monitoring"
check "Prometheus pod Running" \
  "kubectl get pods -n $NS_MONITORING -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running --no-headers | grep -q prometheus"
check "Grafana pod Running" \
  "kubectl get pods -n $NS_MONITORING -l app.kubernetes.io/name=grafana --field-selector=status.phase=Running --no-headers | grep -q grafana"
check "kafka-servicemonitor exists" \
  "kubectl get servicemonitor kafka-servicemonitor -n $NS_MONITORING"
check "kafka-alerts PrometheusRule exists" \
  "kubectl get prometheusrule kafka-alerts -n $NS_MONITORING"

echo ""
echo "==> Kafka Connect"
check "KafkaConnect CR exists" \
  "kubectl get kafkaconnect production-connect -n $NS_KAFKA"
check "Connect pod Running" \
  "kubectl get pods -n $NS_KAFKA -l strimzi.io/kind=KafkaConnect --field-selector=status.phase=Running --no-headers | grep -q connect"

echo ""
echo "==> Schema Registry"
check "Schema Registry deployment exists" \
  "kubectl get deployment schema-registry -n $NS_KAFKA"
check "Schema Registry pod Running" \
  "kubectl get pods -n $NS_KAFKA -l app=schema-registry --field-selector=status.phase=Running --no-headers | grep -q schema-registry"

echo ""
echo "==> Network Policies"
check "kafka-broker-network-policy exists" \
  "kubectl get networkpolicy kafka-broker-network-policy -n $NS_KAFKA"
check "prometheus-network-policy exists" \
  "kubectl get networkpolicy prometheus-network-policy -n $NS_MONITORING"

echo ""
echo "======================================================"
echo " Results: $PASS passed, $FAIL failed"
echo "======================================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
