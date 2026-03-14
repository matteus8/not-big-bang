# 04 — Kubernetes

Bob has his desktop. The SA has AD under control. Jim is standing up the cluster — except Jim doesn't actually run any Terraform this time. The CI pipeline does. Jim's job for this layer is to watch the `apply:kubernetes` job in GitLab, click the approval gate, and then get himself kubectl access once the cluster comes up.

This is a private EKS cluster — the API server has no public endpoint. You reach it from the hub VPC (bastion, SSM tunnel, or VPN). Nodes use IMDSv2 with a hop limit of 1, which means containers physically cannot reach the instance metadata service to steal node credentials. Pods get AWS access via IRSA — short-lived tokens scoped to exactly what they need, nothing more.

**What this builds:**
- EKS cluster (private API endpoint only)
- Managed node group in the EKS spoke private subnets
- OIDC provider for IRSA — pods get scoped, short-lived tokens instead of node credentials
- CoreDNS, kube-proxy, VPC CNI, and EBS CSI add-ons
- KMS encryption for Kubernetes secrets and node EBS volumes
- CloudWatch log group for control plane logs (365-day retention)

---

## Before You Start

### Install kubectl and helm

Jim needs these to verify the cluster and do a few manual things once it's up. Install them now.

**Mac:**
```bash
brew install kubectl helm
```

**Linux / WSL:**
```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

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

## Step 1 — CI Handles This

Unlike layers 01 and 02, Jim doesn't run `terraform apply` from his laptop for this one. The GitLab CI pipeline runs `apply:kubernetes` automatically after `apply:identity` succeeds (see `.gitlab-ci.yml`). There's a manual approval gate — someone has to click **Run** in the GitLab pipeline UI before it applies. That someone is Jim.

Go to your GitLab project → **CI/CD → Pipelines**, find the pipeline that ran after your last merge to `main`, and click the play button on `apply:kubernetes`.

EKS takes 10-15 minutes to provision. Node group takes another 5 minutes on top. Jim gets coffee. So does Sally. Bob calls. Nobody answers.

> **Need to run it locally for debugging?** Here's what the CI job does under the hood — same commands, run from `terraform/04-kubernetes/`:
> ```bash
> terraform init -backend-config="bucket=falcon-park-tfstate"    # <---- change me
> terraform plan  -var="project=falcon-park" -var="environment=dev" -var="tfstate_bucket=falcon-park-tfstate"
> terraform apply -var="project=falcon-park" -var="environment=dev" -var="tfstate_bucket=falcon-park-tfstate"
> ```

---

## Step 2 — Get kubectl Access

The cluster has no public API endpoint. Jim's laptop is not in the hub VPC. Before anyone can run a single `kubectl` command, you need a way in.

The easiest path for a small team is **AWS Systems Manager Session Manager port forwarding** — no bastion to maintain, no VPN to configure, and AWS logs every session automatically.

First, install the SSM plugin if you don't have it:
```bash
# Mac
brew install --cask session-manager-plugin

# Linux / WSL
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o ssm-plugin.deb
sudo dpkg -i ssm-plugin.deb
```

You need an EC2 instance in the hub VPC to tunnel through. A `t3.micro` Amazon Linux instance in a hub private subnet works — it just needs the SSM agent, which comes pre-installed on Amazon Linux. List what's available:
```bash
aws ssm describe-instance-information --region us-gov-west-1 \
  --query 'InstanceInformationList[*].[InstanceId,IPAddress,ComputerName]' \
  --output table
```

Open the tunnel (leave this running in a dedicated terminal):
```bash
ENDPOINT=$(aws eks describe-cluster \
  --name falcon-park-dev \
  --region us-gov-west-1 \
  --query "cluster.endpoint" --output text | sed 's|https://||')

aws ssm start-session \
  --target <your-hub-instance-id> \                 # <---- change me to an SSM-accessible instance in the hub VPC
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$ENDPOINT\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}" \
  --region us-gov-west-1
```

In a second terminal, get the kubeconfig and point it at your local tunnel:
```bash
aws eks update-kubeconfig \
  --name falcon-park-dev \                          # <---- change me
  --region us-gov-west-1

kubectl config set-cluster falcon-park-dev \
  --server=https://localhost:8443
```

> If the team is going to run `kubectl` regularly, look into AWS Client VPN into the hub VPC. The SSM port-forward above works but it's a two-step every time. VPN is a one-time setup and then it just works.

---

## Step 3 — Verify

```bash
kubectl get nodes
```

You should see your nodes in `Ready` state. If they're `NotReady` or missing, the node group is still provisioning — wait 5 minutes and check again.

```bash
kubectl get pods -n kube-system
```

CoreDNS, kube-proxy, VPC CNI, and EBS CSI pods should all be `Running`. If any are stuck, check the add-on status in the AWS EKS console — add-ons sometimes need a second `terraform apply` if the cluster wasn't fully ready on the first pass.

---

## What Success Looks Like

```
apply:kubernetes   passed   12m
```

And in the AWS EKS console, the cluster status shows `Active` and the node group shows `Active` with your nodes listed.

From your tunnel terminal:
```
$ kubectl get nodes
NAME                                          STATUS   ROLES    AGE   VERSION
ip-10-2-10-x.us-gov-west-1.compute.internal   Ready    <none>   8m    v1.30.x
ip-10-2-12-x.us-gov-west-1.compute.internal   Ready    <none>   8m    v1.30.x
```

The Terraform outputs (visible in the CI job log) will look like:
```
cluster_name        = "falcon-park-dev"
cluster_endpoint    = "https://ABCDEF1234.gr7.us-gov-west-1.eks.amazonaws.com"
cluster_oidc_issuer = "https://oidc.eks.us-gov-west-1.amazonaws.com/id/ABCDEF1234"
oidc_provider_arn   = "arn:aws-us-gov:iam::123456789:oidc-provider/..."
```

---

## Troubleshooting

Paste the error below and drop this whole file into Claude or ChatGPT: *"I'm deploying a private EKS cluster in AWS GovCloud. Here's my error."*

---

### Paste Error Output Below

```
<paste CI job log or kubectl output here>
```

---

**Common issues:**

| Error | What it means | Fix |
|-------|---------------|-----|
| `apply:kubernetes` fails: `unsupported Kubernetes version` | Version not available in GovCloud yet | Update `kubernetes_version` in `variables.tf` to a supported version: `aws eks describe-addon-versions --region us-gov-west-1 \| grep kubernetesVersion` |
| `kubectl get nodes` returns nothing | Node group still provisioning | Wait 5 minutes, try again |
| `error: You must be logged in to the server (Unauthorized)` | IAM identity doesn't match who ran apply | The CI role is the cluster creator and gets implicit admin access. Jim's local profile is a different IAM identity. Either add Jim's IAM ARN as a cluster access entry in the EKS console, or assume the same CI role locally before running kubectl |
| SSM port-forward hangs immediately | No instance in hub VPC with SSM | Spin up a `t3.micro` Amazon Linux instance in a hub private subnet |
| Add-on creation fails in CI | Cluster wasn't fully ready yet | Re-run the `apply:kubernetes` job — it retries cleanly |
