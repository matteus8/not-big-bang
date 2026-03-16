# 03 — WorkSpaces

Bob in Tampa is about to stop calling Sally's cell phone.

The SA drew the short straw on this one — which is fine, because once it's running, the day-to-day is manageable. For right now, you just want one WorkSpace: Bob's. You'll add more people later. The only variable that controls how many WorkSpaces exist is `workspace_users` — it's a list of AD usernames. One username, one desktop. Ten usernames, ten desktops. Add a name and re-apply to provision; remove a name (after offboarding in AD) and re-apply to deprovision. That's the whole lifecycle.

**Credentials:** Use the same admin AWS profile you set up in `01-network` (`AWS_PROFILE=govcloud`). This is still a local apply — no CI involvement yet. After this layer is done and `04-kubernetes` runs cleanly through the pipeline, you'll delete the admin access key. Not yet.

**A note on running this locally:** 02-identity said the pipeline takes over from here — and it does for layers 04 and beyond. But 03-workspaces is different. Adding or removing a WorkSpace user is a day-to-day SA task, not a code deployment. Managing a dynamic user list through CI variables every time someone joins the project is more friction than it's worth. The SA runs this one from their terminal. The `apply:workspaces` CI job exists as a fallback, but in practice: new person starts, SA creates them in AD, SA updates the list and runs `terraform apply`, done in 5 minutes.

**What this builds:**
- WorkSpaces directory registered against your Managed AD
- Security group that lets desktops reach AD (in the hub) and the internet via NAT, but nothing else
- KMS-encrypted root and user volumes (NIST SC-28, checked)
- One WorkSpace per username in your list — add more by updating the list and re-applying
- Users are **not** local admins. This is not negotiable.

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

# Confirm your WorkSpaces spoke subnets exist
aws ec2 describe-subnets \
  --region us-gov-west-1 \                         # <---- change me to your region
  --filters "Name=tag:Layer,Values=01-network" \
  --query 'Subnets[*].[SubnetId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

You should see your AD directory in `Active` state and subnets in the `10.1.x.x` range (the WorkSpaces spoke). If the directory isn't `Active` yet, wait and check again — it takes 20-45 minutes.

### Find your WorkSpaces bundle ID

You need a bundle ID for the desktop image. List what's available in GovCloud:

```bash
aws workspaces describe-workspace-bundles \
  --owner AMAZON \
  --region us-gov-west-1 \                         # <---- change me to your region
  --query 'Bundles[*].[BundleId,Name]' \
  --output table
```

Find "Standard with Windows Server 2022" or similar. Copy the `BundleId` — it looks like `wsb-abc123def`. The Standard bundle is the right default for most GovCon teams — enough compute for office work without the graphics card tax.

### Create the OU in AD first

WorkSpaces needs an OU to place computer objects. This cannot be done from the Directory Service console UI — you need to use the directory administration EC2.

**Launch the admin EC2:**
1. Go to **AWS Directory Service → Directories → your directory**
2. Click **Actions → Launch directory administration EC2 instance**
3. AWS creates a Windows EC2 with RSAT tools pre-installed. Once it's running, connect to it via **EC2 → Instances → your instance → Connect → Session Manager**.

**Create the OU via PowerShell:**

First, retrieve your AD admin password from **AWS Secrets Manager → your secret → Retrieve secret value**.

Then in the Session Manager terminal, type `powershell` and run:

```powershell
$password = ConvertTo-SecureString "YOUR_AD_ADMIN_PASSWORD" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("Admin@corp.falconpark.gov", $password)
New-ADOrganizationalUnit -Name "WorkSpaces" -Path "OU=FALCONPARK,DC=corp,DC=falconpark,DC=gov" -Credential $cred -Server "corp.falconpark.gov"
```

Replace `FALCONPARK` with your `ad_short_name`, and adjust the domain components to match your `ad_domain_name`. No output means success.

> **Important:** The OU goes under `OU=<AD_SHORT_NAME>`, not `OU=Computers`. AWS Managed AD restricts the `Admin` user from creating objects directly under `CN=Computers`. You get an "Access is denied" error if you try.

Verify it was created:
```powershell
Get-ADOrganizationalUnit -Filter * -SearchBase "OU=FALCONPARK,DC=corp,DC=falconpark,DC=gov" -Credential $cred -Server "corp.falconpark.gov" | Select-Object DistinguishedName
```

You should see `OU=WorkSpaces,OU=FALCONPARK,DC=corp,...` in the output.

If you skip this step entirely, the WorkSpaces directory registration will fail with a vague error about the OU not existing.

> **Clean up the admin EC2 when you're done.** The directory administration EC2 costs money while it's running and you don't need it after the OU is created. Go to **EC2 → Instances**, find the instance, and **Terminate** it. If you leave it running and later try to destroy `01-network`, Terraform will hang with `DependencyViolation` because the EC2 is sitting inside the hub VPC.

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
  -var='workspace_bundle_id=wsb-abc123def' \       # <---- change me to the bundle ID from the lookup above
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
  -var='workspace_bundle_id=wsb-abc123def' \       # <---- change me
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
| `Access is denied` when creating OU via PowerShell | Trying to create under `CN=Computers` — Managed AD blocks this | Use `OU=<AD_SHORT_NAME>,DC=...` as the `-Path`. AWS Managed AD only grants Admin rights within the delegated OU, not the built-in Computers container. |
