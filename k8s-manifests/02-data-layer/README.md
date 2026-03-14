# 02-data-layer — Kafka

Your apps need to talk to each other without being directly coupled. One service produces an event. Another consumes it. Neither knows the other exists. This is Kafka's whole job.

Jim described it as a conveyor belt in a factory. "Stuff goes in one end, comes out the other, nobody on either end cares how the belt works." Sally said that was a terrible analogy but she understood it. The SA asked if this meant fewer direct database connections to manage. It does. The SA was pleased.

The Strimzi operator manages the Kafka lifecycle. You define what you want in a YAML file. Strimzi makes it happen. No `kafka-topics.sh` on a remote server. No manual ACL commands. You write a `KafkaTopic` resource. It exists.

**What this deploys:**
- Strimzi Kafka operator (manages the cluster via Kubernetes CRDs)
- A 3-broker Kafka cluster with ZooKeeper, persistent storage, mTLS internal auth
- Topic and User operators (manage topics and ACLs via CRs, not CLI)

---

## Files in This Directory

| File | What to change |
|------|---------------|
| `kafka-cluster.yaml` | Kafka version if a newer one is available, storage size if 50Gi is too small |
| `strimzi-operator.yaml` | Strimzi version — pin it |
| `namespace.yaml` | Nothing — deploy as-is |

---

## Before You Start

Make sure your EKS cluster is up and your kubeconfig is pointing at it:

```bash
kubectl get nodes
# Should show nodes in Ready state
```

---

## Step 1 — Apply the Namespace

```bash
kubectl apply -f namespace.yaml
```

---

## Step 2 — Deploy the Strimzi Operator

```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update

helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace data-layer \
  --set watchNamespaces="{data-layer}" \
  --version 0.41.0 \                   # <---- change me if a newer version is available: https://github.com/strimzi/strimzi-kafka-operator/releases
  --wait --timeout 5m
```

Verify the operator is running:

```bash
kubectl get pods -n data-layer
# Expected: strimzi-cluster-operator-* in Running state
```

---

## Step 3 — Deploy the Kafka Cluster

```bash
kubectl apply -f kafka-cluster.yaml
```

Then wait for it to be ready. This takes a few minutes — Strimzi is creating 3 Kafka pods and 3 ZooKeeper pods, each with a persistent volume:

```bash
kubectl wait kafka/main \
  --for=condition=Ready \
  --timeout=300s \
  -n data-layer
```

---

## Step 4 — Verify

```bash
kubectl get pods -n data-layer
```

Expected: 3 `main-kafka-*` pods, 3 `main-zookeeper-*` pods, and operator pods, all `Running`.

```bash
kubectl get kafka main -n data-layer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Should return: True
```

---

## Creating a Topic

Don't use `kafka-topics.sh`. Use a `KafkaTopic` resource instead. Here's the pattern:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: my-first-topic          # <---- change me
  namespace: data-layer
  labels:
    strimzi.io/cluster: main
spec:
  partitions: 3
  replicas: 3
  config:
    retention.ms: 604800000     # 7 days
```

```bash
kubectl apply -f my-topic.yaml
```

---

## Creating a User (with ACLs)

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: my-producer-app         # <---- change me
  namespace: data-layer
  labels:
    strimzi.io/cluster: main
spec:
  authentication:
    type: tls
  authorization:
    type: simple
    acls:
      - resource:
          type: topic
          name: my-first-topic  # <---- change me to your topic name
        operations: [Write, Describe]
```

Strimzi creates the TLS cert for the user and puts it in a Kubernetes secret. Your app mounts the secret and uses it to authenticate to Kafka.

---

## Troubleshooting

Paste the error below and drop this whole file into Claude or ChatGPT: *"I'm deploying Strimzi Kafka on EKS in AWS GovCloud. Here's my error."*

---

### Paste Error Output Below

```
<paste kubectl output here>
```

---

**Common issues:**

| Error | What it means | Fix |
|-------|---------------|-----|
| Kafka pods stuck in `Pending` | PVCs not binding | Check `kubectl get pvc -n data-layer` — make sure gp3 storage class exists |
| `kafka/main not found` after apply | Strimzi CRDs not installed yet | Wait for operator to fully start: `kubectl get crds \| grep kafka` |
| ZooKeeper pods crashing | Usually resource pressure | Check node capacity: `kubectl top nodes` |
| `Timeout waiting for condition` | Cluster taking longer than 5 min | Run the wait command again with `--timeout=600s` |
