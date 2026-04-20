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

## Strimzi Kafka — Component Deep Dive

This section explains every component in the Strimzi Kafka ecosystem: what it is, why it exists, how it communicates with other components, and what breaks when it is absent.

---

### Full System Architecture

```
╔══════════════════════════════════════════════════════════════════════════════════════╗
║                          Kubernetes Cluster                                         ║
║                                                                                     ║
║  ┌──────────────────────────────────────────────────────────────────────────────┐   ║
║  │  namespace: kafka                                                            │   ║
║  │                                                                              │   ║
║  │  ┌─────────────────────┐      watches CRs      ┌────────────────────────┐  │   ║
║  │  │   Strimzi Operator  │◄──────────────────────│  KafkaNodePool CR      │  │   ║
║  │  │  (Deployment)       │                        │  Kafka CR              │  │   ║
║  │  │                     │──── reconciles ──────► │  KafkaTopic CR         │  │   ║
║  │  │  - Fabric8 k8s SDK  │                        │  KafkaUser CR          │  │   ║
║  │  │  - Manages TLS CA   │                        │  KafkaConnect CR       │  │   ║
║  │  └─────────────────────┘                        └────────────────────────┘  │   ║
║  │          │                                                                   │   ║
║  │          │ creates/manages                                                   │   ║
║  │          ▼                                                                   │   ║
║  │  ┌───────────────────────────────────────────────────┐                      │   ║
║  │  │              Kafka Cluster (KRaft mode)           │                      │   ║
║  │  │                                                   │                      │   ║
║  │  │  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐                │   ║
║  │  │  │  combined-0  │  │  combined-1  │  │  combined-2    │                │   ║
║  │  │  │              │  │              │  │                │                │   ║
║  │  │  │ ● Controller │  │ ● Controller │  │ ● Controller   │  (KRaft quorum)│   ║
║  │  │  │ ● Broker     │  │ ● Broker     │  │ ● Broker       │  (data plane)  │   ║
║  │  │  │              │  │              │  │                │                │   ║
║  │  │  │ :9092 plain  │  │ :9092 plain  │  │ :9092 plain    │                │   ║
║  │  │  │ :9093 TLS    │  │ :9093 TLS    │  │ :9093 TLS      │                │   ║
║  │  │  │ :9091 inter  │◄─┤ :9091 inter  │◄─┤ :9091 inter    │                │   ║
║  │  │  │ :9090 ctrl   │  │ :9090 ctrl   │  │ :9090 ctrl     │                │   ║
║  │  │  │ :9404 JMX    │  │ :9404 JMX    │  │ :9404 JMX      │                │   ║
║  │  │  └──────────────┘  └──────────────┘  └────────────────┘                │   ║
║  │  │        PVC 10Gi           PVC 10Gi           PVC 10Gi                   │   ║
║  │  └───────────────────────────────────────────────────────┘                  │   ║
║  │                                                                              │   ║
║  │  ┌──────────────────┐  ┌─────────────────┐  ┌────────────────────────────┐ │   ║
║  │  │  Entity Operator │  │  Kafka Connect  │  │  Schema Registry           │ │   ║
║  │  │  ┌─────────────┐ │  │  (production-   │  │  (cp-schema-registry:7.6) │ │   ║
║  │  │  │Topic Operat.│ │  │   connect-0)    │  │                            │ │   ║
║  │  │  │User Operato.│ │  │  :8083 REST API │  │  :8081 REST API            │ │   ║
║  │  │  └─────────────┘ │  │  :9404 metrics  │  │  Stores schemas in         │ │   ║
║  │  └──────────────────┘  └─────────────────┘  │  _schemas topic            │ │   ║
║  │                                              └────────────────────────────┘ │   ║
║  │  ┌──────────────────────────────────────────────────────────────────────┐   │   ║
║  │  │  Kafka Exporter (danielqsj/kafka-exporter)                          │   │   ║
║  │  │  Queries consumer group API every 30s → exposes on :9308/metrics    │   │   ║
║  │  └──────────────────────────────────────────────────────────────────────┘   │   ║
║  └──────────────────────────────────────────────────────────────────────────────┘   ║
║                                                                                     ║
║  ┌──────────────────────────────────────────────────────────────────────────────┐   ║
║  │  namespace: monitoring                                                       │   ║
║  │                                                                              │   ║
║  │  ┌────────────────────────┐      ┌──────────────────┐  ┌─────────────────┐  │   ║
║  │  │  Prometheus            │      │  Grafana         │  │  AlertManager   │  │   ║
║  │  │  scrapes every 30s:    │─────►│  4 dashboards    │  │  7 alert rules  │  │   ║
║  │  │  - :9404 (JMX/broker)  │      │  - Strimzi Kafka  │  │  Slack/PagerD. │  │   ║
║  │  │  - :9308 (lag/exporter)│      │  - Kafka Exporter │  └─────────────────┘  │   ║
║  │  │  - :9090 (self)        │      │  - Kafka Connect  │                       │   ║
║  │  └────────────────────────┘      │  - Operators      │                       │   ║
║  │  ┌────────────────────────┐      └──────────────────┘                       │   ║
║  │  │  Prometheus Operator   │                                                  │   ║
║  │  │  reads ServiceMonitor  │                                                  │   ║
║  │  │  and PrometheusRule CRs│                                                  │   ║
║  │  └────────────────────────┘                                                  │   ║
║  └──────────────────────────────────────────────────────────────────────────────┘   ║
╚══════════════════════════════════════════════════════════════════════════════════════╝
```

---

### Component 1 — Apache Kafka Broker

**What it is:** The core data store and message bus. A broker receives messages from producers, persists them to disk in topic-partition log segments, and serves them to consumers.

**How it works:**

```
Producer                       Broker (combined-1, leader for partition 2)
   │                                │
   │── ProduceRequest(topic,p=2) ──►│
   │                                │ 1. Write to partition log segment
   │                                │    /var/kafka/data/payments.orders.created.v1-2/
   │                                │    000000000000000001.log  (message bytes)
   │                                │    000000000000000001.index (offset → file pos)
   │                                │
   │                                │ 2. Replicate to follower brokers (ISR)
   │                                │    combined-0 :9091  ◄─── FetchRequest
   │                                │    combined-2 :9091  ◄─── FetchRequest
   │                                │
   │◄─ ProduceResponse(offset=42) ──│ 3. Ack after min.insync.replicas confirmed
   │
Consumer
   │── FetchRequest(topic,p=2,offset=42) ──►│
   │◄─ FetchResponse(messages 42..52)  ──────│
```

**Key config in this repo:**

| Setting | Value | Why |
|---------|-------|-----|
| `offsets.topic.replication.factor` | 3 | Offset commits survive any single broker loss |
| `min.insync.replicas` | 2 | Producer `acks=all` requires 2 replicas to confirm write |
| `default.replication.factor` | 3 | User topics replicated across all 3 brokers |
| `log.retention.hours` | 24 | Local dev — short retention to save disk |

**Port map:**

| Port | Protocol | Purpose |
|------|----------|---------|
| 9092 | PLAINTEXT | Internal client connections (producers/consumers) |
| 9093 | TLS | Encrypted client connections |
| 9091 | PLAINTEXT | Broker-to-broker replication (inter-broker) |
| 9090 | PLAINTEXT | Controller-to-broker (KRaft cluster traffic) |
| 9404 | HTTP | JMX Prometheus exporter (scraped by Prometheus) |

---

### Component 2 — KRaft Controller

**What it is:** In KRaft mode (ZooKeeper-less Kafka), one or more brokers also run the **KRaft controller** role. Controllers manage cluster metadata: topic assignments, partition leadership, ISR state, and broker registrations. They replace the entire ZooKeeper ensemble.

**How it works:**

```
                         KRaft Metadata Quorum (Raft consensus)
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│   combined-0           combined-1           combined-2              │
│   ┌──────────┐         ┌──────────┐         ┌──────────┐           │
│   │Controller│◄───────►│Controller│◄───────►│Controller│           │
│   │ (LEADER) │         │(FOLLOWER)│         │(FOLLOWER)│           │
│   └────┬─────┘         └──────────┘         └──────────┘           │
│        │                                                            │
│        │  Metadata log (Raft entries):                              │
│        │  - PartitionChange: payments.orders.created.v1 p0 → b1    │
│        │  - BrokerRegistration: broker-2 online                    │
│        │  - TopicCreate: inventory.products.updated.v1              │
│        │                                                            │
│   All metadata written to __cluster_metadata topic (internal)      │
└─────────────────────────────────────────────────────────────────────┘
         │
         │ brokers fetch metadata from active controller
         ▼
   Broker data plane (9092/9093 client traffic)
```

**Why this matters over ZooKeeper:**
- No separate ZooKeeper ensemble to manage, monitor, or upgrade
- Metadata operations are faster (Raft vs ZK latency)
- Single unified security model — no ZK ACLs to maintain separately
- `KafkaNodePool` with `roles: [controller, broker]` means each node handles both — fine for dev, separate for prod

---

### Component 3 — Strimzi Operator

**What it is:** A Kubernetes Operator (controller) that manages the entire Kafka cluster lifecycle via Custom Resources. You declare desired state in YAML; the operator reconciles the cluster to match.

**Reconciliation loop:**

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Strimzi Operator Pod                             │
│                                                                     │
│  Informer (watches CRs)                                             │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  kafka.strimzi.io/v1beta2 events → reconcile queue        │    │
│  └────────────────────────────┬───────────────────────────────┘    │
│                               │                                     │
│  Reconcile loop               ▼                                     │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  1. Read current state (StrimziPodSet, Services, Secrets)  │    │
│  │  2. Compute desired state from Kafka CR                    │    │
│  │  3. Diff current vs desired                                │    │
│  │  4. Apply changes:                                         │    │
│  │     - Generate/rotate TLS certificates (cluster CA)        │    │
│  │     - Create/update StrimziPodSet (replaces StatefulSet)   │    │
│  │     - Create Services (bootstrap, broker, headless)        │    │
│  │     - Create ConfigMaps (kafka config, JMX rules)          │    │
│  │     - Rolling restart pods if config changed               │    │
│  │  5. Update CR status conditions (Ready / NotReady)         │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  Sub-operators running inside entity-operator pod:                  │
│  ┌────────────────────────┐  ┌────────────────────────────────┐   │
│  │    Topic Operator      │  │      User Operator             │   │
│  │  KafkaTopic CR ──────► │  │  KafkaUser CR ──────────────► │   │
│  │  kafka-topics.sh API   │  │  kafka-acls.sh API             │   │
│  │  (creates real topics) │  │  (creates users + ACLs)        │   │
│  └────────────────────────┘  └────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

**What the operator manages automatically:**
- Cluster CA and client certificates (rotated every 30 days by default)
- Rolling restarts on config change (one pod at a time, waits for ISR)
- StrimziPodSet (Strimzi's replacement for StatefulSet with finer restart control)
- Bootstrap, broker-specific, and headless Services
- Pod Disruption Budgets

---

### Component 4 — KafkaNodePool

**What it is:** A CR that defines a pool of Kafka pods with a specific set of roles, resources, and storage. Replaces the `spec.kafka.replicas` and `spec.kafka.storage` fields in the Kafka CR when `strimzi.io/node-pools: enabled`.

**Role separation (production):**

```
KafkaNodePool: controller          KafkaNodePool: broker
roles: [controller]                roles: [broker]
replicas: 3                        replicas: 3 (scale independently)
storage: 20Gi (metadata log)       storage: 500Gi JBOD (message data)
cpu: 1, memory: 4Gi                cpu: 4, memory: 16Gi

         ▲                                  ▲
         │                                  │
         └──────────────┬───────────────────┘
                        │
                  Kafka CR (references both pools
                   via strimzi.io/cluster label)
```

**Local dev (this repo) — combined pool:**
```
KafkaNodePool: combined
roles: [controller, broker]   ← both roles in one pod
replicas: 3                   ← 3 pods, each is controller + broker
storage: 10Gi                 ← fine for testing, not prod
```

---

### Component 5 — Topic Operator

**What it is:** Watches `KafkaTopic` CRs and reconciles them to real Kafka topics via the Kafka Admin API. Lets you manage topics as Kubernetes resources in Git.

**Data flow:**

```
Developer applies KafkaTopic CR:
  kubectl apply -f strimzi/topics/orders-events.yaml

         │
         ▼
Topic Operator (inside entity-operator pod)
  ┌──────────────────────────────────────────────┐
  │  1. Watch KafkaTopic CR                      │
  │  2. Call Kafka Admin API:                    │
  │     CreateTopics(                            │
  │       name="payments.orders.created.v1",     │
  │       numPartitions=6,                       │
  │       replicationFactor=3,                   │
  │       configs={retention.ms=86400000, ...}   │
  │     )                                        │
  │  3. Update CR status.conditions = Ready      │
  └──────────────────────────────────────────────┘
         │
         ▼
  Kafka Broker: topic created, partitions assigned across brokers

Reverse sync (broker → CR):
  If topic config changes directly in Kafka (e.g. via kafka-topics.sh),
  the operator detects the drift and reconciles back to the CR definition.
```

---

### Component 6 — User Operator

**What it is:** Watches `KafkaUser` CRs and creates Kafka users with TLS certificates or SCRAM credentials, plus ACL rules — as Kubernetes Secrets.

**TLS user flow:**

```
KafkaUser CR (payments-service)
  authentication: tls
  authorization: acls [Write+Read on payments.orders.created.v1]
         │
         ▼
User Operator
  ┌──────────────────────────────────────────────────────────────┐
  │  1. Generate client keypair signed by cluster CA             │
  │  2. Create Secret "payments-service" in kafka namespace:     │
  │     data:                                                    │
  │       user.crt: <base64 client cert>                         │
  │       user.key: <base64 private key>                         │
  │       user.p12: <PKCS12 keystore>                            │
  │       user.password: <keystore password>                     │
  │  3. Call Kafka Admin API:                                     │
  │     CreateAcls(principal=User:CN=payments-service,           │
  │       resource=Topic:payments.orders.created.v1,             │
  │       operation=WRITE)                                       │
  └──────────────────────────────────────────────────────────────┘
         │
         ▼
Application mounts Secret as volume → authenticates with mTLS
```

---

### Component 7 — Kafka Connect

**What it is:** A distributed, scalable framework for streaming data between Kafka and external systems (databases, S3, Elasticsearch, REST APIs). It runs **Connectors** — plugins that know how to read from a source or write to a sink.

**Architecture:**

```
External System                Kafka Connect Worker            Kafka Broker
(e.g. PostgreSQL)              (production-connect-0)
      │                               │                              │
      │ Debezium CDC (source)         │                              │
      │──── row change events ───────►│                              │
      │                               │  Connector task              │
      │                               │  ┌────────────────────┐     │
      │                               │  │ SourceConnector    │     │
      │                               │  │ reads WAL/binlog   │     │
      │                               │  │ converts to Record │     │
      │                               │  └────────┬───────────┘     │
      │                               │           │                  │
      │                               │           ▼                  │
      │                               │  ProduceRequest ────────────►│
      │                               │                              │ topic:
      │                               │                              │ payments.orders.created.v1
      │
      │ (sink direction — S3 example)
      │                     Kafka Broker                 S3
      │                           │                       │
      │           FetchRequest ◄──│                       │
      │                           │   SinkConnector       │
      │                           │   ┌──────────────┐    │
      │                           │   │ reads msgs   │    │
      │                           │   │ writes S3    │───►│
      │                           │   └──────────────┘    │

Config stored in internal Kafka topics:
  connect-offsets   — where each task last read (checkpointing)
  connect-configs   — connector configuration (persisted in Kafka)
  connect-status    — connector/task status
```

**Internal REST API (port 8083) — deploy connectors at runtime:**
```bash
curl -X POST http://production-connect:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{"name":"pg-source","config":{"connector.class":"io.debezium.connector.postgresql.PostgresConnector",...}}'
```

---

### Component 8 — Schema Registry

**What it is:** A centralized store for Avro, JSON Schema, and Protobuf schemas. Producers register schemas; consumers fetch them by ID embedded in the message header. Ensures producers and consumers agree on data shape without embedding full schema in every message.

**Message wire format:**

```
Kafka Message Value (with schema registry):
┌───────────────────────────────────────────────────┐
│  Magic byte: 0x00  (1 byte)                       │
│  Schema ID:  42    (4 bytes, big-endian int)       │
│  Avro payload: <binary Avro-encoded data>          │
└───────────────────────────────────────────────────┘

Producer flow:
  1. Serialize record with Avro schema
  2. POST /subjects/payments.orders.created.v1-value/versions
     → Schema Registry stores schema, returns schema_id=42
  3. Prepend magic+schema_id to Avro bytes → Kafka message

Consumer flow:
  1. Read Kafka message
  2. Extract schema_id=42 from first 5 bytes
  3. GET /schemas/ids/42  → fetch schema from registry
  4. Deserialize Avro payload using fetched schema
```

**Schema evolution (compatibility modes):**

```
BACKWARD (default):
  New schema can read data written by old schema
  → Add fields with defaults ✅  / Remove fields ❌

FORWARD:
  Old schema can read data written by new schema

FULL:
  Both directions — most restrictive, safest for production

NONE:
  No compatibility check — dangerous in production
```

**Why `enableServiceLinks: false` is required in this setup:**
Kubernetes injects `SCHEMA_REGISTRY_PORT=tcp://10.x.x.x:8081` as an env var. Confluent's config parser reads every `SCHEMA_REGISTRY_*` env var as a config key and fails to parse `tcp://` as a valid bootstrap address. Setting `enableServiceLinks: false` suppresses all service injection.

---

### Component 9 — Kafka Exporter

**What it is:** A standalone Prometheus exporter (not part of Strimzi) that connects to Kafka as a consumer-group-aware client and exposes per-partition consumer lag as Prometheus metrics. The JMX exporter covers broker internals; the Kafka Exporter covers consumer health.

**Data flow:**

```
Kafka Exporter Pod                    Prometheus
(kafka-exporter:9308)
       │                                    │
       │ Every 30s:                         │
       │  ListConsumerGroups                │
       │  DescribeConsumerGroups            │
       │  ListOffsets (end offsets)         │
       │                                    │
       │  lag = end_offset - committed_offset
       │                                    │
       │  /metrics endpoint                 │
       │  kafka_consumergroup_lag{          │
       │    consumergroup="payments-...",   │
       │    topic="payments.orders...",     │
       │    partition="2"                   │
       │  } 334                             │
       │                                    │
       │◄─── GET /metrics ─────────────────│ (ServiceMonitor scrape)
       │────  metrics text ────────────────►│
                                            │
                                            │  stores in time-series DB
                                            ▼
                                        Grafana
                                   "Strimzi Kafka Exporter"
                                   dashboard shows lag trend

Key metrics:
  kafka_consumergroup_lag{group,topic,partition}      per-partition lag
  kafka_consumergroup_lag_sum{group,topic}            total lag per group
  kafka_consumergroup_current_offset{group,topic,p}   committed offset
  kafka_topic_partition_current_offset{topic,p}       end offset
  kafka_topic_partition_oldest_offset{topic,p}        start offset
```

---

### Component 10 — JMX Prometheus Exporter (in-process)

**What it is:** A Java agent running inside each Kafka broker JVM that exposes Kafka's internal JMX metrics as Prometheus text format on port `:9404`. It is configured via a `ConfigMap` (`kafka-metrics-config`) that defines JMX → Prometheus metric name mapping rules.

**Metric categories exposed:**

```
Broker JVM (port 9404)
       │
       ├── kafka_server_BrokerTopicMetrics_*
       │     MessagesInPerSec         ← messages produced per second
       │     BytesInPerSec            ← bytes produced per second
       │     BytesOutPerSec           ← bytes consumed per second
       │     FailedProduceRequestsPerSec
       │
       ├── kafka_server_ReplicaManager_*
       │     UnderReplicatedPartitions ← partitions not fully replicated (alert trigger)
       │     PartitionCount            ← partitions led by this broker
       │     LeaderCount
       │     IsrShrinks/Expands        ← ISR membership changes
       │
       ├── kafka_controller_KafkaController_*
       │     ActiveControllerCount     ← must always be 1 (alert if != 1)
       │     OfflinePartitionsCount    ← must always be 0 (alert if > 0)
       │     PreferredReplicaImbalanceCount
       │
       ├── kafka_network_RequestMetrics_*
       │     RequestsPerSec{request="Produce"}
       │     TotalTimeMs{request="FetchConsumer"}
       │
       └── jvm_*  (GC, heap, threads)
```

---

### Component 11 — Prometheus

**What it is:** A time-series database and scrape engine. Prometheus pulls (`scrapes`) metrics from configured targets at fixed intervals and stores them. It also evaluates alert rules and fires to AlertManager.

**How ServiceMonitor wires it up:**

```
ServiceMonitor CR (kafka-servicemonitor)         ← you define this
       │
       │  namespaceSelector: kafka
       │  selector: matchLabels strimzi.io/kind=Kafka
       │  endpoints: port tcp-prometheus, interval 30s
       ▼
Prometheus Operator                              ← reads ServiceMonitor CRs
       │  generates prometheus.yml scrape_configs
       │
       ▼
Prometheus Pod
  scrape loop every 30s:
  ┌───────────────────────────────────────────────────────────────┐
  │  GET http://production-kafka-kafka-brokers:9404/metrics      │ JMX
  │  GET http://kafka-exporter:9308/metrics                      │ lag
  │  parse text format → store as time series                    │
  │  evaluate alert rules → fire to AlertManager if threshold    │
  └───────────────────────────────────────────────────────────────┘

Query language (PromQL examples):
  kafka_server_replicamanager_underreplicatedpartitions > 0
  sum by (consumergroup,topic)(kafka_consumergroup_lag_sum)
  rate(kafka_server_brokertopicmetrics_messagesinpersec_count[5m])
```

---

### Component 12 — Grafana

**What it is:** Visualization layer. Queries Prometheus via PromQL and renders dashboards. The **sidecar container** (`grafana-sc-dashboard`) watches for ConfigMaps with label `grafana_dashboard: "1"` and hot-reloads them as dashboards without restarting Grafana.

**Sidecar dashboard loading:**

```
ConfigMap (grafana-dashboard-strimzi-kafka)
  labels:
    grafana_dashboard: "1"
  data:
    strimzi-kafka.json: |<full dashboard JSON>
         │
         │  sidecar watches all ConfigMaps in cluster
         ▼
Grafana Pod (grafana-sc-dashboard sidecar container)
  watches Kubernetes API for ConfigMaps with grafana_dashboard=1
         │
         │  writes JSON to /tmp/dashboards/strimzi-kafka.json
         ▼
Grafana main container
  reads /tmp/dashboards/*.json on a 30s poll
  → dashboard appears in UI with no restart

4 dashboards in this repo (from strimzi-kafka-operator v0.44.0):
  ┌──────────────────────┬────────────────────────────────────────────┐
  │ Strimzi Kafka        │ Broker health: messages/sec, under-replicated │
  │ Strimzi Kafka Export.│ Consumer group lag trends per partition      │
  │ Strimzi Kafka Connect│ Connector status, task error rates           │
  │ Strimzi Operators    │ Operator reconciliation rate, error counts   │
  └──────────────────────┴────────────────────────────────────────────┘
```

---

### Component 13 — AlertManager

**What it is:** Receives alerts from Prometheus, deduplicates them, groups them, and routes them to receivers (Slack, PagerDuty, email, webhook). It handles silences and inhibition rules.

**Alert lifecycle:**

```
Prometheus evaluates rule every 30s:
  KafkaUnderReplicatedPartitions:
    expr: kafka_server_replicamanager_underreplicatedpartitions > 0
    for: 5m          ← must be true for 5 continuous minutes before firing

  t=0m   metric > 0   → state: PENDING
  t=5m   metric > 0   → state: FIRING → sends alert to AlertManager

AlertManager routing tree:
  alert: KafkaUnderReplicatedPartitions (severity=warning)
       │
       ├── groupBy: [alertname, cluster]
       ├── groupWait: 30s  (collect related alerts before sending)
       ├── groupInterval: 5m
       └── repeatInterval: 12h
             │
             ▼
        slack-warning receiver → POST to #kafka-warnings webhook

  alert: KafkaBrokerDown (severity=critical)
             │
             ▼
        pagerduty-critical receiver → create incident
```

**7 rules in this repo:**

```
Rule                         Threshold           Severity
────────────────────────────────────────────────────────
KafkaBrokerDown              any broker down     critical
KafkaUnderReplicatedPartitions > 0 for 5m       warning
KafkaOfflinePartitions       > 0 for 1m         critical
KafkaConsumerLagHigh         sum lag > 10,000   warning
KafkaDiskUsageHigh           PVC > 80%          warning
KafkaISRShrinkage            shrink rate > 0    warning
KafkaActiveControllerCount   count != 1         critical
```

---

### Component 14 — Network Policies

**What it is:** Kubernetes-native firewall rules that restrict which pods can talk to which ports. Critical for multi-tenant clusters and compliance.

**Full traffic map:**

```
┌──────── namespace: kafka ─────────────────────────────────────────┐
│                                                                    │
│  Kafka Broker pods                                                │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  INGRESS allowed from:                                   │    │
│  │    strimzi-cluster-operator    → :9090, :9091  (mgmt)    │    │
│  │    other kafka broker pods     → :9091          (repl)   │    │
│  │    kafka namespace pods        → :9092, :9093   (clients)│    │
│  │    monitoring namespace pods   → :9404           (JMX)   │    │
│  │                                → :9308           (exporter)    │
│  │  EGRESS allowed to:                                      │    │
│  │    other kafka broker pods     (replication)             │    │
│  │    :443 TCP                    (kafka-init k8s API call) │    │
│  │    :53 UDP/TCP                 (DNS)                     │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                    │
│  Schema Registry pods                                             │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  INGRESS allowed from:                                   │    │
│  │    kafka namespace             → :8081                   │    │
│  │    monitoring namespace        → :8081                   │    │
│  └──────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────┘

┌──────── namespace: monitoring ────────────────────────────────────┐
│                                                                    │
│  Prometheus pods                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  INGRESS allowed from:                                   │    │
│  │    grafana pod                 → :9090 (PromQL queries)  │    │
│  │  EGRESS allowed to:                                      │    │
│  │    kafka namespace             → :9404, :9308            │    │
│  │    :53 UDP/TCP                 (DNS)                     │    │
│  └──────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────┘
```

---

### Component 15 — Message Flow (End-to-End)

**Producer → Broker → Consumer with all components in the path:**

```
Producer Application
  (e.g. payments service)
       │
       │ 1. Lookup schema
       │    GET http://schema-registry:8081/subjects/payments.orders.created.v1-value/versions/latest
       │    ← schema_id=1, Avro schema
       │
       │ 2. Serialize payload with Avro, prepend [0x00][schema_id]
       │
       │ 3. ProduceRequest to bootstrap: production-kafka-kafka-bootstrap:9092
       │    Kafka client fetches cluster metadata → routes to partition leader
       │
       ▼
Kafka Broker (partition leader, e.g. combined-1)
       │
       │ 4. Append to log: /var/kafka/data/payments.orders.created.v1-2/
       │    Offset 1005 written
       │
       │ 5. Replicate to ISR followers (combined-0, combined-2) via :9091
       │    Wait for min.insync.replicas=2 ACKs
       │
       │ 6. Return offset=1005 to producer
       │
       │ 7. JMX Exporter exposes MessagesInPerSec on :9404
       │    Prometheus scrapes → Grafana shows "Strimzi Kafka" dashboard spike
       │
       ▼
Consumer Application (payments-service-group)
       │
       │ 8. FetchRequest(partition=2, offset=1005)
       │    ← message bytes
       │
       │ 9. Extract schema_id from first 5 bytes
       │    GET http://schema-registry:8081/schemas/ids/1
       │    ← Avro schema (cached after first call)
       │
       │ 10. Deserialize Avro payload
       │
       │ 11. CommitOffset(group=payments-service-group, partition=2, offset=1005)
       │     Stored in __consumer_offsets topic
       │
       │ 12. Kafka Exporter detects committed_offset == end_offset
       │     kafka_consumergroup_lag → 0
       │     Grafana "Kafka Exporter" dashboard: lag drops to 0
       ▼
Business logic processes event
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
