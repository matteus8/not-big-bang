# 02 — Identity

The network exists. Three VPCs sitting there doing nothing. Now you need to figure out who gets to touch things — and make sure your CI/CD pipeline never has a hardcoded credential in it.

Jim took this one. "Two things," he said. "Managed AD for the users, and OIDC for the pipeline. Nobody gets a key to the house until we know who they are, and no key lives in a `.env` file." Sally agreed. Bob in Tampa called again. Jim also ignored it.

**What this builds:**
- AWS Managed Microsoft AD in the hub private subnets — AWS runs the domain controllers, you just point WorkSpaces at it
- DHCP options set on the hub VPC so instances resolve your AD domain
- AD admin password stored in Secrets Manager (not in your tfvars file, not in git)
- GitLab OIDC provider + IAM role — your CI pipeline assumes this role via short-lived token, no access keys anywhere

---

## Estimated Monthly Cost

| Resource | What you get | Est. $/month |
|----------|-------------|-------------|
| Managed Microsoft AD (Standard) | Two domain controllers in two AZs, up to 30K objects — plenty for 50 users | ~$40–50 |
| Secrets Manager (1 secret) | AD admin password | ~$0.40 |
| OIDC provider, IAM role | Free | $0 |
| **Layer total** | | **~$40–50/month** |

Standard Edition handles up to 30,000 directory objects — more than enough for a small shop. If you ever need to upgrade to Enterprise (500K objects, ~$110/month), change `ad_edition = "Enterprise"` in your vars and re-apply. The domain is preserved; only the underlying capacity tier changes.

> Same GovCloud pricing caveat as `01-network` — check current rates before budgeting.

---

## Before You Start

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

## Gather These Values Before You Touch a Terminal

Open a notepad. You need nine values before you run a single command. Everything below tells you exactly how to get each one — add each value to your notepad as you go.

```
ad_domain_name        = ___________________________
ad_short_name         = ___________________________
ad_admin_password     = ___________________________   (keep this secret)
gitlab_url            = ___________________________
gitlab_namespace      = ___________________________
gitlab_repo           = ___________________________
gitlab_tls_thumbprint = ___________________________
project               = ___________________________   (carried over from 01-network)
tfstate_bucket        = ___________________________   (carried over from 01-network)
```

---

### `ad_domain_name` — your AD domain

This is the one value you cannot change without rebuilding from scratch. Every WorkSpace, every domain-joined machine, and every Kerberos ticket will use this name forever. Pick it carefully.

Use a subdomain of your contract's domain — not your company's domain, not the public root:

```
corp.falconpark.gov
│    │           │
│    │           └── .gov because it's a government contract
│    └── falconpark — the contract name, not the company name
└── corp — marks this as internal. keeps AD off the public root.
           vipers.io's other projects get corp.theirproject.gov —
           same pattern, no overlap.
```

Rules:
- No spaces, no underscores
- Don't use `.local` — it conflicts with mDNS
- Don't use the bare public root (`falconpark.gov`) — always add a subdomain prefix (`corp.falconpark.gov`)
- Once applied, it's permanent

Add to your notepad: `ad_domain_name = corp.yourcontract.gov`

---

### `ad_short_name` — NetBIOS name

The old-school Windows domain prefix. Users see this when they log in: `FALCONPARK\jdoe`. Take the contract name, uppercase it, drop any hyphens if you need to stay under 15 characters.

Rules: 15 characters max, no dots, all caps by convention.

Add to your notepad: `ad_short_name = YOURCONTRACT`

---

### `ad_admin_password` — AD admin password

Pick a strong password now and write it somewhere safe (a password manager, not a sticky note). You will not type it on the command line — you'll load it into your shell environment before applying so it never touches shell history.

AWS enforces complexity. The password must be 8–64 characters and meet three of these four criteria: uppercase letter, lowercase letter, number, special character. A simple all-lowercase password will be rejected.

Write it down somewhere secure. You'll use it in Step 3.

---

### `gitlab_url` — your GitLab base URL

Just the root URL of your GitLab instance, no trailing slash.

- Self-hosted example: `https://gitlab.vipers.io`
- GitLab.com: `https://gitlab.com`

Add to your notepad: `gitlab_url = https://gitlab.vipers.io`

---

### `gitlab_namespace` — the GitLab group that owns this repo

This is the **group name**, not your username and not the repo name. In GitLab, navigate to your project. The URL looks like `https://gitlab.vipers.io/falcon-park/not-big-bang`. The part between the host and the repo name is the namespace — `falcon-park` in that example.

Add to your notepad: `gitlab_namespace = falcon-park`

---

### `gitlab_repo` — the repo name

The project name inside that group. For this repo it's `not-big-bang`.

Add to your notepad: `gitlab_repo = not-big-bang`

---

### `gitlab_tls_thumbprint` — GitLab's TLS certificate fingerprint

Run this command, replacing the hostname with your GitLab instance:

```bash
openssl s_client -connect gitlab.vipers.io:443 2>/dev/null \
  | openssl x509 -fingerprint -noout -sha1 \
  | sed 's/://g' | tr '[:upper:]' '[:lower:]' | cut -d= -f2
```

Copy the output — it'll be a long hex string. That's your thumbprint.

Add to your notepad: `gitlab_tls_thumbprint = abc123...`

---

### `project` and `tfstate_bucket`

These came from `01-network`. Use the same values you used there.

- `project` — your contract slug, e.g. `falcon-park`
- `tfstate_bucket` — your S3 state bucket, e.g. `falcon-park-tfstate`

---

## Still Running Locally

Jim and Sally run this layer from their laptops. The SA will run `03-workspaces` from their own terminal (same admin credentials) — that's the last local apply before CI takes over. Once both are done and you've verified the pipeline runs `04-kubernetes` cleanly, the admin access key gets deleted.

---

## Step 1 — Init

All terraform commands below run from the `terraform/02-identity/` directory.

```bash
cd terraform/02-identity
terraform init \
  -backend-config="bucket=falcon-park-tfstate"    # <---- change me to your bucket name
```

---

## Step 2 — Plan

Paste your values from the notepad into this command:

```bash
terraform plan \
  -var="project=falcon-park" \                              # <---- change me
  -var="environment=dev" \
  -var="tfstate_bucket=falcon-park-tfstate" \               # <---- change me
  -var="ad_domain_name=corp.falconpark.gov" \               # <---- change me
  -var="ad_short_name=FALCONPARK" \                         # <---- change me
  -var="gitlab_url=https://gitlab.vipers.io" \              # <---- change me
  -var="gitlab_namespace=falcon-park" \                     # <---- change me
  -var="gitlab_repo=not-big-bang" \                         # <---- change me
  -var="gitlab_tls_thumbprint=yourthumbprinthere"           # <---- change me
```

The plan should show Managed AD, a DHCP option set, an OIDC provider, an IAM role, and a Secrets Manager secret.

---

## Step 3 — Apply

**First**, load your AD admin password into the shell environment. This keeps it out of shell history and off the command line entirely:

```bash
read -s TF_VAR_ad_admin_password && export TF_VAR_ad_admin_password
# Type your password and press Enter — nothing echoes to the screen
```

**Then** apply with the same vars as the plan. Terraform picks up `TF_VAR_ad_admin_password` automatically from the environment:

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
```

Type `yes`. Managed AD takes **20-45 minutes** to provision. This is not a bug. AWS is spinning up domain controllers in two AZs. Go get coffee. Bob can wait.

---

## What Success Looks Like

```
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.

Outputs:
  managed_ad_id                = "d-0abc12345"
  managed_ad_dns_ips           = toset(["10.0.10.15", "10.0.11.22"])
  managed_ad_security_group_id = "sg-0abc12345"
  gitlab_ci_role_arn           = "arn:aws-us-gov:iam::123456789:role/falcon-park-dev-gitlab-ci"
  gitlab_oidc_provider_arn     = "arn:aws-us-gov:iam::123456789:oidc-provider/gitlab.vipers.io"
  ad_admin_secret_arn          = "arn:aws-us-gov:secretsmanager:us-gov-west-1:123456789:secret:falcon-park-dev/managed-ad/admin-password"
```

---

## After Apply — Wire Up GitLab CI/CD Variables

Now that Terraform has created the IAM role, you need to tell GitLab about it. Go to your GitLab project → **Settings → CI/CD → Variables** and add all of the following.

The most important value is `AWS_ROLE_ARN` — it comes from the `gitlab_ci_role_arn` line in your Terraform output. Copy it now and add it to your notepad. It looks like:

```
gitlab_ci_role_arn = "arn:aws-us-gov:iam::123456789:role/falcon-park-dev-gitlab-ci"
                                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                this whole ARN goes into AWS_ROLE_ARN
```

**Standard variables (Unprotected + Visible):**
| Variable | Falcon-Park example | Notes |
|----------|-------------------|-------|
| `AWS_ROLE_ARN` | `arn:aws-us-gov:iam::123456789:role/falcon-park-dev-gitlab-ci` | the `gitlab_ci_role_arn` value from your Terraform output |
| `TF_STATE_BUCKET` | `falcon-park-tfstate` | your bucket name from 01-network |
| `PROJECT_NAME` | `falcon-park` | your project slug |
| `ENVIRONMENT` | `dev` | |
| `AD_DOMAIN_NAME` | `corp.falconpark.gov` | your AD FQDN |
| `AD_SHORT_NAME` | `FALCONPARK` | your NetBIOS name |
| `GITLAB_URL` | `https://gitlab.vipers.io` | your GitLab instance base URL |
| `GITLAB_NAMESPACE` | `falcon-park` | your GitLab group name |
| `GITLAB_TLS_THUMBPRINT` | `abc123...` | from the openssl command above |
| `CLUSTER_NAME` | `falcon-park-dev` | project slug + `-` + environment |

**Protected + Masked variable** (set the "Masked" toggle — this one must never appear in logs):

| Variable | Value |
|----------|-------|
| `AD_ADMIN_PASSWORD` | your AD admin password |

When done it should look like this:

![GitLab CI/CD variables configured](gitlab-vars.png)

---

## After Apply — Create Your First AD User

Bob in Tampa is the reason this whole project exists. Before you can provision him a WorkSpace in `03-workspaces`, he needs to exist in Active Directory.

AWS now has a native user management interface built directly into the Directory Service console — no EC2 jump box, no RDP session, no extra cost. The Actions menu does offer "Launch directory administration EC2 instance" for shops that need full AD tooling (GPOs, schema extensions, complex OUs), but for a small team deploying WorkSpaces you don't need any of that.

![AWS Directory Service console showing the Users tab and Enable button](active-directory.png)

**To enable the native console user management:**

1. Go to **AWS Directory Service → Directories → your directory**
2. On the directory detail page, find **User and group management** on the right side — it will say "Disabled"
3. Click **Enable** next to it
4. The **Users** tab will now let you create and manage users directly in the browser

**To create Bob:**

1. Click the **Users** tab
2. Click **Add user**
3. Fill in:
```
First name:  Bob
Last name:   Johnson
User logon:  bjohnson           ← this is what goes in workspace_users later
Password:    <set initial password, mark as "must change at next logon">
```

That's it. One user. When you get to `03-workspaces`, you'll pass `bjohnson` as the first entry in `workspace_users` and Terraform will provision one WorkSpace for him. If the rest of the team needs desktops later, add them to AD the same way and add their usernames to the list — Terraform only creates the new ones, existing WorkSpaces are untouched.

> **How many WorkSpaces will this build?** Exactly as many usernames as you put in `workspace_users`. Start with one (`bjohnson`). Add more when the team grows. There's no minimum and no upper limit enforced by Terraform — AWS limits depend on your service quota, but for a small team you won't hit it.

---

## After Apply — Test OIDC

Push a commit to a branch. The GitLab CI pipeline should trigger and use the OIDC role to authenticate with AWS. If it says `Error: Could not assume role` — double-check the `gitlab_namespace` and `gitlab_repo` vars match your actual GitLab group and project name exactly. **Case-sensitive.**

---

## What's Next

Go to `03-workspaces/`. The SA will apply that layer from their terminal using the same admin credentials you've been using here. Once Bob has a desktop and the pipeline is wired up, you're done with local applies.

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
| `ValidationException: Value at 'password' failed to satisfy constraint` | AD password doesn't meet complexity requirements | Unset `TF_VAR_ad_admin_password`, run `read -s TF_VAR_ad_admin_password && export TF_VAR_ad_admin_password` again with a password that has uppercase, lowercase, a number, and a special character |
