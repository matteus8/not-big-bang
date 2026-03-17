# 03 — WorkSpaces

Bob in Tampa is about to stop calling Sally's cell phone.

The SA drew the short straw on this one — which is fine, because once it's running, the day-to-day is manageable. For right now, you just want one WorkSpace: Bob's. You'll add more people later. The only variable that controls how many WorkSpaces exist is `workspace_users` — it's a list of AD usernames. One username, one desktop. Ten usernames, ten desktops. Add a name and re-apply to provision; remove a name (after offboarding in AD) and re-apply to deprovision. That's the whole lifecycle.

**Credentials:** Use the same admin AWS profile you set up in `01-network` (`AWS_PROFILE=govcloud`). This is still a local apply — no CI involvement yet. After this layer is done and `04-kubernetes` runs cleanly through the pipeline, you'll delete the admin access key. Not yet.

**A note on running this locally:** 02-identity said the pipeline takes over from here — and it does for layers 04 and beyond. But 03-workspaces is different. Adding or removing a WorkSpace user is a day-to-day SA task, not a code deployment. Managing a dynamic user list through CI variables every time someone joins the project is more friction than it's worth. The SA runs this one from their terminal. The `apply:workspaces` CI job exists as a fallback, but in practice: new person starts, SA creates them in AD, SA updates the list and runs `terraform apply`, done in 5 minutes.

**What this builds:**
- WorkSpaces directory registered against your Managed AD
- Security group that lets desktops reach AD and the internet via NAT, but nothing else
- KMS-encrypted root and user volumes (NIST SC-28, checked)
- One WorkSpace per username in your list — add more by updating the list and re-applying
- Users are **not** local admins. This is not negotiable.

> **Why are WorkSpaces in the hub VPC?** AWS requires the WorkSpaces registration subnets to be in the same VPC as the directory. Since Managed AD lives in the hub VPC, desktops do too. Traffic isolation between desktops and servers is enforced by the security group, not separate VPCs.

---

## Estimated Monthly Cost

Cost here scales linearly with the number of users. The big variable is **AutoStop vs AlwaysOn** — AutoStop desktops turn off after a set idle period and bill hourly for usage on top of a base fee; AlwaysOn desktops run 24/7.

| Mode | Base fee/workspace | Usage charge | Best for |
|------|--------------------|-------------|---------|
| AutoStop | ~$28/month | + $0.30/hr while running | Users who work a normal workday (~8 hrs) |
| AlwaysOn | ~$81/month | None | Users who need 24/7 access or complain about cold-start time |

Rough totals by team size (AutoStop, Performance bundle, Windows Server 2022):

| Users | Est. $/month |
|-------|-------------|
| 1 (Bob) | ~$30–85 |
| 5 | ~$150–425 |
| 10 | ~$300–850 |
| 50 | ~$1,500–4,250 |

The low end assumes AutoStop with ~8 hrs/day weekday use. The high end is AlwaysOn.

KMS key for volume encryption adds ~$1/month — negligible.

> AutoStop is the right default for a small GovCon team. If Bob complains about the 30-second resume time, consider AlwaysOn for his WorkSpace specifically and leave everyone else on AutoStop.

### Why not WorkSpaces Pools?

The AWS console shows a **Pools** tab alongside Personal. Pools bill per concurrent session instead of per seat, which sounds cheaper — but for GovCon it usually isn't the right fit.

**Pools save money when** you have shift workers or part-time contractors where fewer than ~60% of users are online at the same time. If you have 50 users but only 20 ever log in simultaneously, you pay for 20 slots.

**Pools don't work well for GovCon because:**
- Sessions are non-persistent — files are gone on logout. Users must store everything on a network share (FSx, SharePoint), which adds scope to your ATO.
- Shared session infrastructure is harder to document in an SSP. AOs expect a 1:1 user-to-desktop mapping for end-user workstations.
- STIG hardening is different for Pools and less mature than for Personal desktops.

For a team of contractors doing standard office work with a live ATO — WorkSpaces Personal is the right product. The simplicity of one user, one desktop, one SSP entry is worth the price difference.

---

## Before You Start

### What you need from previous layers

Run these to confirm the earlier layers finished cleanly:

```bash
# Confirm AD is up and shows Active status
aws ds describe-directories \
  --region us-gov-west-1 \                         # <---- change me to your region
  --query 'DirectoryDescriptions[*].[DirectoryId,Name,Stage]' \
  --output table

# Confirm your hub private subnets exist (WorkSpaces deploys into hub VPC alongside AD)
aws ec2 describe-subnets \
  --region us-gov-west-1 \                         # <---- change me to your region
  --filters "Name=tag:Layer,Values=01-network" "Name=tag:Name,Values=*hub-private*" \
  --query 'Subnets[*].[SubnetId,CidrBlock,AvailabilityZoneId,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

You should see your AD directory in `Active` state and two hub private subnets in the `10.0.x.x` range in different Availability Zones. If the directory isn't `Active` yet, wait and check again — it takes 20-45 minutes.

### Find your WorkSpaces bundle ID

You need a bundle ID for the desktop image. List what's available in GovCloud:

```bash
aws workspaces describe-workspace-bundles \
  --owner AMAZON \
  --region us-gov-west-1 \                         # <---- change me to your region
  --query 'Bundles[*].[BundleId,Name]' \
  --output table
```

Look for **`Standard with Windows (Server 2025 based) (English)`** — this is the Windows 11 client experience on Server 2025 infrastructure, and what most AOs expect to see on end-user workstations today. Copy the `BundleId` — it looks like `wsb-abc123def`.

> **Windows 11 vs Windows Server 2025:** The naming is confusing. Bundles that say `(Server 2025 based)` deliver a **Windows 11 desktop** to users. Bundles that say `Windows Server 2025` deliver a full **server OS** — no Windows 11 Start menu, not what most AOs mean when they ask for Windows 11. For end-user WorkSpaces, you want the `(Server 2025 based)` variant.

The Standard bundle is the right default for most GovCon teams — enough compute for office work without the graphics card tax. If users need more headroom, Performance is the next tier up.

### Confirm the WorkSpaces OU exists

The WorkSpaces OU was created in `02-identity` as part of AD setup. Before running the plan, confirm it's there:

```bash
aws ds describe-directories \
  --region us-gov-west-1 \                         # <---- change me to your region
  --query 'DirectoryDescriptions[*].[DirectoryId,Name,Stage]' \
  --output table
```

The directory should show `Active`. If it does, the OU exists and you're ready to apply. If you skipped the OU creation step in `02-identity`, go back and do it now — `terraform apply` will fail with `InvalidParameterValuesException: The OU does not exist` if you don't.

---

## Step 1 — Init

All terraform commands below run from the `terraform/03-workspaces/` directory.

```bash
cd terraform/03-workspaces
terraform init \
  -backend-config="bucket=falcon-park-tfstate"    # <---- change me to your bucket name
```

---

## Step 2 — Plan

```bash
terraform plan \
  -var="project=falcon-park" \                     # <---- change me
  -var="environment=dev" \
  -var="tfstate_bucket=falcon-park-tfstate" \      # <---- change me
  -var="ad_domain_name=corp.falconpark.gov" \      # <---- change me — must match 02-identity exactly
  -var="ad_short_name=FALCONPARK" \                # <---- change me — must match 02-identity exactly
  -var='workspace_bundle_id=wsb-abc123def' \       # <---- change me — use "Standard with Windows (Server 2025 based) (English)" bundle ID
  -var='workspace_users=["bjohnson"]'              # <---- start with Bob, add more later
```

The plan should show the WorkSpaces directory, security group, KMS key, and one `aws_workspaces_workspace` resource — just Bob's for now.

---

## Step 3 — Apply

```bash
terraform apply \
  -var="project=falcon-park" \                     # <---- change me
  -var="environment=dev" \
  -var="tfstate_bucket=falcon-park-tfstate" \      # <---- change me
  -var="ad_domain_name=corp.falconpark.gov" \      # <---- change me
  -var="ad_short_name=FALCONPARK" \                # <---- change me
  -var='workspace_bundle_id=wsb-abc123def' \       # <---- change me — use "Standard with Windows (Server 2025 based) (English)" bundle ID
  -var='workspace_users=["bjohnson"]'              # <---- Bob first, add more names when ready
```

WorkSpaces take 15-25 minutes to provision per user. The directory registration itself takes another 5-10 minutes on top of that. Total: grab lunch.

---

## Adding Users Later

When the next person needs a desktop — say Sally decides she wants a WorkSpace too — create her in AD first (`ssmith` or whatever your naming convention is), then add her username to the list:

```bash
-var='workspace_users=["bjohnson","ssmith"]'
```

Re-apply. Terraform sees one existing WorkSpace (Bob's) and one new one to create (Sally's). Bob's desktop is untouched. Sally's provisions and is ready in 15-25 minutes.

To decommission: remove the user from AD first, then remove their username from the list and re-apply. Terraform destroys the WorkSpace. The user's D: drive data is gone permanently — make sure they've offboarded their files before you pull the trigger.

---

## What Success Looks Like

```
Apply complete! Resources: 6 added, 0 changed, 0 destroyed.

Outputs:
  workspaces_directory_id = "d-0abc..."
  workspace_ids = {
    "bjohnson" = "ws-0abc..."
  }
```

Send Bob the WorkSpaces client download link and his registration code (find it in the AWS console under WorkSpaces → Directories → your directory → Registration Code). He logs in with his AD credentials. Bob will stop calling. For a few days.

---

## Clean Up — Delete Your Admin Access Key

Bob has his desktop. The CI pipeline handles everything from `04-kubernetes` onward. The long-lived admin access key you created in `01-network` has done its job. Delete it now.

Find the access key ID (the one starting with `AKIA`):

```bash
aws iam list-access-keys --user-name <your-iam-username> --profile govcloud
```

Deactivate it first (lets you recover it if something breaks in the next 24 hours):

```bash
aws iam update-access-key \
  --user-name <your-iam-username> \
  --access-key-id <AKIAIOSFODNN7EXAMPLE> \
  --status Inactive \
  --profile govcloud
```

Once you've confirmed `04-kubernetes` applies cleanly through the pipeline, delete it permanently:

```bash
aws iam delete-access-key \
  --user-name <your-iam-username> \
  --access-key-id <AKIAIOSFODNN7EXAMPLE> \
  --profile govcloud
```

Then clear it from your local config — it no longer works and there's no reason to keep it:

```bash
aws configure --profile govcloud set aws_access_key_id ""
aws configure --profile govcloud set aws_secret_access_key ""
```

> From this point on, AWS access goes through the GitLab OIDC role for automation and through IAM Identity Center (or a scoped role) for human access to the cluster. No more long-lived keys.

---

## Troubleshooting

Paste the error output below and drop this whole file into Claude or ChatGPT: *"I'm setting up AWS WorkSpaces in GovCloud. Here's my error."*

---

### Paste Error Output Below

```
<paste terraform output here>
```

---

**Common issues:**

| Error | What it means | Fix |
|-------|---------------|-----|
| `InvalidParameterValuesException: The OU ... does not exist` | Skipped the OU creation step, or OU path is wrong | Create the OU under `OU=<AD_SHORT_NAME>`, not `OU=Computers` — see the OU creation section above |
| `Error: User not found` | Username not in AD | Create the user in AD first (in 02-identity), then apply |
| WorkSpace stuck in `PENDING` | Normal provisioning lag | Wait 30 minutes. If still stuck, check CloudTrail for the underlying error. |
| `Error: InvalidResourceStateException` on directory | AD not fully provisioned | Go back to `02-identity`, confirm the AD state is `Active` in the console |
| `Access is denied` when creating OU via PowerShell | Trying to create under `CN=Computers` — Managed AD blocks this | See the OU creation section in `02-identity` README — use `OU=<AD_SHORT_NAME>,DC=...` as the `-Path`. |
