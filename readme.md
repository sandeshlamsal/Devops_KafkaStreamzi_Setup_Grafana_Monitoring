# Production-Grade Strimzi Kafka Setup with Grafana Monitoring

## Overview

This repository documents the end-to-end setup of Apache Kafka on Kubernetes using **Strimzi Operator v0.44.0**, with production-grade observability via **Prometheus** and **Grafana**. It covers cluster bootstrapping, topic/user management, TLS security, schema registry, Connect, and alerting — fully tested on **k3d (k3s in Docker)** adapted for local development, with notes on production differences.

---

## Current Deployment Status

> Last verified: 2026-04-19

| Component | Status | Notes |
|-----------|--------|-------|
| Strimzi Operator v0.44.0 | ✅ Running | Helm, namespace `kafka` |
| Kafka Cluster (KRaft, 3 nodes) | ✅ Ready | Kafka 3.7.0, combined controller+broker |
| Entity Operator | ✅ Running | Topic + User operators |
| KafkaTopics | ✅ Created | `payments.orders.created.v1` (6p), `inventory.products.updated.v1` (3p) |
| KafkaUsers | ✅ Created | `payments-service`, `inventory-service` (TLS auth + ACLs) |
| Kafka Connect | ✅ Running | Plain bootstrap, JsonConverter |
| Schema Registry | ✅ Running | Confluent 7.6.0, plain 9092 |
| Kafka Exporter | ✅ Scraping | Consumer lag metrics on `:9308` |
| Prometheus | ✅ Running | kube-prometheus-stack v58.0.0 |
| Grafana | ✅ Running | 4 Strimzi dashboards loaded |
| AlertManager | ✅ Running | 7 PrometheusRules applied |
| Network Policies | ✅ Applied | kafka + monitoring namespaces |

### End-to-End Test Results

```
=== Topic Message Counts ===
  payments.orders.created.v1:    3,005 messages (6 partitions)
  inventory.products.updated.v1:   500 messages (3 partitions)

=== Consumer Group Lag (Prometheus-scraped) ===
  payments-service-group / payments.orders.created.v1  → lag = 2,000  (deliberate, showing in Grafana)
  inventory-service-group / inventory.products.updated.v1 → lag = 0   (fully consumed)
  check-group / payments.orders.created.v1             → lag = 3,000  (only consumed 5 msgs)

=== Grafana Dashboards (auto-loaded via sidecar) ===
  ✅ Strimzi Kafka
  ✅ Strimzi Kafka Exporter
  ✅ Strimzi Kafka Connect
  ✅ Strimzi Operators
```

---

## Known Issues & Solutions

These are real issues encountered during implementation, with the root cause and fix for each.

### Issue 1 — k3s v1.33 incompatible with Strimzi 0.44

**Symptom:**
```
UnrecognizedPropertyException: Unrecognized field "emulationMajor" (class
io.fabric8.kubernetes.api.model.version.Info)
```
Strimzi operator pod enters `CrashLoopBackOff` immediately after install.

**Root cause:** k3s v1.33 adds an `emulationMajor` field to the `/version` API response. Strimzi 0.44 uses fabric8 6.13.4, which fails strict JSON deserialization on unknown fields.

**Fix:** Create the k3d cluster pinned to k3s v1.31.6:
```bash
k3d cluster create kafka-local \
  --image rancher/k3s:v1.31.6-k3s1 \
  --servers 1 --agents 3 \
  -p "30092:30092@loadbalancer"
```

---

### Issue 2 — `watchNamespaces` duplicates kafka namespace

**Symptom:** Operator logs show `watching kafka,kafka` — the kafka namespace is listed twice, causing reconciliation noise.

**Root cause:** When Strimzi is installed into the `kafka` namespace, it automatically watches that namespace. Setting `--set watchNamespaces="{kafka}"` additionally adds it, resulting in a duplicate.

**Fix:** Omit the `watchNamespaces` flag entirely when operator and Kafka are in the same namespace:
```bash
helm install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --version 0.44.0
```

---

### Issue 3 — `storageClassName: hostpath` not found in k3d

**Symptom:**
```
no persistent volumes available for this claim and no storage class is set
```
Prometheus PVCs remain `Pending`.

**Root cause:** k3d uses the `rancher.io/local-path` provisioner, which creates a StorageClass named `local-path` — not `hostpath` (which is Docker Desktop's class).

**Fix:** Use `local-path` in `prometheus-values.yaml`:
```yaml
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path   # not hostpath
          resources:
            requests:
              storage: 5Gi
```

---

### Issue 4 — `verify-cluster.sh` exits immediately on first success

**Symptom:** Script exits after the first `[OK]` check — all subsequent checks never run.

**Root cause:** `set -euo pipefail` is active. The arithmetic expression `((PASS++))` evaluates to `0` when `PASS` starts at `0`, which bash treats as a false/failure exit code (`1`), causing the shell to exit.

**Fix:** Use assignment arithmetic instead:
```bash
# Wrong — exits when PASS==0
((PASS++))

# Correct — always exits 0
PASS=$((PASS + 1))
FAIL=$((FAIL + 1))
```

---

### Issue 5 — Schema Registry `CrashLoopBackOff`

**Symptom:**
```
org.apache.kafka.common.config.ConfigException:
  Invalid value tcp://10.96.x.x:8081 for configuration bootstrap.servers
```

**Root cause:** Kubernetes auto-injects service discovery environment variables for every service in the namespace. Because there is a Service named `schema-registry` on port 8081, Kubernetes injects `SCHEMA_REGISTRY_PORT=tcp://10.96.x.x:8081`. Confluent's config parser treats every `SCHEMA_REGISTRY_*` env var as a config key and fails to parse the `tcp://` value as a bootstrap address.

**Fix:** Set `enableServiceLinks: false` in the pod spec to suppress Kubernetes service env injection:
```yaml
spec:
  enableServiceLinks: false   # prevents SCHEMA_REGISTRY_PORT=tcp://... injection
  containers:
    - name: schema-registry
      image: confluentinc/cp-schema-registry:7.6.0
```

---

### Issue 6 — `kafka-init` ClosedChannelException with NodePort external listener

**Symptom:**
```
io.netty.channel.ClosedChannelException: null
kafka-init container fails, broker pod stuck in Init:0/1
```

**Root cause:** When an external NodePort listener is configured, Strimzi's `kafka-init` container queries the Kubernetes API to resolve the node's external address for advertising. On k3d, the node's external IP is unreachable from inside the cluster, and the init container cannot complete. Even with RBAC fixes, the underlying network path doesn't resolve correctly.

**Fix:** Remove the external NodePort listener entirely from the Kafka CR. Internal-only listeners (`plain` on 9092, `tls` on 9093) are sufficient for local dev:
```yaml
spec:
  kafka:
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls
    # No external listener — avoids kafka-init node address lookup
```

---

### Issue 7 — Cruise Control triggers rolling restart deadlock

**Symptom:** After adding `cruiseControl:` to the Kafka CR, the operator attempts a rolling restart. `pod-0`'s init container fails because the StrimziPodSet still carries `EXTERNAL_ADDRESS=TRUE` from the previous spec. The operator waits for `pod-0` to become Ready before applying the new spec — deadlock.

**Root cause:** Cruise Control triggers a full rolling restart when first added. Any pre-existing misconfiguration in the current pod spec (e.g. stale external listener env var) blocks the rolling update from completing.

**Fix:** Do not add Cruise Control to an already-running cluster without first ensuring the existing spec is clean. For local dev, omit Cruise Control entirely:
```yaml
spec:
  kafka: ...
  entityOperator: ...
  # No cruiseControl section for local dev
```
If a deadlock occurs, break it by force-deleting blocked pods after manually patching the StrimziPodSet — but it is safer to delete and recreate the cluster.

---

### Issue 8 — Network policy blocks Prometheus from scraping Kafka Exporter (port 9308)

**Symptom:** Prometheus target `http://<kafka-exporter-pod-ip>:9308/metrics` shows `State: down`, error `connection refused`.

**Root cause (two policies):**

1. **`kafka-broker-network-policy`** — ingress from `monitoring` namespace only allowed on port `9404` (JMX exporter). Kafka Exporter listens on `9308`, which was not in the allow list.
2. **`prometheus-network-policy`** — egress from Prometheus to `kafka` namespace only allowed on port `9404`. Same missing port.

**Fix:** Add port `9308` to both policies:

`network-policies/kafka-network-policy.yaml`:
```yaml
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
  ports:
    - port: 9404
    - port: 9308   # Kafka Exporter
```

`network-policies/monitoring-network-policy.yaml`:
```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kafka
    ports:
      - port: 9404
      - port: 9308   # Kafka Exporter
```

---

### Issue 9 — Grafana dashboard ConfigMaps not created (Python `yaml` module missing)

**Symptom:**
```
ModuleNotFoundError: No module named 'yaml'
```
Attempt to generate dashboard ConfigMaps using a Python script failed.

**Root cause:** The host system had Python 3.14 installed but `PyYAML` was not installed via `pip`.

**Fix:** Use `kubectl create configmap --dry-run=client -o yaml` with `sed` to inject the sidecar label, bypassing Python entirely:
```bash
for name in strimzi-kafka strimzi-kafka-exporter strimzi-kafka-connect strimzi-operators; do
  kubectl create configmap "grafana-dashboard-${name}" \
    --from-file="${name}.json=monitoring/grafana/dashboards/${name}.json" \
    --namespace monitoring \
    --dry-run=client -o yaml | \
    sed 's/^  namespace: monitoring$/  namespace: monitoring\n  labels:\n    grafana_dashboard: "1"/' \
    > "monitoring/grafana/dashboards/${name}-configmap.yaml"
  kubectl apply -f "monitoring/grafana/dashboards/${name}-configmap.yaml"
done
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    k3d Kubernetes Cluster                       │
│   (k3s v1.31.6 — 1 server + 3 agent nodes)                    │
│                                                                 │
│  namespace: kafka                                               │
│  ┌──────────────┐   ┌────────────────────────────────────────┐ │
│  │   Strimzi    │   │  KafkaNodePool: combined (x3)          │ │
│  │   Operator   │──▶│  roles: [controller, broker]           │ │
│  └──────────────┘   │  Kafka 3.7.0, KRaft mode               │ │
│                     └──────────┬───────────────────────────── ┘ │
│                                │ bootstrap:9092 (plain)         │
│  ┌─────────────────────────────▼───────────────────────────┐   │
│  │ Kafka Ecosystem (namespace: kafka)                       │   │
│  │  Kafka Connect │ Schema Registry │ Kafka Exporter:9308  │   │
│  └─────────────────────────────┬───────────────────────────┘   │
│                                │ JMX:9404  Exporter:9308        │
│  ┌─────────────────────────────▼───────────────────────────┐   │
│  │ Observability Stack (namespace: monitoring)              │   │
│  │  Prometheus (scrapes 9404 + 9308) → Grafana (4 boards)  │   │
│  │  AlertManager (7 rules)                                  │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Repository Structure](#2-repository-structure)
3. [Strimzi Operator Installation](#3-strimzi-operator-installation)
4. [Kafka Cluster Deployment](#4-kafka-cluster-deployment)
5. [KRaft Mode (ZooKeeper-less)](#5-kraft-mode-zookeeper-less)
6. [TLS and Authentication](#6-tls-and-authentication)
7. [Topic Management](#7-topic-management)
8. [User Management (ACLs)](#8-user-management-acls)
9. [Kafka Connect](#9-kafka-connect)
10. [Schema Registry](#10-schema-registry)
11. [MirrorMaker 2 (Multi-cluster Replication)](#11-mirrormaker-2-multi-cluster-replication)
12. [Prometheus Integration](#12-prometheus-integration)
13. [Grafana Dashboards](#13-grafana-dashboards)
14. [Alerting with AlertManager](#14-alerting-with-alertmanager)
15. [Storage Configuration](#15-storage-configuration)
16. [Network Policies](#16-network-policies)
17. [Scaling and Performance Tuning](#17-scaling-and-performance-tuning)
18. [Backup and Recovery](#18-backup-and-recovery)
19. [Upgrade Strategy](#19-upgrade-strategy)
20. [Troubleshooting](#20-troubleshooting)

---

## 1. Prerequisites

### Tools Required

| Tool | Version | Purpose |
|------|---------|---------|
| `kubectl` | >= 1.27 | Kubernetes CLI |
| `helm` | >= 3.12 | Package manager |
| `k3d` | >= 5.6 | Local k3s cluster (dev) |
| `openssl` | >= 3.0 | TLS certificate generation |

### Local Dev Cluster (k3d)

```bash
# Create cluster with k3s v1.31.6 (required — v1.33 breaks Strimzi 0.44)
k3d cluster create kafka-local \
  --image rancher/k3s:v1.31.6-k3s1 \
  --servers 1 --agents 3 \
  -p "30092:30092@loadbalancer"

kubectl cluster-info
```

> **Warning:** Do NOT use k3s v1.33+. The `emulationMajor` field in its `/version` response causes Strimzi's fabric8 client to crash. See [Issue 1](#issue-1--k3s-v133-incompatible-with-strimzi-044).

### Production Kubernetes Requirements

- Kubernetes >= 1.27 (EKS / GKE / AKS / on-prem)
- Minimum node specs for production brokers: **4 vCPU, 16 GB RAM, 500 GB SSD**
- StorageClass with `WaitForFirstConsumer` binding mode and `Retain` reclaim policy
- Dedicated node pool for Kafka brokers (via taints/tolerations)

### Namespace Setup

```bash
kubectl create namespace kafka
kubectl create namespace monitoring
kubectl label namespace kafka kubernetes.io/metadata.name=kafka
kubectl label namespace monitoring kubernetes.io/metadata.name=monitoring
```

---

## 2. Repository Structure

```
.
├── strimzi/
│   ├── cluster/
│   │   ├── kafka-cluster.yaml           # Kafka CR (KRaft, internal listeners only)
│   │   └── node-pool.yaml               # KafkaNodePool (combined controller+broker)
│   ├── topics/
│   │   ├── orders-events.yaml           # payments.orders.created.v1 (6 partitions)
│   │   └── inventory-updates.yaml       # inventory.products.updated.v1 (3 partitions)
│   ├── users/
│   │   ├── payments-service.yaml        # TLS auth, Write+Read ACL on payments topic
│   │   └── inventory-service.yaml       # TLS auth, Write ACL on inventory topic
│   ├── connect/
│   │   └── kafka-connect.yaml           # KafkaConnect (plain 9092, JsonConverter)
│   └── schema-registry/
│       └── schema-registry.yaml         # Confluent Schema Registry 7.6.0
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus-values.yaml       # Helm values (local-path StorageClass)
│   │   ├── kafka-metrics-configmap.yaml # JMX exporter rules
│   │   ├── servicemonitor-kafka.yaml    # ServiceMonitors for Kafka + Connect
│   │   └── rules/
│   │       └── kafka-alerts.yaml        # 7 PrometheusRules
│   ├── grafana/
│   │   ├── datasource-prometheus.yaml   # Prometheus datasource ConfigMap
│   │   └── dashboards/
│   │       ├── strimzi-kafka.json            # Official Strimzi dashboard
│   │       ├── strimzi-kafka-exporter.json   # Consumer lag dashboard
│   │       ├── strimzi-kafka-connect.json    # Connect dashboard
│   │       ├── strimzi-operators.json        # Operator metrics dashboard
│   │       ├── strimzi-kafka-configmap.yaml
│   │       ├── strimzi-kafka-exporter-configmap.yaml
│   │       ├── strimzi-kafka-connect-configmap.yaml
│   │       └── strimzi-operators-configmap.yaml
│   ├── kafka-exporter/
│   │   └── kafka-exporter.yaml          # Deployment + Service + ServiceMonitor
│   └── alertmanager/
│       └── alertmanager-config.yaml
├── network-policies/
│   ├── kafka-network-policy.yaml        # Ports: 9090,9091,9092,9093,9404,9308
│   └── monitoring-network-policy.yaml   # Prometheus egress: 9404,9308
└── scripts/
    ├── install.sh                       # Full one-shot install script
    └── verify-cluster.sh                # 17-check health script
```

---

## 3. Strimzi Operator Installation

```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update

# Do NOT set watchNamespaces when operator and kafka share the same namespace
helm install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --version 0.44.0 \
  --wait --timeout 5m
```

> **Note:** Omit `--set watchNamespaces="{kafka}"` — Strimzi already watches its own namespace. Adding it explicitly creates a duplicate entry. See [Issue 2](#issue-2--watchnamespaces-duplicates-kafka-namespace).

### Verify

```bash
kubectl get pods -n kafka -l name=strimzi-cluster-operator
kubectl get crds | grep strimzi
# Expected: kafkas, kafkatopics, kafkausers, kafkaconnects, kafkanodepools, ...
```

---

## 4. Kafka Cluster Deployment

### `strimzi/cluster/node-pool.yaml`

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: combined
  namespace: kafka
  labels:
    strimzi.io/cluster: production-kafka
spec:
  replicas: 3
  roles:
    - controller
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 10Gi
        class: local-path   # k3d StorageClass (use kafka-storage / gp3 in prod)
        deleteClaim: false
  resources:
    requests:
      memory: 1Gi
      cpu: 250m
    limits:
      memory: 2Gi
      cpu: "1"
```

### `strimzi/cluster/kafka-cluster.yaml`

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: production-kafka
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.7.0
    metadataVersion: 3.7-IV4
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls
      # No external listener — avoids kafka-init node-address lookup failure on k3d
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
      log.retention.hours: 24
      num.network.threads: 3
      num.io.threads: 8
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef:
          name: kafka-metrics-config
          key: kafka-metrics-config.yml
    template:
      pod:
        affinity:
          podAntiAffinity:
            preferredDuringSchedulingIgnoredDuringExecution:
              - weight: 100
                podAffinityTerm:
                  labelSelector:
                    matchExpressions:
                      - key: strimzi.io/name
                        operator: In
                        values:
                          - production-kafka-combined
                  topologyKey: kubernetes.io/hostname
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

```bash
kubectl apply -f strimzi/cluster/
kubectl wait kafka/production-kafka --for=condition=Ready \
  --timeout=600s -n kafka
```

---

## 5. KRaft Mode (ZooKeeper-less)

KRaft is enabled via two annotations on the Kafka CR:

```yaml
metadata:
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
```

The `KafkaNodePool` with `roles: [controller, broker]` creates combined nodes (suitable for local dev). In production, separate controller and broker pools are recommended:

```yaml
# Controller-only pool (3 replicas, smaller storage)
---
kind: KafkaNodePool
metadata:
  name: controller
spec:
  roles: [controller]
  replicas: 3
  storage:
    size: 20Gi

# Broker-only pool (scale independently)
---
kind: KafkaNodePool
metadata:
  name: broker
spec:
  roles: [broker]
  replicas: 3
  storage:
    type: jbod
    volumes:
      - id: 0
        size: 500Gi
        class: kafka-storage
```

---

## 6. TLS and Authentication

### Mutual TLS (mTLS) — Client Certificate Auth

Strimzi automatically generates a cluster CA. Extract for clients:

```bash
kubectl get secret production-kafka-cluster-ca-cert \
  -n kafka -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
```

### SCRAM-SHA-512 Authentication

```yaml
listeners:
  - name: scram
    port: 9095
    type: internal
    tls: true
    authentication:
      type: scram-sha-512
```

### OAuth2 / OIDC (enterprise)

```yaml
listeners:
  - name: oauth
    port: 9096
    type: internal
    tls: true
    authentication:
      type: oauth
      validIssuerUri: https://your-keycloak/realms/kafka
      jwksEndpointUri: https://your-keycloak/realms/kafka/protocol/openid-connect/certs
      userNameClaim: preferred_username
```

---

## 7. Topic Management

**Naming convention:** `<domain>.<entity>.<event-type>.<version>`

### `strimzi/topics/orders-events.yaml`

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: payments.orders.created.v1
  namespace: kafka
  labels:
    strimzi.io/cluster: production-kafka
spec:
  partitions: 6
  replicas: 3
  config:
    retention.ms: "86400000"       # 24 hours (local dev)
    min.insync.replicas: "2"
    compression.type: lz4
    cleanup.policy: delete
```

```bash
kubectl apply -f strimzi/topics/
kubectl get kafkatopics -n kafka
```

---

## 8. User Management (ACLs)

### `strimzi/users/payments-service.yaml`

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: payments-service
  namespace: kafka
  labels:
    strimzi.io/cluster: production-kafka
spec:
  authentication:
    type: tls
  authorization:
    type: simple
    acls:
      - resource:
          type: topic
          name: payments.orders.created.v1
          patternType: literal
        operations: [Write, Read, Describe]
      - resource:
          type: group
          name: payments-service-group
          patternType: literal
        operations: [Read]
```

```bash
kubectl apply -f strimzi/users/
# Extract user cert for application config
kubectl get secret payments-service -n kafka \
  -o jsonpath='{.data.user\.crt}' | base64 -d > user.crt
```

---

## 9. Kafka Connect

### `strimzi/connect/kafka-connect.yaml`

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnect
metadata:
  name: production-connect
  namespace: kafka
  annotations:
    strimzi.io/use-connector-resources: "true"
spec:
  version: 3.7.0
  replicas: 1
  bootstrapServers: production-kafka-kafka-bootstrap:9092
  config:
    group.id: connect-cluster
    offset.storage.topic: connect-offsets
    config.storage.topic: connect-configs
    status.storage.topic: connect-status
    config.storage.replication.factor: 1
    offset.storage.replication.factor: 1
    status.storage.replication.factor: 1
    key.converter: org.apache.kafka.connect.storage.StringConverter
    value.converter: org.apache.kafka.connect.json.JsonConverter
    value.converter.schemas.enable: "false"
```

---

## 10. Schema Registry

> **Critical:** Set `enableServiceLinks: false` or the pod will crash. See [Issue 5](#issue-5--schema-registry-crashloopbackoff).

### `strimzi/schema-registry/schema-registry.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: schema-registry
  namespace: kafka
spec:
  replicas: 1
  selector:
    matchLabels:
      app: schema-registry
  template:
    metadata:
      labels:
        app: schema-registry
    spec:
      enableServiceLinks: false   # prevents SCHEMA_REGISTRY_PORT=tcp://... injection
      containers:
        - name: schema-registry
          image: confluentinc/cp-schema-registry:7.6.0
          ports:
            - containerPort: 8081
          env:
            - name: SCHEMA_REGISTRY_HOST_NAME
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS
              value: "production-kafka-kafka-bootstrap:9092"
            - name: SCHEMA_REGISTRY_KAFKASTORE_SECURITY_PROTOCOL
              value: PLAINTEXT
            - name: SCHEMA_REGISTRY_LISTENERS
              value: "http://0.0.0.0:8081"
```

### Test Schema Registry

```bash
kubectl port-forward svc/schema-registry 8081:8081 -n kafka
curl http://localhost:8081/subjects
# Expected: []
```

---

## 11. MirrorMaker 2 (Multi-cluster Replication)

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaMirrorMaker2
metadata:
  name: kafka-mirror-maker2
  namespace: kafka
spec:
  version: 3.7.0
  replicas: 3
  connectCluster: "target-cluster"
  clusters:
    - alias: "source-cluster"
      bootstrapServers: source-kafka-bootstrap.source-namespace:9093
      tls:
        trustedCertificates:
          - secretName: source-cluster-ca-cert
            certificate: ca.crt
    - alias: "target-cluster"
      bootstrapServers: production-kafka-kafka-bootstrap:9093
      tls:
        trustedCertificates:
          - secretName: production-kafka-cluster-ca-cert
            certificate: ca.crt
  mirrors:
    - sourceCluster: "source-cluster"
      targetCluster: "target-cluster"
      sourceConnector:
        config:
          replication.factor: 3
          sync.topic.acls.enabled: "false"
      topicsPattern: ".*"
      groupsPattern: ".*"
```

---

## 12. Prometheus Integration

### Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 58.0.0 \
  -f monitoring/prometheus/prometheus-values.yaml \
  --wait
```

Key `prometheus-values.yaml` settings for k3d:

```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path   # k3d StorageClass
          resources:
            requests:
              storage: 5Gi
```

### Kafka JMX Exporter ConfigMap

```bash
kubectl apply -f monitoring/prometheus/kafka-metrics-configmap.yaml -n kafka
```

### ServiceMonitors

```bash
kubectl apply -f monitoring/prometheus/servicemonitor-kafka.yaml
```

### Kafka Exporter (consumer lag)

```bash
kubectl apply -f monitoring/kafka-exporter/kafka-exporter.yaml
```

The exporter scrapes per-partition lag from Kafka's consumer group API and exposes it on `:9308`. Prometheus scrapes it every 30s via a ServiceMonitor.

---

## 13. Grafana Dashboards

### Access Grafana

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3001:80 -n monitoring
# Username: admin
# Password: $(kubectl get secret kube-prometheus-stack-grafana -n monitoring \
#              -o jsonpath='{.data.admin-password}' | base64 -d)
```

### Official Strimzi Dashboards (auto-loaded via sidecar)

Dashboards are provisioned as ConfigMaps with label `grafana_dashboard: "1"`. The Grafana sidecar container auto-discovers and loads them without a pod restart.

| Dashboard | File | Content |
|-----------|------|---------|
| Strimzi Kafka | `strimzi-kafka-configmap.yaml` | Broker metrics, partition leadership, log sizes |
| Strimzi Kafka Exporter | `strimzi-kafka-exporter-configmap.yaml` | Consumer group lag per topic/partition |
| Strimzi Kafka Connect | `strimzi-kafka-connect-configmap.yaml` | Connector status, task throughput |
| Strimzi Operators | `strimzi-operators-configmap.yaml` | Operator reconciliation event rates |

JSON sources: `strimzi-kafka-operator` GitHub tag `0.44.0`, path `examples/metrics/grafana-dashboards/`.

```bash
kubectl apply -f monitoring/grafana/dashboards/
```

### Re-generate dashboard ConfigMaps (if JSON changes)

```bash
for name in strimzi-kafka strimzi-kafka-exporter strimzi-kafka-connect strimzi-operators; do
  kubectl create configmap "grafana-dashboard-${name}" \
    --from-file="${name}.json=monitoring/grafana/dashboards/${name}.json" \
    --namespace monitoring \
    --dry-run=client -o yaml | \
    sed 's/^  namespace: monitoring$/  namespace: monitoring\n  labels:\n    grafana_dashboard: "1"/' \
    > "monitoring/grafana/dashboards/${name}-configmap.yaml"
  kubectl apply -f "monitoring/grafana/dashboards/${name}-configmap.yaml"
done
```

---

## 14. Alerting with AlertManager

### `monitoring/prometheus/rules/kafka-alerts.yaml`

7 rules applied:

| Alert | Severity | Condition |
|-------|----------|-----------|
| `KafkaBrokerDown` | critical | Any broker unreachable for > 1m |
| `KafkaUnderReplicatedPartitions` | warning | Under-replicated partitions for > 5m |
| `KafkaOfflinePartitions` | critical | Offline partitions for > 1m |
| `KafkaConsumerLagHigh` | warning | Total lag > 10,000 for > 10m |
| `KafkaDiskUsageHigh` | warning | PVC usage > 80% for > 5m |
| `KafkaISRShrinkage` | warning | ISR shrink rate > 0 for > 5m |
| `KafkaActiveControllerCount` | critical | Active controller != 1 |

```bash
kubectl apply -f monitoring/prometheus/rules/kafka-alerts.yaml
kubectl get prometheusrule kafka-alerts -n monitoring
```

---

## 15. Storage Configuration

### Local dev (k3d)

```yaml
storageClassName: local-path   # rancher.io/local-path provisioner
```

### Production (AWS EKS gp3)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kafka-storage
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "16000"
  throughput: "1000"
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
```

**Best practices:**
- `Retain` reclaim policy — prevents accidental data loss on PVC delete
- `WaitForFirstConsumer` — co-locates PVC with broker pod in same AZ
- Use SSDs (gp3 / pd-ssd) for data volumes
- Enable volume expansion (`allowVolumeExpansion: true`)

---

## 16. Network Policies

### Port reference

| Port | Service | Direction |
|------|---------|-----------|
| 9090 | Kafka internal | Operator → brokers |
| 9091 | Kafka internal | Broker ↔ broker |
| 9092 | Kafka plain | Clients (kafka ns) |
| 9093 | Kafka TLS | Clients (kafka ns) |
| 9308 | Kafka Exporter | Prometheus → exporter |
| 9404 | JMX Exporter | Prometheus → brokers |
| 8081 | Schema Registry | Internal + monitoring |

### `network-policies/kafka-network-policy.yaml`

```yaml
# Ingress from monitoring: both JMX (9404) and Kafka Exporter (9308)
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
  ports:
    - port: 9404
    - port: 9308
```

### `network-policies/monitoring-network-policy.yaml`

```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kafka
    ports:
      - port: 9404
      - port: 9308   # Required for Kafka Exporter scraping
```

> **Common mistake:** Forgetting port 9308 in both policies causes Prometheus target to show `State: down, connection refused` even though the Kafka Exporter pod is healthy. See [Issue 8](#issue-8--network-policy-blocks-prometheus-from-scraping-kafka-exporter-port-9308).

---

## 17. Scaling and Performance Tuning

### Horizontal Scaling (KRaft)

```bash
# Scale broker count
kubectl patch kafkanodepool broker -n kafka \
  --type=merge -p '{"spec":{"replicas":5}}'
```

### Producer Tuning (high-throughput)

```properties
acks=all
retries=2147483647
enable.idempotence=true
compression.type=lz4
batch.size=65536
linger.ms=5
buffer.memory=67108864
```

### Consumer Tuning (low-latency)

```properties
fetch.min.bytes=1
fetch.max.wait.ms=10
max.poll.records=500
enable.auto.commit=false
isolation.level=read_committed
```

### Partition Rebalancing (Production — Cruise Control)

> **Local dev:** Do NOT add Cruise Control to a running cluster without a clean slate. It triggers a rolling restart that can deadlock if the existing pod spec has stale env vars. See [Issue 7](#issue-7--cruise-control-triggers-rolling-restart-deadlock).

```yaml
spec:
  cruiseControl:
    brokerCapacity:
      inboundNetwork: 10000KB/s
      outboundNetwork: 10000KB/s
```

---

## 18. Backup and Recovery

### Manual Offset Checkpoint

```bash
kubectl run kafka-groups --image=quay.io/strimzi/kafka:0.44.0-kafka-3.7.0 \
  --restart=Never --namespace=kafka --rm -i \
  --command -- /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server production-kafka-kafka-bootstrap:9092 \
    --describe --all-groups
```

> **Note:** Always use full path `/opt/kafka/bin/` in `--command` mode. The `PATH` does not include `/opt/kafka/bin` when using `kubectl run --command`. See [Load Test section](#load-test--verification).

### PVC Snapshot (Velero)

```bash
velero schedule create kafka-daily \
  --schedule="0 2 * * *" \
  --include-namespaces kafka \
  --include-resources persistentvolumeclaims,persistentvolumes
```

---

## 19. Upgrade Strategy

### Strimzi Operator Upgrade

```bash
# 1. Check current version
kubectl get deployment strimzi-cluster-operator -n kafka \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 2. Upgrade operator
helm upgrade strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --reuse-values \
  --version 0.45.0

# 3. Update Kafka version (triggers rolling broker restart)
kubectl patch kafka production-kafka -n kafka \
  --type=merge -p '{"spec":{"kafka":{"version":"3.8.0","metadataVersion":"3.8-IV0"}}}'
```

**Rules:**
- Upgrade Strimzi operator first, then update Kafka version
- Never skip more than one minor Strimzi version
- Test in staging before production

---

## 20. Troubleshooting

### Common Issues

| Symptom | Check | Resolution |
|---------|-------|------------|
| Strimzi crashes with `emulationMajor` | k3s version | Use k3s v1.31.6 (see [Issue 1](#issue-1--k3s-v133-incompatible-with-strimzi-044)) |
| Broker pod stuck in `Init:0/1` | `kubectl logs <pod> -c kafka-init` | Remove external NodePort listener (see [Issue 6](#issue-6--kafka-init-closedchannelexception-with-nodeport-external-listener)) |
| Schema Registry CrashLoopBackOff | `kubectl logs schema-registry` | Add `enableServiceLinks: false` (see [Issue 5](#issue-5--schema-registry-crashloopbackoff)) |
| Prometheus target `down (connection refused)` | Check network policies | Add port 9308 to both policies (see [Issue 8](#issue-8--network-policy-blocks-prometheus-from-scraping-kafka-exporter-port-9308)) |
| Broker pod stuck in `Pending` | `kubectl describe pod` | Check node capacity, PVC binding, StorageClass |
| `verify-cluster.sh` exits after 1 check | `set -euo pipefail` + `((PASS++))` | Use `PASS=$((PASS+1))` (see [Issue 4](#issue-4--verify-clustersh-exits-immediately-on-first-success)) |
| Consumer lag growing | Kafka Exporter metrics | Scale consumers; check `kafka_consumergroup_lag_sum` |

### Useful Commands

```bash
# Cluster health
bash scripts/verify-cluster.sh

# Kafka cluster CR status
kubectl get kafka production-kafka -n kafka -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Broker logs
kubectl logs -f production-kafka-combined-0 -n kafka -c kafka

# List topics + offsets
kubectl run kafka-offsets --image=quay.io/strimzi/kafka:0.44.0-kafka-3.7.0 \
  --restart=Never --namespace=kafka --rm -i \
  --command -- /opt/kafka/bin/kafka-get-offsets.sh \
    --bootstrap-server production-kafka-kafka-bootstrap:9092 \
    --topic payments.orders.created.v1

# Consumer group lag
kubectl run kafka-groups --image=quay.io/strimzi/kafka:0.44.0-kafka-3.7.0 \
  --restart=Never --namespace=kafka --rm -i \
  --command -- /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server production-kafka-kafka-bootstrap:9092 \
    --describe --all-groups

# KRaft quorum status
kubectl run kafka-quorum --image=quay.io/strimzi/kafka:0.44.0-kafka-3.7.0 \
  --restart=Never --namespace=kafka --rm -i \
  --command -- /opt/kafka/bin/kafka-metadata-quorum.sh \
    --bootstrap-server production-kafka-kafka-bootstrap:9092 describe --status

# Prometheus scrape targets (check kafka-exporter is up)
kubectl exec -n monitoring -c prometheus \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus --no-headers -o name | head -1) \
  -- wget -qO- 'http://localhost:9090/api/v1/targets' | \
  python3 -c "import sys,json; [print(t['scrapeUrl'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets'] if 'kafka' in t.get('scrapeUrl','')]"

# Kafka Exporter raw metrics
kubectl exec -n kafka deployment/kafka-exporter -- \
  wget -qO- http://localhost:9308/metrics | grep kafka_consumergroup_lag_sum
```

---

## Load Test & Verification

### Produce Load

```bash
# Produce 1000 messages to payments topic
kubectl run kafka-producer \
  --image=quay.io/strimzi/kafka:0.44.0-kafka-3.7.0 \
  --restart=Never --namespace=kafka \
  --command -- /bin/bash -c '
    for i in $(seq 1 1000); do
      echo "key-$i:{\"orderId\":$i,\"amount\":$((RANDOM % 500 + 10))}"
    done | /opt/kafka/bin/kafka-console-producer.sh \
      --bootstrap-server production-kafka-kafka-bootstrap:9092 \
      --topic payments.orders.created.v1 \
      --property parse.key=true --property key.separator=:
  '
```

> **Important:** Always use `/opt/kafka/bin/` prefix in `--command` mode. The shell PATH does not include `/opt/kafka/bin` when `kubectl run` uses `--command`, so bare script names like `kafka-console-producer.sh` will report "command not found" silently (exit 0 due to echo at end of script).

### Consume and Verify

```bash
kubectl run kafka-consumer \
  --image=quay.io/strimzi/kafka:0.44.0-kafka-3.7.0 \
  --restart=Never --namespace=kafka \
  --command -- /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server production-kafka-kafka-bootstrap:9092 \
    --topic payments.orders.created.v1 \
    --from-beginning \
    --group payments-service-group \
    --max-messages 1000 \
    --timeout-ms 60000
```

### Verify in Prometheus

```bash
# Query consumer lag (should appear after one 30s scrape cycle)
kubectl exec -n monitoring -c prometheus \
  $(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus --no-headers -o name | head -1) \
  -- wget -qO- 'http://localhost:9090/api/v1/query?query=kafka_consumergroup_lag_sum' | \
  python3 -c "
import sys, json
for r in json.load(sys.stdin)['data']['result']:
    print(r['metric'].get('consumergroup'), r['metric'].get('topic'), '→ lag =', r['value'][1])
"
```

---

## Quick Start (All-in-One)

```bash
# 1. Create k3d cluster (k3s v1.31.6 required)
k3d cluster create kafka-local \
  --image rancher/k3s:v1.31.6-k3s1 \
  --servers 1 --agents 3

# 2. Run full install
bash scripts/install.sh

# 3. Verify all 17 checks pass
bash scripts/verify-cluster.sh

# 4. Access Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana 3001:80 -n monitoring &
echo "Grafana: http://localhost:3001  user=admin  pass=$(kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)"
```

---

## References

- [Strimzi Documentation](https://strimzi.io/docs/operators/latest/)
- [Strimzi GitHub — v0.44.0](https://github.com/strimzi/strimzi-kafka-operator/tree/0.44.0)
- [Strimzi Grafana Dashboards](https://github.com/strimzi/strimzi-kafka-operator/tree/0.44.0/examples/metrics/grafana-dashboards)
- [Apache Kafka KRaft Mode](https://kafka.apache.org/documentation/#kraft)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Confluent Schema Registry](https://docs.confluent.io/platform/current/schema-registry/index.html)
- [Kafka Performance Tuning Guide](https://kafka.apache.org/documentation/#producerconfigs)
