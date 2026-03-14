# Windows Lifecycle
### *How to Patch Windows Without Losing Your Mind*

Traditional patch management for 50 Windows VMs means 50 Ansible runs, 50 failure modes, and 50 patches for the Ansible server itself. We don't do that here.

**Our model:** One Golden Image. One monthly rebuild. Zero playbooks.

---

## 1. The Philosophy

We use **AWS WorkSpaces with Windows Server 2022 Desktop Experience**. It looks and feels like Windows 11 to the user (Bob won't know the difference), but it sidesteps the 100-user BYOL licensing requirement that comes with actual Windows 11.

The key insight: **WorkSpaces separates user data from the OS.**

| Drive | What Lives There | Survives a Rebuild? |
| :--- | :--- | :--- |
| **C:\\** | OS, apps, security stack | **NO** — wiped and replaced |
| **D:\\** | User profile, documents, desktop | **YES** — untouched |

This means patching is just replacing the C: drive. User data is never at risk.

---

## 2. The Golden Image

Sally owns the Golden Image. It is a single "Master" WorkSpace that no real user ever touches.

**What's on the Golden Image:**
- Windows Server 2022 Desktop Experience, fully patched
- All required software (browsers, Office, mission apps)
- STIG-compliant GPO baseline applied
- Security stack (EDR/AV) installed and configured
- Any `# <--- CHANGE ME` values in the config set for this environment

**Sally's monthly process (roughly 2 hours):**
1. Start the Master WorkSpace
2. Open Windows Update — install everything, reboot until clean
3. Update any software with new versions (check pinned versions in the shared drive)
4. Verify the security stack agent is checking in
5. Close the Master WorkSpace
6. In AWS Console: WorkSpaces → Master WorkSpace → Actions → **Create Image**
7. Name it: `golden-YYYY-MM` (e.g., `golden-2026-03`)
8. Wait for image status to show `AVAILABLE` (takes 20–45 min)
9. Update the WorkSpaces bundle to point to the new image
10. Notify the SA: *"New image is ready. Bundle updated. You're clear to rebuild."*

---

## 3. The Rebuild (SA's Job)

Once Sally gives the green light:

```
Pre-Rebuild Checklist:
[ ] Send user notification email (72hr notice minimum)
[ ] Confirm users know to save work to D:\ drive
[ ] Confirm new bundle is AVAILABLE in AWS Console
[ ] Schedule rebuild window (recommend Friday 6pm local time)
```

**Rebuild steps:**
1. AWS Console → WorkSpaces
2. Select all user WorkSpaces (not the Master)
3. Actions → **Rebuild WorkSpaces**
4. Confirm the prompt
5. Monitor status — machines move through REBUILDING → AVAILABLE (15–30 min per machine, they run in parallel)
6. Log into one test WorkSpace to verify the image looks correct
7. Send the all-clear email to users

> **Hardware Note:** Always use **Performance Bundles (2vCPU / 7.5GB RAM)**. If you drop to a smaller bundle, the security stack will consume available RAM, the machine will become unresponsive, and Bob in Tampa will start calling your personal cell phone. Don't do this.

---

## 4. D:\\ Drive Policy (Tell Your Users)

Users must be trained on one rule: **Everything important goes on D:\\.**

Reinforce this at onboarding. Include it in the rebuild notification email. Put it in your welcome message. Tattoo it somewhere.

```
Recommended user communication template:

Subject: Desktop Maintenance Window – Action Required

Your AWS WorkSpace will be rebuilt on [DATE] at [TIME].
This is a routine security patching event.

ACTION REQUIRED:
- Save all documents, downloads, and desktop shortcuts to your D:\ drive.
- Anything on the C:\ drive (including the Desktop if not redirected) will be lost.

Your D:\ drive (My Documents, redirected Desktop) is SAFE and will not be affected.

If you have questions, contact [SA name].
```

---

## 5. Rollback

If the new image causes problems:

1. Note the previous image name (e.g., `golden-2026-02`)
2. AWS Console → WorkSpaces → Bundles → Edit bundle → point back to old image
3. Rebuild affected WorkSpaces using the old bundle
4. File a ticket with Sally describing the failure

> There is no automatic rollback. The old image stays available in AWS until you explicitly delete it. Don't delete old images until the new one has been stable for at least two weeks.

---

## 6. STIG Compliance

The Golden Image must meet the **Windows Server 2022 STIG** baseline before it's considered production-ready. Sally applies these as GPOs during the image build process.

Key STIG categories covered by our GPO baseline:

| Control Area | What We Do |
| :--- | :--- |
| Account Policies | Password complexity, lockout thresholds |
| Audit Policies | Logon events, privilege use, object access |
| Windows Firewall | Host-based rules enforced via GPO |
| Windows Update | Managed via WSUS or AWS patching schedule |
| AppLocker / Defender | Application whitelisting and AV policy |

Full STIG-to-NIST mapping is in `ato-mappings.md`.

---

## 7. Why Not Ansible?

Because:
- 50 users = 50 ways for a playbook to fail
- The Ansible server itself needs patches
- SSH/WinRM access to 50 boxes is its own attack surface
- A failed run at midnight means someone (you) is debugging YAML at 1am

The Golden Image + Rebuild approach removes all of that. You patch one machine, take a snapshot, and distribute it. The complexity ceiling is fixed regardless of how many users you have.
