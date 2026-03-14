# 02 — Identity

The network exists. Three VPCs sitting there doing nothing. Now you need to figure out who gets to touch things — and make sure your CI/CD pipeline never has a hardcoded credential in it.

Jim took this one. "Two things," he said. "Managed AD for the users, and OIDC for the pipeline. Nobody gets a key to the house until we know who they are, and no key lives in a `.env` file." Sally agreed. Bob in Tampa called again. Jim also ignored it.

Their project is called **Falcon-Park**. You'll see that name in every example below. Swap it for yours.

**What this builds:**
- AWS Managed Microsoft AD in the hub private subnets — AWS runs the domain controllers, you just point WorkSpaces at it
- DHCP options set on the hub VPC so instances resolve your AD domain
- AD admin password stored in Secrets Manager (not in your tfvars file, not in git)
- GitLab OIDC provider + IAM role — your CI pipeline assumes this role via short-lived token, no access keys anywhere

---

## Before You Start

### A quick word on who's who

Before you pick names, get straight on the two entities involved:

- **Vipers.io** — that's your company. The subcontractor. The people who won the work and are now building this thing.
- **Falcon-Park** — that's the contract. The project. The mission. The thing Bob in Tampa is the end-user of.

These are two different namespaces and they should stay that way. Your AD domain belongs to the *project*, not your company. If Vipers.io wins another contract next year, it gets its own AD domain. They don't share.

### Do you have a Git host? Read this first.

This repo is wired for **GitLab CI** with OIDC. Before you go any further, answer one question:

> *Does Vipers.io already have a GitLab instance?*

Ask someone. Seriously, just ask. There's usually a Slack message or a wiki page. If Vipers.io has been doing GovCon work for more than six months, they almost certainly have a GitLab somewhere. Use that. Point this repo at it. Done.

**If Vipers.io genuinely has no GitLab**, your options are:

| Option | Reality check |
|--------|--------------|
| **Vipers.io self-hosted GitLab in GovCloud** | The right long-term answer. Someone has to bootstrap it manually — provision the instance, install GitLab, wire up DNS — before any pipeline exists. One-time lift. After that it runs itself. |
| **GitLab Dedicated for Government** | GitLab's FedRAMP-authorized managed offering. You call GitLab, you pay GitLab a lot of money, they run it for you in a compliant environment. Good option if you don't want to operate it yourself. |

> ⚠️ **Bootstrapping a GitLab from scratch is out of scope for this repo.** If you're in that situation, get GitLab running first and come back here. We're not going to pretend that's a two-line fix.

Jim asked around at Vipers.io. Turned out there was a GitLab instance. Had been there for two years. Nobody had told the new people about it. Sally added "tell new people about the GitLab" to the onboarding doc.

---

### Picking your AD domain name

This is the one decision you cannot undo without a very bad afternoon. The `ad_domain_name` is the full DNS name of your Active Directory domain. Every WorkSpace, every domain-joined machine, and every Kerberos ticket will use this name forever.

Sally and Jim chose `corp.falconpark.gov`. Here's the anatomy of that choice:

```
corp.falconpark.gov
│    │           │
│    │           └── .gov because it's a government contract
│    └── falconpark — the contract name, not the company name
└── corp — "corporate internal" subdomain. this is the magic part:
           it keeps AD off the public root domain AND signals to
           anyone reading it that this is an internal directory,
           not a public-facing service. vipers.io's other projects
           get corp.theirproject.gov — same pattern, no overlap.
```

**Rules:**
- Must be a valid DNS name — no spaces, no underscores
- Don't use `.local` — it conflicts with mDNS and causes weird DNS issues
- Don't use your public domain root (`falconpark.gov`) — use a subdomain (`corp.falconpark.gov`)
- Once set, it's set. Renaming an AD domain is a full rebuild.

The `ad_short_name` is the old-school NetBIOS name. Users see it as the domain prefix when they log in (`FALCONPARK\jdoe`). 15 characters max, no dots, all caps by convention.

| Variable | Falcon-Park example | Your value |
|----------|-------------------|------------|
| `ad_domain_name` | `corp.falconpark.gov` | `corp.yourproject.gov` |
| `ad_short_name` | `FALCONPARK` | `YOURPROJECT` |
| `project` | `falcon-park` | `your-project` |
| `tfstate_bucket` | `falcon-park-tfstate` | `your-project-tfstate` |

### GitLab CI/CD variables to set

After this apply, Terraform outputs a role ARN. Go to your GitLab project → Settings → CI/CD → Variables and add:

| Variable | Falcon-Park example | Notes |
|----------|-------------------|-------|
| `AWS_ROLE_ARN` | `arn:aws-us-gov:iam::123456789:role/falcon-park-dev-gitlab-ci` | from the `gitlab_ci_role_arn` output |
| `TF_STATE_BUCKET` | `falcon-park-tfstate` | your bucket name from 01-network |
| `PROJECT_NAME` | `falcon-park` | your project slug |
| `ENVIRONMENT` | `dev` | |
| `AD_DOMAIN_NAME` | `corp.falconpark.gov` | your AD FQDN |
| `AD_SHORT_NAME` | `FALCONPARK` | your NetBIOS name |

And one **Protected + Masked variable** (not plain text — this one stays hidden):

| Variable | Value |
|----------|-------|
| `AD_ADMIN_PASSWORD` | your AD admin password |

---

## Still Running Locally

This is the last layer you run from your laptop. Once the apply finishes and you've added the role ARN to your GitLab CI/CD variables, the pipeline takes over. After this: no more `terraform apply` from your terminal unless something is broken.

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
  -var="project=falcon-park" \                              # <---- change me
  -var="environment=dev" \
  -var="tfstate_bucket=falcon-park-tfstate" \               # <---- change me
  -var="ad_domain_name=corp.falconpark.gov" \               # <---- change me
  -var="ad_short_name=FALCONPARK" \                         # <---- change me
  -var="gitlab_url=https://gitlab.vipers.io" \              # <---- change me to your GitLab instance URL
  -var="gitlab_namespace=falcon-park" \                     # <---- change me to your GitLab group/namespace
  -var="gitlab_repo=not-big-bang" \                         # <---- change me to your repo name
  -var="gitlab_tls_thumbprint=yourthumbprinthere"           # <---- change me, see thumbprint note below
```

The plan should show Managed AD, a DHCP option set, an OIDC provider, an IAM role, and a Secrets Manager secret.

**Getting your GitLab TLS thumbprint** — run this from your terminal (swap in your GitLab hostname):
```bash
openssl s_client -connect gitlab.vipers.io:443 2>/dev/null \
  | openssl x509 -fingerprint -noout -sha1 \
  | sed 's/://g' | tr '[:upper:]' '[:lower:]' | cut -d= -f2
```

---

## Step 3 — Apply

Passing a password on the command line saves it to shell history. Use `read` to keep it out:

```bash
read -s TF_VAR_ad_admin_password && export TF_VAR_ad_admin_password
# Type your password and press Enter — nothing echoes to the screen
```

Then apply without the password in the command:

```bash
terraform apply \
  -var="project=falcon-park" \                              # <---- change me
  -var="environment=dev" \
  -var="tfstate_bucket=falcon-park-tfstate" \               # <---- change me
  -var="ad_domain_name=corp.falconpark.gov" \               # <---- change me
  -var="ad_short_name=FALCONPARK" \                         # <---- change me
  -var="gitlab_url=https://gitlab.vipers.io" \              # <---- change me
  -var="gitlab_namespace=falcon-park" \                     # <---- change me
  -var="gitlab_repo=not-big-bang" \                         # <---- change me
  -var="gitlab_tls_thumbprint=yourthumbprinthere"           # <---- change me
# TF_VAR_ad_admin_password is picked up automatically from the environment
```

Type `yes`. Managed AD takes **20-45 minutes** to provision. This is not a bug. AWS is spinning up domain controllers in two AZs. Go get coffee. Bob can wait.

---

## What Success Looks Like

```
Apply complete! Resources: 9 added, 0 changed, 0 destroyed.

Outputs:
  managed_ad_id          = "d-0abc12345"
  managed_ad_dns_ips     = toset(["10.0.10.15", "10.0.11.22"])
  gitlab_ci_role_arn      = "arn:aws-us-gov:iam::123456789:role/falcon-park-dev-gitlab-ci"
  ad_admin_secret_arn    = "arn:aws-us-gov:secretsmanager:us-gov-west-1:123456789:secret:falcon-park-dev/managed-ad/admin-password"
```

Copy that `gitlab_ci_role_arn` and add it to your GitLab project CI/CD variables as `AWS_ROLE_ARN` now, before you forget.

---

## After Apply — Test OIDC

Push a commit to a branch. The GitLab CI pipeline should trigger and use the OIDC role to authenticate with AWS. If it says `Error: Could not assume role` — double-check the `gitlab_namespace` and `gitlab_repo` vars match your actual GitLab group and project name exactly. Case-sensitive.

---

## Troubleshooting

Something went sideways? Paste the terminal output below, then drop this whole file into Claude or ChatGPT: *"I'm building GovCloud infrastructure with Managed AD and GitLab OIDC. Here's my error."*

---

### Paste Error Output Below

```
<paste terraform output here>
```

---

**Common issues:**

| Error | What it means | Fix |
|-------|---------------|-----|
| AD creation times out | Totally normal | It's still provisioning in the background. Run `terraform apply` again — it'll pick up where it left off. |
| `Error: AccessDeniedException` on Secrets Manager | Missing IAM permissions | Add `secretsmanager:*` to your local IAM profile |
| OIDC `Error: Could not assume role` in CI | namespace/repo name mismatch | Re-apply with the exact GitLab namespace and repo name. Case-sensitive. |
| `Error: InvalidSubnet` on AD | Wrong subnet IDs | Make sure `01-network` applied cleanly first |
