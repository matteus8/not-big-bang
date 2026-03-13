# I DON'T SPEAK CYBER
### *The "Bare Minimum" Glossary for quarterly meetings.*

In GovCon, Cyber people love acronyms more than they love security. 
You don't have time to read a 500-page NIST manual. 
Here is the "down and dirty" translation guide so you can sound like an expert in 5 minutes.

---

### 1. The Big Ones (The "Permits")
- **ATO (Authority to Operate):** The "Golden Ticket." It’s the formal approval that says your system is secure enough to touch government data. Without this, your code is just an expensive hobby.
- **cATO (Continuous ATO):** The holy grail. Instead of doing a massive audit every 3 years, you prove that your platform (this repo!) is so automated and hardened that you are *always* compliant. 
- **FedRAMP:** A government-wide program that provides a standardized approach to security assessment for cloud products. Since we use AWS, we **inherit** their FedRAMP status, which saves us 80% of the paperwork.

---

### 2. The Rulebooks (The "Laws")
- **NIST SP 800-53:** The "big cyber manifesto." It’s a giant list of security controls (rules). If a Cyber person asks, *"How are you meeting AC-2?"*, they are talking about a specific rule in this book. 
    > *Pro-Tip: Our `ato-mappings.md` file maps our code directly to these rules.*
- **NIST SP 800-171:** This is the junior version of 800-53, usually applied to your company's internal office network (where Bob in Tampa works).
- **SRG / STIG (Security Technical Implementation Guide):** This is the "Technical Checklist." There is a STIG for Windows, a STIG for Kubernetes, and a STIG for Kafka. If you haven't "STIG'd your box," it's not ready for the mission.

---

### 3. The Paperwork (The "Boring Stuff")
- **SSP (System Security Plan):** The "Big Book of How." It’s a 200+ page document describing every single thing about your system. 
    > *Platform Note: Since we use flat files and simple Terraform, the LLM can actually help you write this.*
- **POA&M (Plan of Action and Milestones):** The "I'll Fix It Later" list. When an auditor finds a bug you can't fix today, you put it on a POA&M with a date. As long as you have a POA&M, the auditor usually stays happy.
- **SCA (Security Control Assessor):** The person who actually grades your homework. Treat them well.

---

### 4. The Tiers (The "Fences")
In the DoD world, not all clouds are equal. We call these **Impact Levels (IL)**:
- **IL2:** Public information. Low security.
- **IL4:** Controlled Unclassified Information (CUI). Think: sensitive but not secret.
- **IL5:** Higher-tier CUI. Usually requires a dedicated, isolated cloud environment.
- **IL6:** **SECRET** data. This is where the **Air-Gap/Zarf** stuff in our repo becomes mandatory.

---

### 5. Data & Identity (The "Keys")
- **CUI (Controlled Unclassified Information):** This is the data Bob is actually working on. It’s not "Classified," but if you lose it, you’re still in big trouble.
- **CAC/PIV:** The physical smart cards everyone uses to log in. Our **Keycloak** setup is designed to eventually talk to these.
- **Zero Trust:** A buzzword that just means "Don't trust anyone, even if they are inside the network." Our **"2fa with CAC/PIC Auth in Keycloak"** is a core part of a Zero Trust strategy.

---

## 🎤 How to use this in a meeting:

**The Cyber Person says:** *"We are worried about data-in-transit on your kubernets cluster and want to know how your VM's are being patched/stig'd."*

**You (The Hero) say:** *"We’ve addressed both of those. Our cluster uses istio service mesh to encrpty pod-to-pod traffic, we’ve also moved away from mutable VMs and are using a **Golden Image rebuild** strategy. Also, all the data-in-transit for the ETL pipeline is forced through **Strimzi mTLS**, satisfying **SC-8**."*

**The Result:** The Cyber person nods, feels impressed, and stops asking you questions for at least another month. **Go to happy hour.**