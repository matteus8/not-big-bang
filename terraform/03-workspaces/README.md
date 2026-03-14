# 03 — WorkSpaces

Bob in Tampa is about to stop calling Sally's cell phone.

The SA drew the short straw on this one — which is fine, because once it's running, the day-to-day is manageable. For right now, you just want one WorkSpace: Bob's. You'll add more people later. The only variable that controls how many WorkSpaces exist is `workspace_users` — it's a list of AD usernames. One username, one desktop. Ten usernames, ten desktops. Add a name and re-apply to provision; remove a name (after offboarding in AD) and re-apply to deprovision. That's the whole lifecycle.

**A note on running this locally:** 02-identity said the pipeline takes over from here — and it does for layers 04 and beyond. But 03-workspaces is different. Adding or removing a WorkSpace user is a day-to-day SA task, not a code deployment. Managing a dynamic user list through CI variables every time someone joins the project is more friction than it's worth. The SA runs this one from their terminal. The `apply:workspaces` CI job exists as a fallback, but in practice: new person starts, SA creates them in AD, SA updates the list and runs `terraform apply`, done in 5 minutes.

**What this builds:**
- WorkSpaces directory registered against your Managed AD
- Security group that lets desktops reach AD (in the hub) and the internet via NAT, but nothing else
- KMS-encrypted root and user volumes (NIST SC-28, checked)
- One WorkSpace per username in your list — add more by updating the list and re-applying
- Users are **not** local admins. This is not negotiable.

---

## Before You Start

### What you need from previous layers

Run these to confirm the earlier layers finished cleanly:

```bash
# Confirm AD is up and shows Active status
aws ds describe-directories \
  --region us-gov-west-1 \
  --query 'DirectoryDescriptions[*].[DirectoryId,Name,Stage]' \
  --output table

# Confirm your WorkSpaces spoke subnets exist
aws ec2 describe-subnets \
  --region us-gov-west-1 \
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
  --region us-gov-west-1 \
  --query 'Bundles[*].[BundleId,Name]' \
  --output table
```

Find "Standard with Windows Server 2022" or similar. Copy the `BundleId` — it looks like `wsb-abc123def`.

### Create the OU in AD first

WorkSpaces needs an OU to place computer objects. You don't have a domain-joined machine yet — that's fine. AWS Directory Service lets you do this from the console.

Go to **AWS Directory Service → your directory → Actions → Open Active Directory Users and Computers** (this launches an RDP-based management console directly from the browser, no client needed).

Navigate to your domain, find or create `Computers`, then create the OU:

```
OU=WorkSpaces,OU=Computers,DC=corp,DC=falconpark,DC=gov    # <---- change me to match your AD domain
```

If you prefer PowerShell, you can also do this from a `t3.micro` Windows instance joined to the domain:
```powershell
New-ADOrganizationalUnit -Name "WorkSpaces" -Path "OU=Computers,DC=corp,DC=falconpark,DC=gov"
```

If you skip this entirely, the WorkSpaces directory registration will fail with a vague error about the OU not existing.

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
  -var="project=falcon-park" \                     # <---- change me
  -var="environment=dev" \
  -var="tfstate_bucket=falcon-park-tfstate" \      # <---- change me
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
| `InvalidParameterValuesException: The OU ... does not exist` | Skipped the OU creation step | Create the OU in AD before applying |
| `Error: User not found` | Username not in AD | Create the user in AD first, then apply |
| WorkSpace stuck in `PENDING` | Normal provisioning lag | Wait 30 minutes. If still stuck, check CloudTrail for the underlying error. |
| `Error: InvalidResourceStateException` on directory | AD not fully provisioned | Go back to `02-identity`, confirm the AD state is `Active` in the console |
