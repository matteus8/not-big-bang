# ATO Mappings
### *NIST 800-53 Controls — The "Pass the Audit" Guide*

This document maps the platform's technical components to their corresponding NIST SP 800-53 security controls.
When the SCA (Security Control Assessor) asks *"How are you meeting AC-2?"*, point them here.

> **How to use this:** Find the control family, read the "How We Meet It" column, and point to the relevant Terraform or manifest directory as evidence. The goal is to make the auditor's job easy so they leave faster.

---

## Control Families Covered

| Family | Name | Coverage |
| :--- | :--- | :--- |
| **AC** | Access Control | Managed AD, Keycloak, WorkSpaces |
| **AU** | Audit and Accountability | CloudWatch, Observability stack |
| **CM** | Configuration Management | Golden Image, Terraform IaC |
| **IA** | Identification and Authentication | Managed AD, Keycloak OIDC, MFA |
| **SC** | System and Communications Protection | VPC isolation, Strimzi mTLS, WorkSpaces streaming |
| **SI** | System and Information Integrity | EDR/AV on Golden Image, container image hardening |
| **CA** | Assessment, Authorization, Monitoring | This document. POA&M. |

---

## AC — Access Control

| Control | Title | How We Meet It | Evidence |
| :--- | :--- | :--- | :--- |
| **AC-2** | Account Management | User accounts created and managed in Managed Microsoft AD. Offboarding removes AD account and terminates WorkSpace. | `terraform/02-identity/` |
| **AC-3** | Access Enforcement | Security groups in AD enforce role-based access to WorkSpaces and app resources via Keycloak. | `terraform/02-identity/`, `k8s-manifests/01-platform-auth/` |
| **AC-4** | Information Flow Enforcement | VPC with Transit Gateway controls enclave-to-enclave traffic. No direct user-to-enclave routing — all access flows through WorkSpaces streaming. | `terraform/01-network/` |
| **AC-17** | Remote Access | No traditional VPN. Users access via AWS WorkSpaces streaming protocol (PCoIP/WSP). The "dirty" office network never touches the cloud. | `terraform/03-workspaces/` |
| **AC-20** | Use of External Systems | WorkSpaces streaming is the only approved external access path. Users cannot install unapproved software (enforced via AppLocker GPO on Golden Image). | `docs/windows-lifecycle.md` |

---

## AU — Audit and Accountability

| Control | Title | How We Meet It | Evidence |
| :--- | :--- | :--- | :--- |
| **AU-2** | Event Logging | CloudTrail captures all AWS API calls. CloudWatch captures WorkSpace session events. Kubernetes audit logs forwarded to observability stack. | `k8s-manifests/03-observability/` |
| **AU-3** | Content of Audit Records | Log events include: timestamp, source IP, user identity, resource affected, success/failure. Configured in CloudWatch log groups. | `k8s-manifests/03-observability/` |
| **AU-9** | Protection of Audit Information | CloudTrail logs written to S3 with bucket policy denying delete. CloudWatch log groups have retention policy. | `terraform/01-network/` |
| **AU-12** | Audit Record Generation | All components (AD, EKS, Kafka, WorkSpaces) generate audit records forwarded to centralized observability stack. | `k8s-manifests/03-observability/` |

---

## CM — Configuration Management

| Control | Title | How We Meet It | Evidence |
| :--- | :--- | :--- | :--- |
| **CM-2** | Baseline Configuration | All infrastructure defined as Terraform IaC. Golden Image defines the Windows baseline. Kubernetes manifests define the app baseline. | `terraform/`, `k8s-manifests/` |
| **CM-3** | Configuration Change Control | All changes to infrastructure go through Git. No manual console changes in production. `# <--- CHANGE ME` comments mark environment-specific values requiring review. | Git history |
| **CM-6** | Configuration Settings | Windows STIG GPOs applied via Golden Image. Kubernetes STIG applied via manifest configurations. | `docs/windows-lifecycle.md` |
| **CM-7** | Least Functionality | WorkSpaces run AppLocker whitelisting. Containers sourced from hardened registries (Iron Bank / approved repos) only — no Docker Hub. | `k8s-manifests/` |
| **CM-11** | User-Installed Software | AppLocker GPO on Golden Image prevents users from installing unapproved software. Enforced at rebuild. | `docs/windows-lifecycle.md` |

---

## IA — Identification and Authentication

| Control | Title | How We Meet It | Evidence |
| :--- | :--- | :--- | :--- |
| **IA-2** | Identification and Authentication (Org Users) | All users authenticate via Managed Microsoft AD. WorkSpaces login requires AD credentials. App SSO via Keycloak OIDC federation to AD. | `terraform/02-identity/`, `k8s-manifests/01-platform-auth/` |
| **IA-2(1)** | MFA for Privileged Accounts | MFA enforced in Keycloak for all admin/privileged roles. | `k8s-manifests/01-platform-auth/` |
| **IA-2(2)** | MFA for Non-Privileged Accounts | MFA enforced in Keycloak for all user accounts accessing platform apps. | `k8s-manifests/01-platform-auth/` |
| **IA-5** | Authenticator Management | AD password policy enforced via GPO: complexity, minimum length, rotation. Service accounts use managed credentials (AWS Secrets Manager or IRSA). | `terraform/02-identity/` |
| **IA-8** | Non-Org User Identification | External users (if any) authenticate through a separate Keycloak realm with equivalent controls. | `k8s-manifests/01-platform-auth/` |

---

## SC — System and Communications Protection

| Control | Title | How We Meet It | Evidence |
| :--- | :--- | :--- | :--- |
| **SC-7** | Boundary Protection | VPC with defined subnets and security groups. Transit Gateway enforces enclave boundaries. No workloads exposed directly to the internet. | `terraform/01-network/` |
| **SC-8** | Transmission Confidentiality and Integrity | Strimzi Kafka enforces mTLS for all producer/consumer connections. EKS uses Istio service mesh for pod-to-pod encryption. WorkSpaces uses encrypted streaming protocol. | `k8s-manifests/02-data-layer/` |
| **SC-12** | Cryptographic Key Management | AWS KMS used for key management. EKS secrets encryption enabled. Kafka TLS certificates managed by cert-manager. | `terraform/04-kubernetes/` |
| **SC-28** | Protection of Information at Rest | EKS etcd encrypted via KMS. EBS volumes encrypted. S3 buckets encrypted with SSE. Managed AD data encrypted at rest by AWS. | `terraform/` |
| **SC-39** | Process Isolation | Kubernetes namespace isolation. WorkSpaces provide per-user OS isolation. Each enclave in a separate VPC/subnet. | `terraform/01-network/`, `terraform/04-kubernetes/` |

---

## SI — System and Information Integrity

| Control | Title | How We Meet It | Evidence |
| :--- | :--- | :--- | :--- |
| **SI-2** | Flaw Remediation | Monthly Golden Image rebuild patches Windows. Kubernetes node AMIs updated via managed node group rolling updates. | `docs/windows-lifecycle.md` |
| **SI-3** | Malicious Code Protection | EDR/AV installed on Golden Image, present on every WorkSpace post-rebuild. Container images scanned before promotion. | `docs/windows-lifecycle.md` |
| **SI-4** | System Monitoring | CloudWatch, EKS audit logs, and Kafka metrics forwarded to centralized observability stack. Alerts configured for anomalous activity. | `k8s-manifests/03-observability/` |
| **SI-7** | Software, Firmware, and Information Integrity | Containers sourced from Iron Bank or approved hardened registries. Image digests pinned in manifests — no floating `latest` tags. | `k8s-manifests/` |

---

## CA — Assessment, Authorization, and Monitoring

| Control | Title | How We Meet It | Evidence |
| :--- | :--- | :--- | :--- |
| **CA-2** | Control Assessments | This document. Reviewed and updated at each ATO renewal or significant change. | This file |
| **CA-5** | Plan of Action and Milestones | POA&M maintained as a living document. Open findings tracked with remediation dates. | POA&M (separate document, provided to ISSO) |
| **CA-7** | Continuous Monitoring | CloudWatch dashboards, EKS metrics, and Kafka consumer lag monitoring provide continuous visibility. Alerts route to on-call. | `k8s-manifests/03-observability/` |
| **CA-9** | Internal System Connections | Transit Gateway connections between enclaves documented and authorized. All connections defined in Terraform. | `terraform/01-network/` |

---

## FedRAMP Inheritance

Because this platform runs on AWS GovCloud, a significant portion of physical and infrastructure controls are **inherited from AWS's FedRAMP authorization**. This is documented in the SSP as "inherited controls."

Key inherited control families: **PE (Physical & Environmental), MP (Media Protection), PS (Personnel Security)**

> When the auditor asks about physical security of the servers, the answer is: *"Inherited from AWS FedRAMP P-ATO. See the AWS Customer Responsibility Matrix."* Hand them the document. Watch them nod. Go to happy hour.

---

## Glossary Quick Reference

| Term | Plain English |
| :--- | :--- |
| **ATO** | The approval that lets your system touch government data |
| **ISSO** | The person at the agency who watches over your ATO |
| **SCA** | The person who grades your security homework |
| **POA&M** | The "I'll fix it later" list — required when you have open findings |
| **SSP** | The 200-page document describing your entire system |
| **IRSA** | AWS IAM Roles for Service Accounts — how Kubernetes pods get AWS permissions without hardcoded keys |

> Cross-reference with `docs/i-dont-speak-cyber.md` for a fuller glossary.
