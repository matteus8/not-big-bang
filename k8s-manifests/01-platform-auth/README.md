# 01-platform-auth — Keycloak

Every app in the cluster needs to know who's asking. Rather than having each app talk to AD directly (chaos), or maintaining separate user databases (more chaos), you put Keycloak in front of everything. Keycloak talks to AD. Apps talk to Keycloak. Users log in once.

Sally called this the bouncer. "One bouncer at the door. Nobody walks past the bouncer." Jim added that the bouncer uses OIDC, not a clipboard with a list of names. The SA appreciated that this meant one fewer password reset queue to manage.

**What this deploys:**
- Keycloak with two replicas (HA — one pod can die and users stay logged in)
- PostgreSQL backend for session persistence
- Internal ALB ingress (HTTPS only, TLS 1.3 minimum)
- IRSA on the Keycloak service account — it uses AWS Secrets Manager via short-lived token, no env vars

---

## Files in This Directory

| File | What to change |
|------|---------------|
| `keycloak-values.yaml` | `# <---- change me` lines: cert ARN, hostname, IRSA role ARN |
| `namespace.yaml` | Nothing — deploy as-is |

---

## Before You Start

### 0. Install the AWS Load Balancer Controller

Every `Ingress` in this stack — including Keycloak's — needs the AWS Load Balancer Controller to provision ALBs. Without it, your Ingress will sit there forever in `Pending` state.

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=falcon-park-dev \    # <---- change me
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 5m
```

Verify:
```bash
kubectl get deployment aws-load-balancer-controller -n kube-system
```

> The controller needs an IRSA role to create ALBs on your behalf. If the pods are crashlooping with `AccessDenied`, the service account needs an IAM role with `elasticloadbalancing:*` and `ec2:Describe*`. The [EKS LBC docs](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html) have the exact policy — one-time setup.

### 1. Note the `# <---- change me` lines in `keycloak-values.yaml`

Open the file. You'll find three things to fill in:

- **`alb.ingress.kubernetes.io/certificate-arn`** — your ACM certificate ARN for the Keycloak domain. If you don't have one yet, request it first:
  ```bash
  aws acm request-certificate \
    --domain-name auth.internal.corp.example.gov \    # <---- change me to your Keycloak domain
    --validation-method DNS \
    --region us-gov-west-1
  ```
  ACM will give you a CNAME record to add to your DNS for validation. Add it, wait a few minutes for it to go green, then grab the ARN:
  ```bash
  aws acm list-certificates --region us-gov-west-1
  ```

- **`hostname`** — the domain Keycloak will be reachable at, e.g. `auth.internal.corp.example.gov`. This needs a DNS record pointing to the ALB after deploy.

- **`eks.amazonaws.com/role-arn`** — create this after step 3 below, then come back and fill it in.

### 2. Create the Keycloak admin secret

```bash
kubectl apply -f namespace.yaml

kubectl create secret generic keycloak-admin \
  --from-literal=admin-password='YourStrongAdminPassword' \    # <---- change me
  -n platform-auth
```

### 3. Create the Keycloak Postgres secret

```bash
kubectl create secret generic keycloak-postgres \
  --from-literal=postgres-password='YourPostgresAdminPassword' \   # <---- change me
  --from-literal=password='YourKeycloakDbPassword' \               # <---- change me
  -n platform-auth
```

### 4. Create the IRSA role for Keycloak

This gives Keycloak a short-lived AWS token to read from Secrets Manager. No credentials in the pod.

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
  --role-name ${CLUSTER_NAME}-keycloak-irsa \
  --assume-role-policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Principal\":{\"Federated\":\"arn:aws-us-gov:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}\"},
      \"Action\":\"sts:AssumeRoleWithWebIdentity\",
      \"Condition\":{\"StringEquals\":{
        \"${OIDC_ISSUER}:sub\":\"system:serviceaccount:platform-auth:keycloak\",
        \"${OIDC_ISSUER}:aud\":\"sts.amazonaws.com\"
      }}
    }]
  }"

aws iam attach-role-policy \
  --role-name ${CLUSTER_NAME}-keycloak-irsa \
  --policy-arn arn:aws-us-gov:iam::aws:policy/SecretsManagerReadWrite

echo "arn:aws-us-gov:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-keycloak-irsa"
```

Copy that ARN and paste it into `keycloak-values.yaml` at the `eks.amazonaws.com/role-arn` line.

---

## Step 1 — Apply the Namespace

```bash
kubectl apply -f namespace.yaml
```

---

## Step 2 — Deploy Keycloak

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm upgrade --install keycloak bitnami/keycloak \
  --namespace platform-auth \
  --values keycloak-values.yaml \
  --wait --timeout 10m
```

---

## Step 3 — Verify

```bash
kubectl get pods -n platform-auth
```

Expected: two Keycloak pods and one Postgres pod, all `Running`.

```bash
kubectl get ingress -n platform-auth
```

This shows the ALB DNS name. Create a DNS CNAME record pointing your Keycloak hostname to this ALB DNS name.

---

## Step 4 — Configure AD Federation (after first login)

Log in to the Keycloak admin console at your hostname (`/auth/admin`). You'll use the `keycloak-admin` secret password.

Then:
1. Create a realm called `platform`
2. Add a User Federation → LDAP provider pointing at your AD DNS IPs (from `02-identity` outputs)
3. Create a client called `grafana` — you'll need its secret for the observability stack

The SA runbook in `docs/sa-cheat-sheet.md` covers the day-to-day of this.

---

## Troubleshooting

Paste the error below and drop this whole file into Claude or ChatGPT: *"I'm deploying Keycloak on EKS in AWS GovCloud. Here's my error."*

---

### Paste Error Output Below

```
<paste kubectl or helm output here>
```

---

**Common issues:**

| Error | What it means | Fix |
|-------|---------------|-----|
| Pods stuck in `Pending` | Nodes don't have capacity | Check `kubectl describe pod -n platform-auth` — look for resource or scheduling issues |
| `CrashLoopBackOff` on Keycloak | Secret doesn't exist or wrong key name | Confirm `keycloak-admin` and `keycloak-postgres` secrets exist: `kubectl get secrets -n platform-auth` |
| ALB not provisioning | AWS Load Balancer Controller not installed | See Step 0 above |
| `Unauthorized` on admin console | Wrong password | Grab it from the secret: `kubectl get secret keycloak-admin -n platform-auth -o jsonpath='{.data.admin-password}' \| base64 -d` |
