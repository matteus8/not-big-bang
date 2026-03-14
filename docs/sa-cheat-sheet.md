# SA Cheat Sheet
### *One-Liners for the Meeting-Sitter*

You're the SA. You sit in meetings, reset passwords, and sign things. This doc is for you.
You don't need to know Terraform. You need to know enough to not break things and enough to sound credible when someone calls.

---

## 1. The Three Things You Own

| Thing | What It Is | Your Job |
| :--- | :--- | :--- |
| **Managed Microsoft AD** | The identity backbone. Users, groups, GPOs. | Add/remove users. Reset passwords. Don't touch the OU structure. |
| **AWS WorkSpaces** | The Windows desktops your users live in. | Rebuild stale machines. Unlock locked accounts. |
| **Keycloak (via the team)** | The SSO layer for the apps. | Escalate to Sally or Jim. You don't touch this. |

---

## 2. Password Reset (Most Common Call)

```powershell
# In Active Directory Users and Computers (ADUC):
# 1. Find the user (Bob in Tampa)
# 2. Right-click → Reset Password
# 3. Force change at next logon: YES
# 4. Tell Bob his temp password (set something compliant with your GPO policy)
```

> **Note:** If Bob says "it still doesn't work," check that his WorkSpace isn't in an ERROR state before you reset anything else.

---

## 3. WorkSpace User Is Locked Out

```bash
# Via AWS Console → WorkSpaces → Find user's WorkSpace
# State should be "AVAILABLE"
# If state is "ERROR" → click Rebuild (Bob loses C: drive, D: drive is safe)
# If state is "STOPPED" → click Start

# Via AWS CLI (if you're feeling brave):
aws workspaces describe-workspaces --filters Name=UserName,Values=bob.tampa
aws workspaces reboot-workspaces --reboot-workspace-requests WorkspaceId=ws-xxxxxxxxx
```

---

## 4. Monthly Patch Cycle (Your Biggest Day)

Sally updates the Golden Image. You do the rebuild. Here's the order:

1. **Confirm** with Sally that the new bundle is ready (she'll tell you)
2. **Notify users** — send the email: *"Your desktop will be rebuilt Friday at 6pm. Save everything to your D: drive."*
3. **Rebuild** all WorkSpaces via the AWS Console (WorkSpaces → select all → Actions → Rebuild)
4. **Verify** one machine comes back clean (log in as a test user)
5. **Stand by** for Bob's call from Tampa. There will always be a Bob.

> See `windows-lifecycle.md` for the full patching philosophy.

---

## 5. Adding a New User

```
1. Create account in Active Directory (ADUC)
   - Place in the correct OU (e.g., OU=Users,OU=Enclave-Alpha,DC=mission,DC=local)
   - Add to the correct security group (e.g., SG-WorkSpaces-Users)

2. Create WorkSpace in AWS Console
   - WorkSpaces → Create WorkSpaces
   - Select: Managed AD directory
   - Select user from AD
   - Bundle: Performance (2vCPU / 7.5GB RAM) ← DO NOT go lower
   - Running mode: AUTO STOP (saves money when Bob goes home)

3. Email user their login instructions (use the template in the shared drive)
```

---

## 6. Removing a User (Offboarding)

```
1. Disable account in Active Directory (right-click → Disable Account)
2. Remove WorkSpace in AWS Console (Actions → Remove WorkSpace)
   !! D: drive data is deleted. Make sure it's been backed up first. !!
3. Remove from all security groups in AD
4. File the offboarding ticket. Done.
```

---

## 7. Useful AWS CLI One-Liners

```bash
# List all WorkSpaces and their states
aws workspaces describe-workspaces \
  --query 'Workspaces[*].{User:UserName,State:State,ID:WorkspaceId}' \
  --output table

# Check AD directory health
aws ds describe-directories \
  --query 'DirectoryDescriptions[*].{Name:Name,Type:Type,Status:Stage}' \
  --output table

# Get WorkSpaces bundle IDs (useful when creating new ones)
aws workspaces describe-workspace-bundles --owner AMAZON \
  --query 'Bundles[?contains(Name, `Performance`)].{ID:BundleId,Name:Name}' \
  --output table
```

---

## 8. Who To Call

| Problem | Person |
| :--- | :--- |
| WorkSpace won't rebuild after 3 tries | **Jim** |
| Keycloak / SSO login failures | **Jim** |
| Kafka / app is down | **Sally** |
| Terraform changes needed | **Sally or Jim** |
| Auditor wants a report | **You** (pull from AWS Console → generate it) |
| Bob in Tampa is calling your cell | **Expected. Answer it.** |
