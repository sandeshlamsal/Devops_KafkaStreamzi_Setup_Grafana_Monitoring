# Production-Grade Strimzi Kafka Setup with Grafana Monitoring

## Overview

This repository documents the end-to-end setup of Apache Kafka on Kubernetes using **Strimzi Operator**, with production-grade observability via **Prometheus** and **Grafana**. It covers cluster bootstrapping, topic/user management, TLS security, schema registry, Connect, and alerting.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                       │
│                                                                 │
│  ┌──────────────┐   ┌──────────────┐   ┌────────────────────┐  │
│  │   Strimzi    │   │    Kafka     │   │    ZooKeeper /     │  │
│  │   Operator   │──▶│   Brokers   │   │  KRaft (3 nodes)   │  │
│  └──────────────┘   └──────┬───────┘   └────────────────────┘  │
│                            │                                    │
│  ┌──────────────────────────▼──────────────────────────────┐   │
│  │                   Kafka Ecosystem                        │   │
│  │  Kafka Connect │ Schema Registry │ Kafka Bridge │ MM2   │   │
│  └──────────────────────────┬────────────────────────────────┘  │
│                             │                                   │
│  ┌──────────────────────────▼──────────────────────────────┐   │
│  │                 Observability Stack                      │   │
│  │  JMX Exporter → Prometheus → Grafana │ AlertManager     │   │
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
| `kustomize` | >= 5.0 | Manifest management |
| `kafkacat` / `kcat` | latest | Kafka CLI testing |
| `openssl` | >= 3.0 | TLS certificate generation |

### Kubernetes Requirements

- Kubernetes >= 1.27 (EKS / GKE / AKS / on-prem)
- Minimum node specs for production brokers: **4 vCPU, 16 GB RAM, 500 GB SSD**
- StorageClass with `WaitForFirstConsumer` binding mode and `Retain` reclaim policy
- Dedicated node pool for Kafka brokers (via taints/tolerations)

### Namespace Setup

```bash
kubectl create namespace kafka
kubectl create namespace monitoring
kubectl label namespace kafka strimzi.io/cluster=true
```

---

## 2. Repository Structure

```
.
├── strimzi/
│   ├── operator/
│   │   └── strimzi-operator.yaml        # CRDs + Operator deployment
│   ├── cluster/
│   │   ├── kafka-cluster.yaml           # Main Kafka cluster CR
│   │   ├── kafka-cluster-kraft.yaml     # KRaft-mode variant
│   │   └── node-pool.yaml               # KafkaNodePool CR
│   ├── topics/
│   │   ├── kafka-topic-template.yaml
│   │   └── topics/                      # Per-topic CR files
│   ├── users/
│   │   └── kafka-user.yaml              # KafkaUser CRs with ACLs
│   ├── connect/
│   │   ├── kafka-connect.yaml
│   │   └── connectors/
│   ├── mirror-maker/
│   │   └── kafka-mirror-maker2.yaml
│   └── schema-registry/
│       └── schema-registry.yaml
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus-operator.yaml
│   │   ├── prometheus.yaml
│   │   ├── servicemonitor-kafka.yaml
│   │   └── rules/
│   │       └── kafka-alerts.yaml
│   ├── grafana/
│   │   ├── grafana.yaml
│   │   ├── datasource-prometheus.yaml
│   │   └── dashboards/
│   │       ├── kafka-overview.json
│   │       ├── kafka-topics.json
│   │       ├── kafka-consumer-lag.json
│   │       └── zookeeper.json
│   └── alertmanager/
│       ├── alertmanager.yaml
│       └── alertmanager-config.yaml
├── storage/
│   └── storageclass.yaml
├── network-policies/
│   ├── kafka-network-policy.yaml
│   └── monitoring-network-policy.yaml
└── scripts/
    ├── install.sh
    ├── verify-cluster.sh
    └── generate-certs.sh
```

---

## 3. Strimzi Operator Installation

### Option A: Helm (Recommended)

```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update

helm install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --set watchNamespaces="{kafka}" \
  --set resources.requests.memory=512Mi \
  --set resources.requests.cpu=200m \
  --set resources.limits.memory=1Gi \
  --set resources.limits.cpu=1000m \
  --version 0.44.0
```

### Option B: YAML Manifests

```bash
# Install CRDs and operator
kubectl apply -f "https://strimzi.io/install/latest?namespace=kafka" -n kafka

# Verify operator is running
kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator \
  -n kafka --timeout=120s
```

### Verify Installation

```bash
kubectl get pods -n kafka
kubectl get crds | grep kafka
# Expected CRDs: kafkas, kafkatopics, kafkausers, kafkaconnects,
#                kafkamirrormaker2s, kafkabridges, kafkanodepools
```

---

## 4. Kafka Cluster Deployment

### `strimzi/cluster/kafka-cluster.yaml`

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: production-kafka
  namespace: kafka
spec:
  kafka:
    version: 3.7.0
    replicas: 3
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
      - name: external
        port: 9094
        type: loadbalancer
        tls: true
        authentication:
          type: tls
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
      log.message.format.version: "3.7"
      inter.broker.protocol.version: "3.7"
      log.retention.hours: 168
      log.segment.bytes: 1073741824
      log.retention.check.interval.ms: 300000
      num.network.threads: 8
      num.io.threads: 16
      socket.send.buffer.bytes: 102400
      socket.receive.buffer.bytes: 102400
      socket.request.max.bytes: 104857600
    storage:
      type: jbod
      volumes:
        - id: 0
          type: persistent-claim
          size: 500Gi
          class: kafka-storage
          deleteClaim: false
    resources:
      requests:
        memory: 8Gi
        cpu: "2"
      limits:
        memory: 16Gi
        cpu: "4"
    jvmOptions:
      -Xms: 4096m
      -Xmx: 4096m
      gcLoggingEnabled: false
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef:
          name: kafka-metrics-config
          key: kafka-metrics-config.yml
    template:
      pod:
        tolerations:
          - key: "kafka-broker"
            operator: "Exists"
            effect: "NoSchedule"
        affinity:
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector:
                  matchExpressions:
                    - key: strimzi.io/name
                      operator: In
                      values:
                        - production-kafka-kafka
                topologyKey: kubernetes.io/hostname
  zookeeper:
    replicas: 3
    storage:
      type: persistent-claim
      size: 100Gi
      class: kafka-storage
      deleteClaim: false
    resources:
      requests:
        memory: 2Gi
        cpu: "500m"
      limits:
        memory: 4Gi
        cpu: "1"
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef:
          name: kafka-metrics-config
          key: zookeeper-metrics-config.yml
  entityOperator:
    topicOperator:
      resources:
        requests:
          memory: 512Mi
          cpu: 200m
        limits:
          memory: 1Gi
          cpu: 500m
    userOperator:
      resources:
        requests:
          memory: 512Mi
          cpu: 200m
        limits:
          memory: 1Gi
          cpu: 500m
```

```bash
kubectl apply -f strimzi/cluster/kafka-cluster.yaml -n kafka

# Monitor rollout
kubectl wait kafka/production-kafka --for=condition=Ready \
  --timeout=600s -n kafka
```

---

## 5. KRaft Mode (ZooKeeper-less)

For Kafka 3.7+ production deployments, prefer KRaft mode (removes ZooKeeper dependency).

### `strimzi/cluster/node-pool.yaml`

```yaml
# Controller pool
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller
  namespace: kafka
  labels:
    strimzi.io/cluster: production-kafka
spec:
  replicas: 3
  roles:
    - controller
  storage:
    type: persistent-claim
    size: 100Gi
    class: kafka-storage
    deleteClaim: false
  resources:
    requests:
      memory: 4Gi
      cpu: "1"
    limits:
      memory: 8Gi
      cpu: "2"
---
# Broker pool
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  namespace: kafka
  labels:
    strimzi.io/cluster: production-kafka
spec:
  replicas: 3
  roles:
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 500Gi
        class: kafka-storage
        deleteClaim: false
  resources:
    requests:
      memory: 8Gi
      cpu: "2"
    limits:
      memory: 16Gi
      cpu: "4"
```

### `strimzi/cluster/kafka-cluster-kraft.yaml`

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
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls
      - name: external
        port: 9094
        type: loadbalancer
        tls: true
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
    storage:
      type: jbod
      volumes:
        - id: 0
          type: persistent-claim
          size: 500Gi
          class: kafka-storage
          deleteClaim: false
  # No zookeeper section in KRaft mode
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

---

## 6. TLS and Authentication

### Mutual TLS (mTLS) — Client Certificate Auth

Strimzi automatically generates a cluster CA. Extract the CA cert for clients:

```bash
# Get cluster CA certificate
kubectl get secret production-kafka-cluster-ca-cert \
  -n kafka -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt

# Get cluster CA key (for signing client certs manually)
kubectl get secret production-kafka-cluster-ca \
  -n kafka -o jsonpath='{.data.ca\.key}' | base64 -d > ca.key
```

### SCRAM-SHA-512 Authentication (alternative)

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

### `strimzi/topics/kafka-topic-template.yaml`

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders-events
  namespace: kafka
  labels:
    strimzi.io/cluster: production-kafka
spec:
  partitions: 12
  replicas: 3
  config:
    retention.ms: "604800000"        # 7 days
    segment.bytes: "1073741824"      # 1 GiB segments
    min.insync.replicas: "2"
    compression.type: lz4
    cleanup.policy: delete
```

```bash
kubectl apply -f strimzi/topics/

# Verify topics
kubectl get kafkatopics -n kafka
```

**Topic Naming Convention:**

```
<domain>.<entity>.<event-type>.<version>
# e.g.: payments.orders.created.v1
#       inventory.products.updated.v2
```

---

## 8. User Management (ACLs)

### `strimzi/users/kafka-user.yaml`

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
      # Producer ACL
      - resource:
          type: topic
          name: payments.orders.created.v1
          patternType: literal
        operations: [Write, Describe]
        host: "*"
      # Consumer ACL
      - resource:
          type: topic
          name: payments.orders.created.v1
          patternType: literal
        operations: [Read, Describe]
        host: "*"
      - resource:
          type: group
          name: payments-service-group
          patternType: literal
        operations: [Read]
        host: "*"
```

```bash
kubectl apply -f strimzi/users/kafka-user.yaml -n kafka

# Extract user certificate and key for application config
kubectl get secret payments-service -n kafka \
  -o jsonpath='{.data.user\.crt}' | base64 -d > user.crt
kubectl get secret payments-service -n kafka \
  -o jsonpath='{.data.user\.key}' | base64 -d > user.key
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
  replicas: 3
  bootstrapServers: production-kafka-kafka-bootstrap:9093
  tls:
    trustedCertificates:
      - secretName: production-kafka-cluster-ca-cert
        certificate: ca.crt
  authentication:
    type: tls
    certificateAndKey:
      secretName: connect-user
      certificate: user.crt
      key: user.key
  config:
    group.id: connect-cluster
    offset.storage.topic: connect-offsets
    config.storage.topic: connect-configs
    status.storage.topic: connect-status
    config.storage.replication.factor: 3
    offset.storage.replication.factor: 3
    status.storage.replication.factor: 3
    key.converter: org.apache.kafka.connect.storage.StringConverter
    value.converter: io.confluent.connect.avro.AvroConverter
    value.converter.schema.registry.url: http://schema-registry:8081
  build:
    output:
      type: docker
      image: your-registry/kafka-connect:latest
    plugins:
      - name: debezium-postgres
        artifacts:
          - type: tgz
            url: https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/2.6.0.Final/debezium-connector-postgres-2.6.0.Final-plugin.tar.gz
      - name: kafka-connect-s3
        artifacts:
          - type: jar
            url: https://packages.confluent.io/maven/io/confluent/kafka-connect-s3/10.5.0/kafka-connect-s3-10.5.0.jar
  resources:
    requests:
      memory: 2Gi
      cpu: "1"
    limits:
      memory: 4Gi
      cpu: "2"
  metricsConfig:
    type: jmxPrometheusExporter
    valueFrom:
      configMapKeyRef:
        name: kafka-metrics-config
        key: connect-metrics-config.yml
```

---

## 10. Schema Registry

Deploy Confluent Schema Registry (or Apicurio) alongside Kafka.

### `strimzi/schema-registry/schema-registry.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: schema-registry
  namespace: kafka
spec:
  replicas: 2
  selector:
    matchLabels:
      app: schema-registry
  template:
    metadata:
      labels:
        app: schema-registry
    spec:
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
              value: "production-kafka-kafka-bootstrap:9093"
            - name: SCHEMA_REGISTRY_KAFKASTORE_SECURITY_PROTOCOL
              value: SSL
            - name: SCHEMA_REGISTRY_KAFKASTORE_SSL_TRUSTSTORE_LOCATION
              value: /etc/schema-registry/secrets/truststore.jks
            - name: SCHEMA_REGISTRY_LISTENERS
              value: "http://0.0.0.0:8081"
          resources:
            requests:
              memory: 1Gi
              cpu: 500m
            limits:
              memory: 2Gi
              cpu: "1"
---
apiVersion: v1
kind: Service
metadata:
  name: schema-registry
  namespace: kafka
spec:
  selector:
    app: schema-registry
  ports:
    - port: 8081
      targetPort: 8081
```

---

## 11. MirrorMaker 2 (Multi-cluster Replication)

### `strimzi/mirror-maker/kafka-mirror-maker2.yaml`

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
      authentication:
        type: tls
        certificateAndKey:
          secretName: mirror-maker-source-user
          certificate: user.crt
          key: user.key
    - alias: "target-cluster"
      bootstrapServers: production-kafka-kafka-bootstrap:9093
      tls:
        trustedCertificates:
          - secretName: production-kafka-cluster-ca-cert
            certificate: ca.crt
      authentication:
        type: tls
        certificateAndKey:
          secretName: mirror-maker-target-user
          certificate: user.crt
          key: user.key
  mirrors:
    - sourceCluster: "source-cluster"
      targetCluster: "target-cluster"
      sourceConnector:
        config:
          replication.factor: 3
          offset-syncs.topic.replication.factor: 3
          sync.topic.acls.enabled: "false"
          replication.policy.separator: "."
          replication.policy.class: "org.apache.kafka.connect.mirror.IdentityReplicationPolicy"
      heartbeatConnector:
        config:
          heartbeats.topic.replication.factor: 3
      checkpointConnector:
        config:
          checkpoints.topic.replication.factor: 3
          sync.group.offsets.enabled: "true"
      topicsPattern: ".*"
      groupsPattern: ".*"
  resources:
    requests:
      memory: 2Gi
      cpu: "1"
    limits:
      memory: 4Gi
      cpu: "2"
```

---

## 12. Prometheus Integration

### JMX Exporter ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-metrics-config
  namespace: kafka
data:
  kafka-metrics-config.yml: |
    lowercaseOutputName: true
    rules:
      - pattern: kafka.server<type=(.+), name=(.+), clientId=(.+), topic=(.+), partition=(.*)><>Value
        name: kafka_server_$1_$2
        type: GAUGE
        labels:
          clientId: "$3"
          topic: "$4"
          partition: "$5"
      - pattern: kafka.server<type=(.+), name=(.+), clientId=(.+), brokerHost=(.+), brokerPort=(.+)><>Value
        name: kafka_server_$1_$2
        type: GAUGE
        labels:
          clientId: "$3"
          broker: "$4:$5"
      - pattern: kafka.server<type=(.+), name=(.+)><>Value
        name: kafka_server_$1_$2
        type: GAUGE
      - pattern: kafka.(\w+)<type=(.+), name=(.+)><>Value
        name: kafka_$1_$2_$3
        type: GAUGE
      - pattern: ".*"
```

### Prometheus Operator + ServiceMonitor

```bash
# Install kube-prometheus-stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=standard \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=100Gi \
  --version 58.0.0
```

### `monitoring/prometheus/servicemonitor-kafka.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kafka-servicemonitor
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - kafka
  selector:
    matchLabels:
      strimzi.io/kind: Kafka
  endpoints:
    - port: tcp-prometheus
      path: /metrics
      interval: 30s
      scheme: http
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kafka-connect-servicemonitor
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - kafka
  selector:
    matchLabels:
      strimzi.io/kind: KafkaConnect
  endpoints:
    - port: tcp-prometheus
      path: /metrics
      interval: 30s
```

---

## 13. Grafana Dashboards

### Access Grafana

```bash
# Port-forward Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana \
  3000:80 -n monitoring

# Get admin password
kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

### Recommended Dashboards (Import by ID)

| Dashboard | Grafana ID | Description |
|-----------|-----------|-------------|
| Kafka Overview | 7589 | Broker metrics, throughput, partitions |
| Kafka Topics | 12460 | Per-topic metrics |
| Consumer Lag | 12479 | Consumer group lag monitoring |
| Kafka Connect | 11285 | Connector status and throughput |
| ZooKeeper | 10465 | ZooKeeper ensemble health |
| JVM Overview | 8563 | JVM memory, GC, threads |

### Import via ConfigMap (GitOps)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-overview-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  kafka-overview.json: |
    <paste dashboard JSON here>
```

---

## 14. Alerting with AlertManager

### `monitoring/prometheus/rules/kafka-alerts.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kafka-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: kafka.broker
      rules:
        - alert: KafkaBrokerDown
          expr: count(up{job="kafka"} == 0) > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Kafka broker is down"
            description: "{{ $value }} Kafka broker(s) are not reachable."

        - alert: KafkaUnderReplicatedPartitions
          expr: kafka_server_replicamanager_underreplicatedpartitions > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Under-replicated partitions detected"
            description: "Broker {{ $labels.pod }} has {{ $value }} under-replicated partitions."

        - alert: KafkaOfflinePartitions
          expr: kafka_controller_kafkacontroller_offlinepartitionscount > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Offline partitions detected"
            description: "There are {{ $value }} offline partitions."

        - alert: KafkaConsumerLagHigh
          expr: sum(kafka_consumer_group_lag) by (group, topic) > 10000
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "High consumer lag"
            description: "Consumer group {{ $labels.group }} on topic {{ $labels.topic }} has lag {{ $value }}."

        - alert: KafkaDiskUsageHigh
          expr: >
            (kubelet_volume_stats_used_bytes{persistentvolumeclaim=~"data-.*kafka.*"} /
             kubelet_volume_stats_capacity_bytes{persistentvolumeclaim=~"data-.*kafka.*"}) > 0.80
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Kafka disk usage above 80%"
            description: "PVC {{ $labels.persistentvolumeclaim }} is {{ $value | humanizePercentage }} full."

        - alert: KafkaISRShrinkage
          expr: kafka_server_replicamanager_isrshrinkspersec > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "ISR shrinkage detected"
            description: "ISR shrinkage occurring on broker {{ $labels.pod }}."
```

### AlertManager Config (Slack + PagerDuty)

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: kafka-alertmanager-config
  namespace: monitoring
spec:
  route:
    groupBy: ["alertname", "cluster"]
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 12h
    receiver: slack-critical
    routes:
      - matchers:
          - name: severity
            value: critical
        receiver: pagerduty-critical
      - matchers:
          - name: severity
            value: warning
        receiver: slack-warning
  receivers:
    - name: slack-critical
      slackConfigs:
        - apiURL:
            name: alertmanager-secrets
            key: slack-webhook-url
          channel: "#kafka-critical"
          title: "CRITICAL: {{ .GroupLabels.alertname }}"
          text: "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"
    - name: pagerduty-critical
      pagerdutyConfigs:
        - routingKey:
            name: alertmanager-secrets
            key: pagerduty-routing-key
          description: "{{ .GroupLabels.alertname }}: {{ .CommonAnnotations.summary }}"
    - name: slack-warning
      slackConfigs:
        - apiURL:
            name: alertmanager-secrets
            key: slack-webhook-url
          channel: "#kafka-warnings"
```

---

## 15. Storage Configuration

### `storage/storageclass.yaml`

```yaml
# For AWS EKS (gp3)
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

**Storage Best Practices:**

- Use `Retain` reclaim policy — prevent accidental data loss on PVC delete
- Use `WaitForFirstConsumer` — ensures PVCs are created in the same AZ as the pod
- Enable volume expansion for online resizing
- Use SSDs (gp3 on AWS, pd-ssd on GCP) for broker data volumes
- Separate volumes for data and logs where possible

---

## 16. Network Policies

### `network-policies/kafka-network-policy.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafka-broker-network-policy
  namespace: kafka
spec:
  podSelector:
    matchLabels:
      strimzi.io/kind: Kafka
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow from Strimzi operator
    - from:
        - podSelector:
            matchLabels:
              name: strimzi-cluster-operator
      ports:
        - port: 9090
        - port: 9091
    # Allow broker-to-broker replication
    - from:
        - podSelector:
            matchLabels:
              strimzi.io/kind: Kafka
      ports:
        - port: 9091
    # Allow clients within kafka namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kafka
      ports:
        - port: 9092
        - port: 9093
    # Allow Prometheus scraping
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - port: 9404
  egress:
    - to:
        - podSelector:
            matchLabels:
              strimzi.io/kind: Kafka
    - to:
        - podSelector:
            matchLabels:
              strimzi.io/kind: ZooKeeper
    - ports:
        - port: 53
          protocol: UDP
```

---

## 17. Scaling and Performance Tuning

### Horizontal Scaling (Add Brokers)

```bash
# Scale broker count (ZooKeeper-mode)
kubectl patch kafka production-kafka -n kafka \
  --type=merge -p '{"spec":{"kafka":{"replicas":5}}}'

# Scale with KafkaNodePool (KRaft-mode)
kubectl patch kafkanodepool broker -n kafka \
  --type=merge -p '{"spec":{"replicas":5}}'
```

### Partition Rebalancing with Cruise Control

Add Cruise Control to the Kafka CR for automated partition rebalancing:

```yaml
spec:
  cruiseControl:
    brokerCapacity:
      inboundNetwork: 10000KB/s
      outboundNetwork: 10000KB/s
    config:
      replication.throttle: 50000000
    resources:
      requests:
        memory: 1Gi
        cpu: 500m
      limits:
        memory: 2Gi
        cpu: "1"
```

```bash
# Trigger rebalance via KafkaRebalance CR
kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaRebalance
metadata:
  name: full-rebalance
  namespace: kafka
  labels:
    strimzi.io/cluster: production-kafka
spec:
  mode: full
EOF

# Approve rebalance
kubectl annotate kafkarebalance full-rebalance \
  strimzi.io/rebalance=approve -n kafka
```

### Producer/Consumer Tuning

**Producer (high-throughput):**
```properties
acks=all
retries=2147483647
max.in.flight.requests.per.connection=5
enable.idempotence=true
compression.type=lz4
batch.size=65536
linger.ms=5
buffer.memory=67108864
```

**Consumer (low-latency):**
```properties
fetch.min.bytes=1
fetch.max.wait.ms=10
max.poll.records=500
enable.auto.commit=false
isolation.level=read_committed
```

---

## 18. Backup and Recovery

### Topic Backup with MirrorMaker 2

Use MirrorMaker 2 to continuously replicate to a secondary cluster or cold storage region.

### Manual Offset Checkpoint

```bash
# Export consumer group offsets
kubectl exec -it production-kafka-kafka-0 -n kafka -- \
  bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --group my-consumer-group \
  --describe > consumer-offsets-backup.txt
```

### PVC Snapshot (Velero)

```bash
# Install Velero with CSI plugin
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --set-json 'configuration.features=["EnableCSI"]' \
  --set snapshotsEnabled=true

# Create scheduled backup
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

# 2. Upgrade operator (rolling)
helm upgrade strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --reuse-values \
  --version 0.45.0

# 3. Update Kafka version in CR (triggers rolling broker restart)
kubectl patch kafka production-kafka -n kafka \
  --type=merge -p '{"spec":{"kafka":{"version":"3.8.0","metadataVersion":"3.8-IV0"}}}'
```

**Upgrade Rules:**
- Upgrade Strimzi operator first, then update Kafka version in the CR
- Never skip more than one minor version of Strimzi
- Always check the Strimzi upgrade guide for breaking changes
- Test upgrades in staging before production

---

## 20. Troubleshooting

### Common Issues

| Symptom | Check | Resolution |
|---------|-------|------------|
| Broker pod stuck in `Pending` | `kubectl describe pod` | Check node capacity, PVC binding, taints |
| `NotLeaderForPartition` errors | Check under-replicated partitions | Wait for ISR recovery; check network |
| Consumer lag growing | Monitor `kafka_consumer_group_lag` | Scale consumers; increase partitions |
| OOM killed broker | JVM heap settings | Increase `-Xmx`; check heap dump |
| ZooKeeper session timeout | ZK leader election | Check ZK pod logs; ensure quorum |
| Topic operator reconcile loop | `kubectl logs entity-operator` | Check KafkaTopic CR status conditions |

### Useful Commands

```bash
# Kafka cluster status
kubectl get kafka production-kafka -n kafka -o yaml | grep -A5 conditions

# Broker logs
kubectl logs -f production-kafka-kafka-0 -n kafka -c kafka

# List topics
kubectl exec -it production-kafka-kafka-0 -n kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# Consumer group lag
kubectl exec -it production-kafka-kafka-0 -n kafka -- \
  bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --all-groups

# Describe KRaft quorum
kubectl exec -it production-kafka-kafka-0 -n kafka -- \
  bin/kafka-metadata-quorum.sh \
  --bootstrap-server localhost:9092 describe --status

# Check Strimzi operator logs
kubectl logs -f deploy/strimzi-cluster-operator -n kafka

# Force topic reconciliation
kubectl annotate kafkatopic my-topic \
  strimzi.io/force-reconcile=true -n kafka

# Inspect Prometheus metrics
kubectl port-forward svc/production-kafka-kafka-brokers 9404:9404 -n kafka
curl -s http://localhost:9404/metrics | grep kafka_server_broker
```

---

## Quick Start (All-in-One)

```bash
#!/bin/bash
# scripts/install.sh

set -euo pipefail

NAMESPACE_KAFKA=kafka
NAMESPACE_MONITORING=monitoring

echo "Creating namespaces..."
kubectl create namespace $NAMESPACE_KAFKA --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $NAMESPACE_MONITORING --dry-run=client -o yaml | kubectl apply -f -

echo "Installing Strimzi operator..."
helm repo add strimzi https://strimzi.io/charts/
helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  -n $NAMESPACE_KAFKA --version 0.44.0 --wait

echo "Applying storage class..."
kubectl apply -f storage/

echo "Deploying Kafka cluster..."
kubectl apply -f strimzi/cluster/ -n $NAMESPACE_KAFKA
kubectl wait kafka/production-kafka --for=condition=Ready \
  --timeout=600s -n $NAMESPACE_KAFKA

echo "Applying topics and users..."
kubectl apply -f strimzi/topics/ -n $NAMESPACE_KAFKA
kubectl apply -f strimzi/users/ -n $NAMESPACE_KAFKA

echo "Installing Prometheus + Grafana..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  -n $NAMESPACE_MONITORING --version 58.0.0 \
  -f monitoring/prometheus/values.yaml --wait

echo "Applying ServiceMonitors..."
kubectl apply -f monitoring/prometheus/ -n $NAMESPACE_MONITORING

echo "Applying alert rules..."
kubectl apply -f monitoring/prometheus/rules/ -n $NAMESPACE_MONITORING

echo "Done! Access Grafana:"
echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
```

---

## References

- [Strimzi Documentation](https://strimzi.io/docs/operators/latest/)
- [Strimzi GitHub](https://github.com/strimzi/strimzi-kafka-operator)
- [Apache Kafka KRaft Mode](https://kafka.apache.org/documentation/#kraft)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Strimzi Grafana Dashboards](https://github.com/strimzi/strimzi-kafka-operator/tree/main/examples/metrics)
- [Kafka Performance Tuning Guide](https://kafka.apache.org/documentation/#producerconfigs)
- [Cruise Control for Kafka](https://github.com/linkedin/cruise-control)
