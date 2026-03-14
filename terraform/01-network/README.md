# 01 — The Network

You won the contract. Congratulations. Go celebrate. Now come back, because you need a network before any of this works.

Sally drew it on a napkin at happy hour: a hub in the middle, two spokes hanging off it. "Hub is for shared stuff," she said. "AD, Keycloak, monitoring. The spokes are for actual workloads. WorkSpaces goes in one, Kubernetes in the other. They don't talk to each other — only back to the hub." Jim nodded. Bob in Tampa called to ask when his desktop would be ready. Sally ignored it.

That napkin is now this Terraform.

**What this builds:**
- Hub VPC (`10.0.0.0/16`) — shared services live here
- WorkSpaces spoke (`10.1.0.0/16`) — desktops stream from here
- EKS spoke (`10.2.0.0/16`) — app workloads live here
- VPC peering: hub ↔ each spoke (spokes can't see each other — if one gets weird, it stays weird in isolation)
- VPC Flow Logs on all three — 365-day retention, NIST AU-2 covered

---

## Before You Start — Do You Have the AWS CLI?

Someone handed Jim an email with a root account username and password. Jim stared at it, immediately felt some dread, and then did the right thing: logged in once to set up MFA, and never touched root again. Here's how to get from that email to actually running Terraform.

### 1. Secure the root account first

Log in at [https://console.amazonaws-us-gov.com](https://console.amazonaws-us-gov.com), go to the top-right account menu → **Security credentials**, and enable MFA on the root account. Use an authenticator app. Log out. That's it — root is now a break-glass credential, not a daily driver.

### 2. Windows? Use WSL First

Every command in this repo is bash. If your work laptop runs Windows, install **Windows Subsystem for Linux** before anything else — it gives you a real Linux terminal and makes everything below just work.

Open PowerShell as Administrator and run:
```powershell
wsl --install
```
Reboot when it asks. After reboot, open the **Ubuntu** app from the Start menu and finish the setup. From here on, run all commands inside that Ubuntu terminal — not PowerShell, not CMD.

> If your environment is locked down and you can't install WSL, Terraform and the AWS CLI both have native Windows binaries. But you'll be fighting the current the whole way. WSL is worth the IT ticket.

### 3. Install the AWS CLI

**Mac:**
```bash
brew install awscli
```

**Linux / WSL:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
```

**Windows (native, if WSL really isn't an option — PowerShell as Administrator):**
```powershell
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
```

Confirm it works: `aws --version`

### 4. Create a working IAM user (temporary)

In the AWS console, go to **IAM → Users → Create user**. Attach `AdministratorAccess`. Under that user's Security Credentials tab, create an **Access Key**.

> This key gets deleted once `02-identity` is applied and OIDC is wired up. Write that on a sticky note. Don't forget.

### 5. Configure the CLI on your laptop

```bash
aws configure --profile govcloud
```

```
AWS Access Key ID:     <paste your key>
AWS Secret Access Key: <paste your secret>
Default region name:   us-gov-west-1
Default output format: json
```

### 6. Verify it works

```bash
aws sts get-caller-identity --profile govcloud
```

You should get your account ID and user ARN back. If you see that, your laptop can talk to GovCloud. Set it as your default profile so you don't have to type `--profile` on every command:

```bash
export AWS_PROFILE=govcloud
```

> you can view your creds and cli account info in your home directory - the ".aws" directory

### 7. Install Terraform

**Mac:**
```bash
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
```

**Windows/Linux:** Download the binary from [developer.hashicorp.com/terraform/downloads](https://developer.hashicorp.com/terraform/downloads), unzip it, and put it somewhere on your PATH.

Confirm: `terraform -version` — needs to be `>= 1.6`.

---

## Pick Your Project Name

Before you create the state bucket or run a single Terraform command, you need two names. They show up in every layer from here to the end, so pick them now and write them down.

**Who's who:**

- **Vipers.io** — your company. The subcontractor. The people who won the work.
- **Falcon-Park** — the contract. The project. The mission. The thing Bob in Tampa is the end-user of.

These are two different namespaces. Your project name belongs to the *contract*, not your company. Everything in this repo is named after the contract.

The two values you need:

| Variable | What it is | Falcon-Park example | Your value |
|----------|-----------|-------------------|------------|
| `project` | Short slug used in every resource name and state path | `falcon-park` | `your-contract-name` |
| `tfstate_bucket` | S3 bucket for Terraform state — must be globally unique | `falcon-park-tfstate` | `your-contract-name-tfstate` |

Pick a slug that's lowercase, hyphenated, no spaces. You'll type it in every `terraform plan` and `terraform apply` for the rest of this build. Keep it short.

> The examples below use `falcon-park` and `falcon-park-tfstate`. Swap them for your contract name everywhere you see `# <---- change me`.

---

## Create the State Bucket

You need one thing that doesn't exist yet: an S3 bucket for Terraform state. Run this once, ever, before anything else.

```bash
aws s3api create-bucket \
  --bucket falcon-park-tfstate \         # <---- change me to your bucket name
  --region us-gov-west-1 \
  --create-bucket-configuration LocationConstraint=us-gov-west-1

aws s3api put-bucket-versioning \
  --bucket falcon-park-tfstate \         # <---- same bucket name
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket falcon-park-tfstate \         # <---- same bucket name
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'

aws s3api put-public-access-block \
  --bucket falcon-park-tfstate \         # <---- same bucket name
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

Done. You never run that again.

---

## A Note on CI

The GitLab CI pipeline uses an IAM role that doesn't exist yet — it gets created in `02-identity`. That means **layers 01 and 02 are applied manually from your laptop**. After `02-identity` is done and you've added the role ARN to your GitLab CI/CD variables, the pipeline takes over for layers 03 and 04 and everything after.

So for right now: ignore CI, run terraform from your terminal.

---

## Step 1 — Init

```bash
terraform init \
  -backend-config="bucket=falcon-park-tfstate"    # <---- change me to your bucket name
```

Terraform will pull the AWS provider and connect to your state bucket. Expected output ends with `Terraform has been successfully initialized!`

---

## Step 2 — Plan

```bash
terraform plan \
  -var="project=falcon-park" \                     # <---- change me
  -var="environment=dev"
```

Read it. The plan should show three VPCs, subnets, NAT gateways, peering connections, and flow logs. Nothing destructive on first run.

---

## Step 3 — Apply

```bash
terraform apply \
  -var="project=falcon-park" \                     # <---- change me
  -var="environment=dev"
```

Type `yes` when prompted. This takes about 3-5 minutes. NAT Gateways are slow to provision — that's normal, not broken.

---

## What Success Looks Like

```
Apply complete! Resources: 35 added, 0 changed, 0 destroyed.

Outputs:
  hub_vpc_id = "vpc-0abc..."
  spoke_workspaces_vpc_id = "vpc-0def..."
  spoke_eks_vpc_id = "vpc-0ghi..."
```

Three VPC IDs in the output. That's your network. Go to `02-identity/` next.

---

## Troubleshooting

Something went sideways? Copy the full terminal output below the line, then paste this entire file into Claude or ChatGPT and say *"help me fix this Terraform error."* The context above tells it exactly what you're building.

---

### Paste Error Output Below

```
<paste terraform output here>
```

---

**Common issues:**

| Error | What it means | Fix |
|-------|---------------|-----|
| `Error: error creating VPC` | IAM permissions missing | Make sure your AWS profile has EC2 permissions |
| `Error: S3 bucket not found` | Wrong bucket name in `-backend-config` | Re-run `terraform init` with the correct bucket |
| `Error: InvalidVpcID.NotFound` on peering | VPC creation failed upstream | Check `terraform state list` and re-apply |
| NAT Gateway stuck creating | Totally normal, it's slow | Wait 5 more minutes |
