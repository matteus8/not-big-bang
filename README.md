# The "Small-Shop Hero" Platform
### *GovCon Cloud Infrastructure for the Rest of Us*

## 0. The "Oh No, I'm the Lead" Reality Check
You’re a 2-3 person shop. You just won a sub-contract for a mission in DC/Colorado-Springs/Huntsville. You looked at the "Big Bang" or "Iron Bank" source code and realized you don't have a 20-person platform team to keep that black box from exploding.

**This repo is your escape hatch.** 

We designed this for **Sally & Jim** (the two engineers doing the real work) and **The SA** (who sits in meetings and resets passwords).
It’s built to handle about 50 users, 5-10 enclaves, and a whole lot of "Cyber" scrutiny without requiring a single Ansible playbook or a PhD in YAML-nesting.

---

## 1. The Vibe: "Anti-Big-Bang"
Most GovCloud platforms are giant blobs of "trust me, it works." When they break, you’re digging through 5,000 lines of nested Helm logic.

**Our Philosophy:**
- **No Magic Booleans:** We don’t hide 100 resources behind a single `enabled: true` flag. 
- **Pixels, Not Packets:** We don’t do VPNs. We stream Windows desktops to the users. It keeps the "dirty" office network away from our "clean" cloud.
- **LLM-Ready:** The code is flat and simple. You can literally copy-paste a directory into ChatGPT or Claude and ask, *"Why is my Kafka pod sad?"* and it will actually know the answer.
- **Read the Comments:** Look for `# <--- CHANGE ME`. This is where the ATO (Authority to Operate) happens.

---

## 2. The Architecture of Least Resistance
We use **Managed Services** wherever possible. Why? Because Sally and Jim also want to go to the team happy hour, not patch Linux kernels till 7pm.

| Layer | Technology | The "Why" |
| :--- | :--- | :--- |
| **Front Door** | **AWS WorkSpaces** | Windows 11. Cyber wants a Start Menu; we give them a Start Menu. |
| **Identity** | **Managed Microsoft AD** | Cyber’s comfort blanket. It handles the users, the GPOs, and the trust. |
| **The Brain** | **EKS / AKS** | Managed Kubernetes. This is where your Kafka and important apps live. |
| **Data Bus** | **Strimzi Kafka** | Because everyone in DC loves a good ETL pipeline. |
| **Hardening** | **Container Images** | We don't pull from Docker Hub. We only feast with trusted repos (Iron Bank, etc.). |

---

## 3. The "No-Ansible" Windows Pact
We don't use Ansible to patch Windows. Why? Because 50 users = 50 ways for a playbook to fail. 

**The Strategy:**
1. **The Golden Image:** Sally updates one "Master" WorkSpace once a month.
2. **The Rebuild:** You click "Rebuild" on the 50 WorkSpaces.
3. **The Result:** The C: drive is replaced with a fresh, patched image. User data lives on the D: drive and survives. 
4. **Hardware Note:** Windows 11 is a RAM hog. We use **Performance Bundles (2vCPU / 8GB RAM)**. If you try to run it on 4GB, "Microsoft Copilot" will brick the machine and the user Bob in Tampa FL will start calling your personal cell phone.

---

## 4. The Map (Directory Structure)

```text
.
├── terraform/
│   ├── 01-network/          # VPC & Transit Gateway (The Enclave Backbone)
│   ├── 02-identity/         # Managed AD (Setup this first or nothing works)
│   ├── 03-workspaces/       # The Windows 11 Pool (The "Hero" Layer)
│   └── 04-kubernetes/       # EKS/AKS Cluster (The App Engine)
├── k8s-manifests/
│   ├── 01-platform-auth/    # Keycloak OIDC (Hardened Identity)
│   ├── 02-data-layer/       # Strimzi Kafka (The Data Bus)
│   └── 03-observability/    # Centralized Logs (To keep the ISSO happy)
├── docs/
│   ├── sa-cheat-sheet.md    # One-liners for the Meeting-Sitter SA
│   ├── windows-lifecycle.md # How to patch Windows without losing your mind
│   └── ato-mappings.md      # NIST 800-53 controls (The "Pass the Audit" guide)
└── README.md
```

---

## 5. Order of Operations (How to Win)

### Step 1: The Plumbing (`/terraform/01-02`)
Deploy the Network and Identity. If your Managed AD isn't healthy, your Windows desktops will be "orphans."
This is where you set up the Transit Gateway to talk to those 7 different enclaves.

### Step 2: The Front Door (`/terraform/03`)
Spin up the WorkSpaces. Get one user (Bob in Tampa, FL) logged in. If Bob can see a Windows Start Menu... Nice!

### Step 3: The Brain (`/terraform/04` + `/k8s-manifests`)
Deploy the cluster. 
We use standard managed nodes that Sally can troubleshoot if she needs to.
Deploy Strimzi Kafka and point your Windows apps at it.

---

## 6. Air-Gap & AI Readiness
- **The SCIF Factor:** If you're heading into a SCIF, we've included **Zarf** support. 
  - Run `./scripts/package-zarf.sh` and it will bundle this entire repo, including the hardened Kafka and Keycloak images, zarf-cli, and raw manifests into one giant file you can carry in on a disc.
  - There is a whole `README.md` **dedicated** to Zarf: To make your life easy and get yourself to happy hour, please read the entire thing before deploying anything.

- **LLM Context:** Every folder has a flat structure. If you're stuck, feed the `terraform/` folder and the `k8s-manifests/` folder to your favorite AI. 
    > It will understand exactly how the IAM roles in AWS connect to the ServiceAccounts in Kubernetes as well as tell you what IRSA is.

---

## 7. The Final Word
This repo doesn't solve every problem. It doesn't cook dinner. But it **does** get a small team to a "Ready for ATO" state in a week instead of a year.

**Sally & Jim:** Start with `terraform/01-network`. 
**The SA:** Go read `docs/sa-cheat-sheet.md`. 
**Team Lead:** Relax. You’ve got this. You're not here by chance—maybe some luck, but:
> "Luck is what happens when preparation meets opportunity."