# 03-observability — Prometheus, Grafana, Fluent Bit

You want to know if something is broken before Bob calls your cell phone at 6pm. That's it. That's the whole point of this directory.

Sally called this the "early warning system." The SA called it "the thing that tells me what broke before the tickets pile up." Jim called it "the reason we can actually go to happy hour without our phones buzzing every 20 minutes."

Here's what it does: Prometheus scrapes metrics from everything. Grafana shows it to humans. Fluent Bit ships all container logs to CloudWatch, which keeps them for 365 days because NIST says so and also because you will absolutely need a log from three months ago at least once.

Grafana uses Keycloak for login — users don't get local Grafana accounts. They log in with their AD credentials via Keycloak. One less password for the SA to reset.

**What this deploys:**
- `kube-prometheus-stack` — Prometheus, Alertmanager, and Grafana in one shot
- Fluent Bit daemonset — one pod per node, ships logs to CloudWatch via IRSA (no credentials in the pod)

---

## Estimated Monthly Cost

| Resource | Details | Est. $/month |
|----------|---------|-------------|
| Prometheus PVC (50 Gi gp3, 30-day retention) | Metrics storage | ~$5 |
| ALB for Grafana | Same as Keycloak ALB — one per service | ~$6–8 |
| CloudWatch Logs ingestion (Fluent Bit) | ~5–20 GB/month for a small cluster at $0.50/GB | ~$3–10 |
| CloudWatch Logs storage (365-day retention) | Accumulates over time — ~$0.03/GB/month | ~$2–15 |
| **Additional cost this layer** | | **~$15–40/month** |

CloudWatch log costs grow with cluster activity. A quiet cluster with 3–4 nodes and low-traffic apps generates maybe 5 GB/month. A busy cluster with lots of pod churn can hit 20+ GB/month. Check the CloudWatch usage metrics after the first week to calibrate.

---

## Full-Stack Cost Summary

Once everything in this repo is deployed, here's the combined monthly estimate:

| Layer | What's running | Est. $/month |
|-------|---------------|-------------|
| 01-network | 3 VPCs, 3 NAT Gateways, flow logs | ~$120–135 |
| 02-identity | Managed AD (Standard), Secrets Manager | ~$40–50 |
| 03-workspaces | WorkSpaces (AutoStop vs AlwaysOn × user count) | ~$30–85 per user |
| 04-kubernetes | EKS cluster + 2–4 × m5.large nodes | ~$255–430 |
| k8s: Keycloak | ALB, runs on existing nodes | ~$6–8 |
| k8s: Kafka | 6 PVCs, likely +1 node | ~$15–100 |
| k8s: Observability | Prometheus PVC, ALB, CloudWatch logs | ~$15–40 |
| **Total (excl. WorkSpaces)** | | **~$450–760/month** |

Add WorkSpaces on top:

| Team size | WorkSpaces add | **Grand total** |
|-----------|---------------|----------------|
| 1 user | ~$30–85 | **~$480–845/month** |
| 10 users | ~$300–850 | **~$750–1,610/month** |
| 50 users | ~$1,500–4,250 | **~$1,950–5,010/month** |

> These are estimates based on default configuration and `us-gov-west-1` pricing as of early 2025. Actual costs vary with traffic, log volume, and autoscaling. Run the [AWS Pricing Calculator](https://calculator.aws) with your specific numbers before sending a budget to the contracting officer.

---

## Files in This Directory

| File | What to change |
|------|---------------|
| `prometheus-stack-values.yaml` | `# <---- change me` lines: Grafana domain, cert ARN, Keycloak OAuth URLs, client secret |
| `fluent-bit-values.yaml` | `# <---- change me` lines: IRSA role ARN, region if not `us-gov-west-1` |
| `namespace.yaml` | Nothing — deploy as-is |

---

## Before You Start

### Prerequisites — kubectl must be connected

Your SSM tunnel needs to be active before any of the commands below will work. Quick check:

```bash
kubectl get nodes
# If this hangs or errors, start the SSM tunnel first (see terraform/04-kubernetes/ Step 2)
```

Also confirm Keycloak is running before deploying this stack — Grafana's login depends on it:

```bash
kubectl get pods -n platform-auth
# Should show keycloak-* and postgresql-* pods in Running state
```

### 1. Note all the `# <---- change me` lines

**In `prometheus-stack-values.yaml`:**
- `root_url` — your Grafana domain, e.g. `https://grafana.internal.corp.example.gov`
- `client_secret` — create a `grafana` client in Keycloak first, copy the secret
- `auth_url`, `token_url`, `api_url` — replace `auth.internal.example.gov` with your actual Keycloak domain
- `alb.ingress.kubernetes.io/certificate-arn` — your ACM cert ARN
- `hosts` — your Grafana domain

**In `fluent-bit-values.yaml`:**
- `eks.amazonaws.com/role-arn` — create below, paste the ARN in

### 2. Create the Grafana client in Keycloak

Before deploying, log into your Keycloak admin console and:
1. Go to your `platform` realm → Clients → Create
2. Client ID: `grafana`
3. Client Protocol: `openid-connect`
4. Access Type: `confidential`
5. Valid Redirect URIs: `https://grafana.internal.corp.example.gov/*`  ← your domain
6. Save → Credentials tab → copy the Secret

Paste that secret into `prometheus-stack-values.yaml` at the `client_secret` line.

### 3. Create the Grafana admin secret

```bash
kubectl apply -f namespace.yaml

kubectl create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='YourGrafanaAdminPassword' \   # <---- change me
  -n observability
```

### 4. Create the IRSA role for Fluent Bit

Fluent Bit needs to write to CloudWatch. It does this via a short-lived IAM token, not a credential in the pod.

```bash
CLUSTER_NAME=falcon-park-dev                            # <---- change me
AWS_REGION=us-gov-west-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ISSUER=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed 's|https://||')

aws iam create-role \
  --role-name ${CLUSTER_NAME}-fluent-bit-irsa \
  --assume-role-policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Principal\":{\"Federated\":\"arn:aws-us-gov:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}\"},
      \"Action\":\"sts:AssumeRoleWithWebIdentity\",
      \"Condition\":{\"StringEquals\":{
        \"${OIDC_ISSUER}:sub\":\"system:serviceaccount:observability:fluent-bit\",
        \"${OIDC_ISSUER}:aud\":\"sts.amazonaws.com\"
      }}
    }]
  }"

aws iam put-role-policy \
  --role-name ${CLUSTER_NAME}-fluent-bit-irsa \
  --policy-name cloudwatch-logs \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\",\"logs:DescribeLogStreams\"],
      \"Resource\":\"arn:aws-us-gov:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/eks/*\"
    }]
  }"

echo "arn:aws-us-gov:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-fluent-bit-irsa"
```

Copy that ARN into `fluent-bit-values.yaml` at the `eks.amazonaws.com/role-arn` line.

---

## Step 1 — Apply the Namespace

```bash
kubectl apply -f namespace.yaml
```

---

## Step 2 — Deploy Prometheus + Grafana

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace observability \
  --version 82.10.3 \
  --values prometheus-stack-values.yaml \
  --wait --timeout 10m
```

---

## Step 3 — Deploy Fluent Bit

```bash
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace observability \
  --version 0.56.0 \
  --values fluent-bit-values.yaml \
  --set "daemonSetVolumes[0].hostPath.path=/var/log" \
  --wait --timeout 5m
```

---

## Step 4 — Verify

```bash
kubectl get pods -n observability
```

Expected: Prometheus pods, Alertmanager pods, Grafana pod, Fluent Bit pods (one per node), all `Running`.

```bash
kubectl get ingress -n observability
```

Get the ALB DNS name, create a CNAME for your Grafana domain pointing at it.

Confirm logs are flowing to CloudWatch:

```bash
aws logs describe-log-streams \
  --log-group-name /eks/falcon-park-dev/containers \      # <---- change me to your cluster name
  --region us-gov-west-1 \
  --order-by LastEventTime \
  --descending \
  --max-items 5
```

You should see log streams from your nodes. If you see streams, logs are flowing. Bob can call all he wants — you'll see his desktop logs before he finishes dialing.

---

## You're Done

The full stack is deployed:

- ✅ Hub-and-spoke network (10.x.x.x, VPC peering)
- ✅ Managed AD + GitLab OIDC (no credentials anywhere)
- ✅ WorkSpaces (Bob has his desktop)
- ✅ EKS cluster (private endpoint, IRSA, encrypted)
- ✅ Keycloak (OIDC broker, AD-backed)
- ✅ Kafka (mTLS, operator-managed)
- ✅ Prometheus + Grafana + Fluent Bit (Keycloak SSO, 365-day logs)

Go to happy hour. You've earned it. Leave Slack notifications on your phone — but only because you want to, not because you have to.

---

## Troubleshooting

Paste the error below and drop this whole file into Claude or ChatGPT: *"I'm deploying kube-prometheus-stack and Fluent Bit on EKS in AWS GovCloud. Here's my error."*

---

### Paste Error Output Below

```
<paste kubectl or helm output here>
```

---

**Common issues:**

| Error | What it means | Fix |
|-------|---------------|-----|
| Grafana pod in `CrashLoopBackOff` | Missing `grafana-admin` secret | Create the secret: `kubectl create secret generic grafana-admin ...` |
| Fluent Bit pods running but no CloudWatch logs | Wrong IRSA role ARN or log group doesn't exist | Confirm the log group exists and the ARN in `fluent-bit-values.yaml` is correct |
| Grafana login shows "Login with Keycloak" but fails | OAuth URLs wrong or Keycloak client misconfigured | Double-check all four `# <---- change me` URL lines in `prometheus-stack-values.yaml` match your actual Keycloak domain |
| Prometheus targets all `DOWN` | Service monitors not matching | Run `kubectl get servicemonitors -A` — if empty, check `serviceMonitorSelectorNilUsesHelmValues` is false |
| PVCs stuck in `Pending` | No default storage class | Confirm gp3 StorageClass exists: `kubectl get storageclass` |
