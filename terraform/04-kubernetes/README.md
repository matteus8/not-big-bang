# 04 — Kubernetes

The apps need a home. Bob has his desktop. The SA has their AD. Now Jim is going to stand up the cluster, and Sally is going to deploy things into it in the next three directories.

This is a private EKS cluster — the API server has no public endpoint. You reach it from the hub VPC (bastion, VPN, or Systems Manager Session Manager). Nodes use IMDSv2 with a hop limit of 1, which means your containers physically cannot reach the instance metadata service to steal node credentials. Pods get AWS access via IRSA — short-lived tokens scoped to exactly what they need, nothing more.

**What this builds:**
- EKS cluster (private API endpoint only)
- Managed node group in the EKS spoke private subnets
- OIDC provider for IRSA — this is the foundation for `k8s-manifests/`
- CoreDNS, kube-proxy, VPC CNI, and EBS CSI add-ons
- KMS encryption for Kubernetes secrets and node EBS volumes
- CloudWatch log group for control plane logs (365-day retention)

---

## Before You Start

### Install kubectl and helm if you haven't already

These are needed for every step in `k8s-manifests/`. Get them now before you need them mid-deploy.

**kubectl — Mac:**
```bash
brew install kubectl
```
**kubectl — Windows/Linux:** [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools)

**helm — Mac:**
```bash
brew install helm
```
**helm — Windows/Linux:** [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install)

Confirm both work:
```bash
kubectl version --client
helm version
```

### Confirm the earlier layers are clean

```bash
# Should return your EKS spoke VPC — look for the 10.2.0.0/16 block
aws ec2 describe-vpcs \
  --region us-gov-west-1 \
  --filters "Name=tag:Layer,Values=01-network" \
  --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# Should return private subnets in the 10.2.x.x range
aws ec2 describe-subnets \
  --region us-gov-west-1 \
  --filters "Name=tag:Layer,Values=01-network" "Name=cidrBlock,Values=10.2.*" \
  --query 'Subnets[*].[SubnetId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

---

## Step 1 — Init

```bash
terraform init \
  -backend-config="bucket=falcon-park-tfstate"    # <---- change me to your bucket name
```

---

## Step 2 — Plan

```bash
terraform plan \
  -var="project=falcon-park" \                    # <---- change me
  -var="environment=dev" \
  -var="tfstate_bucket=falcon-park-tfstate"       # <---- change me
```

The plan will show the EKS cluster, node group, launch template, IAM roles, OIDC provider, add-ons, and KMS key. It's a lot of resources — that's expected.

---

## Step 3 — Apply

```bash
terraform apply \
  -var="project=falcon-park" \                    # <---- change me
  -var="environment=dev" \
  -var="tfstate_bucket=falcon-park-tfstate"       # <---- change me
```

EKS takes 10-15 minutes. Node group takes another 5 minutes on top. Go bug-free time is approximately 20 minutes.

---

## Step 4 — Get Access to the Cluster

The API server has no public endpoint. Your laptop is not in the hub VPC. Before you can run a single `kubectl` command, you need a way in.

The simplest option for a small team is **AWS Systems Manager Session Manager port forwarding** — no bastion to maintain, no VPN to configure, and the audit trail is automatic.

First, make sure you have the SSM plugin installed:
```bash
# Mac
brew install --cask session-manager-plugin

# Linux / WSL
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
sudo dpkg -i session-manager-plugin.deb
```

Find an instance in the hub VPC to tunnel through (or provision a small `t3.micro` Amazon Linux instance in a hub private subnet — it just needs the SSM agent, which comes pre-installed on Amazon Linux):
```bash
# List instances in your account that have SSM available
aws ssm describe-instance-information --region us-gov-west-1 \
  --query 'InstanceInformationList[*].[InstanceId,IPAddress,ComputerName]' \
  --output table
```

Port-forward through SSM to the EKS endpoint:
```bash
# Get your cluster endpoint (strip the https://)
ENDPOINT=$(aws eks describe-cluster \
  --name falcon-park-dev \                          # <---- change me
  --region us-gov-west-1 \
  --query "cluster.endpoint" --output text | sed 's|https://||')

aws ssm start-session \
  --target <your-hub-instance-id> \                 # <---- change me to an instance in the hub VPC
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$ENDPOINT\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}" \
  --region us-gov-west-1
```

Leave that running in one terminal. Then get your kubeconfig in another:
```bash
aws eks update-kubeconfig \
  --name falcon-park-dev \                          # <---- change me
  --region us-gov-west-1

# Point kubectl at the local tunnel instead of the private endpoint
kubectl config set-cluster falcon-park-dev \
  --server=https://localhost:8443
```

Verify it works:
```bash
kubectl get nodes
# Should show your nodes in Ready state
```

> If this feels like a lot, it is. The alternative is setting up AWS Client VPN into the hub VPC, which is a more permanent solution for a team that will be running `kubectl` regularly. The SSM port-forward approach above is fine for occasional use.

---

## Step 5 — Install the AWS Load Balancer Controller

Every `Ingress` in this stack uses the ALB ingress class. Without this controller, ALBs never get created — Keycloak, Grafana, and anything else with an ingress will sit there doing nothing. Install it now, before you need it.

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=falcon-park-dev \    # <---- change me to match your cluster name
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 5m
```

Verify it's running:
```bash
kubectl get deployment aws-load-balancer-controller -n kube-system
```

> The controller needs IAM permissions to create ALBs on your behalf. If the pods are crashlooping with `AccessDenied`, the service account needs an IRSA role with `elasticloadbalancing:*` and `ec2:Describe*`. The [EKS LBC docs](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html) have the exact policy — it's a one-time setup.

---

## Step 6 — Create the CloudWatch Log Group for Fluent Bit

Fluent Bit (deployed later in `03-observability`) will ship logs here. Create the group now so the log group exists with the right retention before Fluent Bit starts writing:

```bash
aws logs create-log-group \
  --log-group-name /eks/falcon-park-dev/containers \    # <---- change me to match project-environment
  --region us-gov-west-1

aws logs put-retention-policy \
  --log-group-name /eks/falcon-park-dev/containers \    # <---- change me
  --retention-in-days 365 \
  --region us-gov-west-1
```

---

## What Success Looks Like

```
Apply complete! Resources: 22 added, 0 changed, 0 destroyed.

Outputs:
  cluster_name = "falcon-park-dev"
  cluster_endpoint = "https://ABCDEF1234.gr7.us-gov-west-1.eks.amazonaws.com"
  cluster_oidc_issuer = "https://oidc.eks.us-gov-west-1.amazonaws.com/id/ABCDEF1234"
  oidc_provider_arn = "arn:aws-us-gov:iam::123456789:oidc-provider/..."
```

Copy the `cluster_oidc_issuer` value somewhere handy. You'll need it in the k8s-manifests steps when creating IRSA roles.

Head to `k8s-manifests/01-platform-auth/` next.

---

## Troubleshooting

Paste the error below and drop this whole file into Claude or ChatGPT: *"I'm deploying a private EKS cluster in AWS GovCloud. Here's my error."*

---

### Paste Error Output Below

```
<paste terraform output here>
```

---

**Common issues:**

| Error | What it means | Fix |
|-------|---------------|-----|
| `Error: Error creating EKS Cluster: InvalidParameterException: unsupported Kubernetes version` | Version not available in GovCloud yet | Change `kubernetes_version` to one that's available: `aws eks describe-addon-versions --region us-gov-west-1 \| grep kubernetesVersion` |
| `kubectl get nodes` returns nothing | Node group still provisioning | Wait 5 minutes, try again |
| `error: You must be logged in to the server (Unauthorized)` | IAM identity doesn't have cluster access | Make sure you're using the same AWS profile that ran `terraform apply` |
| Add-on creation fails | Cluster not fully ready yet | Run `terraform apply` again — it retries |
