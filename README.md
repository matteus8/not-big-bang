This approach is a direct response to "Black Box Fatigue." By removing the abstraction layers (the nested Helm charts and 500-line `values.yaml` files), you make the infrastructure readable for both a Human Lead and an LLM.

Here is the directory structure and the top-level README designed to be the "source of truth" for the environment.

### 1. Directory Structure (3 Layers)

```text
.
├── terraform/
│   ├── 01-network/          # VPC, Subnets (Internal/External), Flow Logs
│   ├── 02-iam-roles/        # The "Least Privilege" definitions for EKS/Nodes
│   └── 03-eks-cluster/      # The EKS Cluster & Managed Node Groups
├── k8s-manifests/
│   ├── 01-platform-auth/    # Keycloak / OIDC Config (Hardened)
│   ├── 02-data-layer/       # Strimzi Kafka Operator & Cluster definitions
│   ├── 03-observability/    # Logging (Fluentbit) and Metrics (Prometheus)
│   └── 04-security-ops/     # OPA Gatekeeper policies & Vault Sidecars
├── scripts/
│   ├── bootstrap.sh         # Basic environment check and user setup
│   ├── package-zarf.sh      # Script to containerize this for air-gap
│   └── rotate-certs.sh      # Manual trigger for cert-manager rotations
├── docs/
│   ├── ato-mapping.md       # NIST 800-53 controls mapped to this repo
│   └── air-gap-guide.md     # How to move this to a SCIF/High-side
└── README.md                # Top-level Entry Point
```

---

### 2. Top-Level README.md

```markdown
# Simple Cloud Platform: GovCon Reference Architecture (AWS)

## The Philosophy: "Anti-Big-Bang"
Most Government Cloud platforms (like Big Bang or Iron Bank variants) are powerful but operate as "Black Boxes." When a deployment fails, you are digging through thousands of lines of nested Helm logic.

**This repo is different:**
- **No Hidden Booleans:** We do not hide complex logic behind `enabled: true` flags.
- **Visual Transparency:** All YAML and Terraform is meant to be read by a human (or an LLM). 
- **Piece-by-Piece:** You do not run one script to build the world. You deploy in stages so you can troubleshoot the ATO (Authority to Operate) requirements at each layer.
- **Hardening by Default:** Every image reference includes a comment pointing to the **Iron Bank (Registry One)** equivalent.

## Context for Colorado Springs / DC Areas
This stack is specifically tuned for USSF, USAF, and IC requirements:
1. **ATO-First:** Documentation focuses on RMF (Risk Management Framework) compliance.
2. **Data-Centric:** Built-in Kafka support via Strimzi for sensor data/ETL.
3. **Air-Gap Ready:** Integrated with Zarf for deployment to IL5/IL6 or disconnected environments.

---

## Deployment Stages (The "Order of Operations")

Each folder contains its own `README.md` with specific "ATO Gotchas."

### 1. Infrastructure Layer (`/terraform`)
*   **01-Network:** Sets up the VPC. *ATO Note: We force VPC Flow Logs on by default.*
*   **02-IAM:** Defines exactly what the nodes can touch. *No Admin Access.*
*   **03-EKS:** Provisions the cluster.
    *   **Action Required:** You must update the `account_id` in `variables.tf`.

### 2. Identity & Access (`/k8s-manifests/01-platform-auth`)
*   Deploys Keycloak. 
*   **Hardening:** We use OIDC for cluster access. No `cluster-admin` for users; roles are mapped to AD/LDAP groups.
    *   **Change Me:** Swap the generic Keycloak image for the `ironbank/keycloak` image noted in `keycloak.yaml`.

### 3. Data Movement (`/k8s-manifests/02-data-layer`)
*   Deploys Strimzi (Kafka).
*   **Security:** mTLS is forced for all internal traffic. No plaintext Kafka allowed.

### 4. Observability (`/k8s-manifests/03-observability`)
*   The "Audit Trail." This is what your ISSO (Information System Security Officer) wants to see.
*   Centralized logging for every container in the cluster.

---

## The "Iron Bank" Rule & The `# <--- CHANGE ME` Pattern
Throughout this repo, you will see comments like this:

```yaml
image: "quay.io/strimzi/kafka:latest" # <--- CHANGE ME: Use ironbank.repository.com/strimzi/kafka:version for ATO
```

**Do not just run this code.** You are expected to read the manifests. This ensures that when the Auditor asks "How is this traffic encrypted?", you actually know the answer because you didn't just toggle a boolean.

## AI-Context Optimization
This repository is designed to be fed into an LLM (ChatGPT, Claude, Gemini). 
- **Flat Files:** Minimal nesting makes it easy for the AI to "see" the relationship between IAM roles and Kubernetes Service Accounts.
- **Self-Documenting:** The scripts are simple Bash, not complex Python wrappers.

## Air-Gap Deployment
To package this for an air-gapped SCIF:
1. Install [Zarf](https://zarf.dev/).
2. Run `./scripts/package-zarf.sh`.
3. This will pull all images, charts, and files into a single `.tar.zst` file for transfer.
```

### Why this works for your goals:
1.  **AI Friendly:** An LLM can easily parse a 3-layer deep directory. It won't get lost in "Helm-template-hell."
2.  **Educational:** A Junior Devops guy can actually learn *why* the VPC Flow logs are there (because the README told him it's for the ATO).
3.  **Audit Ready:** When the ISSO asks about data-in-transit, the user can point directly to the Strimzi YAML where mTLS is defined, rather than searching through a 2,000-line "Big Bang" values file.
4.  **Flexible:** If they don't need Kafka, they just don't deploy folder `02`. The "Big Bang" usually breaks if you try to pull a core component out.