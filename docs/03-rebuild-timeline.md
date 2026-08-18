# Homelab Rebuild Timeline — Clean Slate to Secure Hybrid
_6–8 hours/week · security-first, container-first_
_Last updated: August 2026 — Phases 0 and 1 complete; AWS inserted as Phase 2.5_

---

## Ordering principle

```
Pis online (keys only) → Network segmented → CI/CD bootstrap → AWS identity foundation
→ Cluster (hardened + cloud-federated from day 1) → Services (TLS from day 1)
→ Security layers + hybrid (Vault, tunnel, detection)
```

**Why AWS moved earlier than originally planned:** the API server's `service-account-issuer` is fixed at `kubeadm init`. Getting cluster→AWS federation right means the AWS account and its OIDC provider must exist before the cluster is built, not after. Doing it later means rebuilding the control plane or living with stored access keys — the exact thing this whole design is meant to avoid.

Key decisions locked in:
- **OS:** Ubuntu Server 24.04 LTS on all Pis
- **CNI:** Cilium
- **GitOps:** Argo CD
- **Secrets:** SOPS + age now → Vault OSS on-cluster in Phase 5
- **Cloud identity:** zero IAM users, zero access keys — SSO for humans, OIDC for CI and pods
- **Certificates:** cert-manager + Let's Encrypt DNS-01 via Cloudflare
- **Load balancing:** MetalLB L2; public exposure via Cloudflare Tunnel
- **Wi-Fi:** Deco in AP mode; OPNsense↔switch trunk is wired, never over mesh backhaul

---

## Phase 0 — Accounts, domain, imaging ✅ COMPLETE

- [x] Domain registered: `eightbitsaxlounge.com` (Cloudflare Registrar) + free Cloudflare account
- [x] G.Network bridge mode scheduled and activated
- [x] All Pis imaged with Ubuntu 24.04 LTS, key-only SSH, password auth disabled
- [x] SSH verified from macOS and Windows
- [ ] AWS account hygiene — **moved to Phase 2.5** (was never started; now done properly rather than ad hoc)
- [ ] `1972-console` still on SD card — SSD (WD Blue SA510 250 GB) outstanding

**Learnings captured:** cloud-init `user-data` and `network-config` must sit at the root of the `system-boot` FAT32 partition, replacing the stock files — not in a subfolder. Inside a running Pi that partition is `/boot/firmware`; from Windows it's the volume root. Verify rendered files are in place before first boot or the stock defaults silently leave users and keys unprovisioned.

---

## Phase 1 — Network re-architecture ✅ COMPLETE

- [x] OPNsense on the N100; Unbound DNS, Kea DHCP, admin UI locked to Trusted
- [x] Nokia ONT → bridge mode; OPNsense holds the public IP; household internet verified
- [x] GS308E 802.1Q: trunk to OPNsense, VLAN 10 to Deco, VLAN 20 access ports for Pis and PC
- [x] OPNsense VLAN 10/20/30/40 interfaces with per-VLAN DHCP
- [x] Pis and PC moved to VLAN 20, static leases in Kea
- [x] Deco → AP mode on VLAN 10
- [x] Default-deny between VLANs with explicit allows
- [ ] Red-team pass documented? — **confirm**
- [ ] GS308E management IP moved to 192.168.10.100 — **confirm**

**Learnings captured (firewall):**
- Rules go on the **source** interface tab, not the destination
- Default-deny rules should be direction **"in" only** — an outbound deny on a VLAN interface intercepts cross-VLAN routed traffic even when the source rules are right
- The "WAN network" alias means the ISP's directly-attached subnet, *not* the internet — never use it as a destination for internet-access rules
- Protocol defaults to TCP; set it to "any" or ICMP and UDP are silently dropped
- "Allow Trusted to any" bypasses segmentation — put an `Internal_Networks` deny above the allow-any rule
- VLAN 1 must keep the management ports as untagged members on the GS308E or the switch loses its own management connectivity

**Deferred out of Phase 1:** Squid egress proxy (Phase 2.5/3), Omada EAP (trigger-based), UPS.

---

## Phase 2 — CI/CD bootstrap, container-first 🔄 IN PROGRESS

**Goal: a pipeline that can build images and run Ansible against the fleet, before the cluster exists.**

- [x] GitHub org `nineteenseventytwo` created (prerequisite for org-level runners and ARC scale sets)
- [x] Platform repo `nineteenseventytwo-platform` with Makefile render system, cloud-init templates
- [x] SOPS + age chosen over ansible-vault (per-value encryption, multi-recipient)
- [x] Docker on `1972-console-1` (renamed from `1972-console` during provisioning)
- [x] Ephemeral, containerised, **org-scoped** GHA runner live end-to-end
- [x] Two-image split: `ansible-runner` (playbooks + collections baked in) and thin `gha-runner`
- [x] End-to-end verified: push to main → containerised runner → containerised Ansible → Pi reconfigured
- [ ] Codify the Phase 0 hardening as the first real playbook and run it through the pipeline
- [ ] **Make `nineteenseventytwo-eightbitsaxlounge` private** — fork-PR RCE risk against self-hosted runners. Oldest outstanding security action.
- [ ] AWS OIDC federation for Actions — **moved to Phase 2.5** (needs the account to exist)

**Deliverable:** ✅ push-to-main configures a Pi via containerised runner + containerised Ansible — achieved.
**Later migration:** runners move in-cluster via ARC once the cluster is healthy; `1972-console-1`'s runner stays as the break-glass bootstrap path.

---

## Phase 2.5 — AWS landing zone & identity ⏭ NEXT (~5 sessions, 20h)

**Goal: an AWS organization where no credential lives longer than an hour, ready for the cluster to federate into.**

Full detail in **`04-aws-landing-zone.md`**. Summary:

| Session | Work |
|---|---|
| 1 | Cloudflare email aliases; management account + root MFA + alternate contacts; budgets ($5/$10/$20) and Cost Anomaly Detection; Organization with all features; SCP/RCP/declarative policy types enabled; centralized root access management |
| 2 | Four member accounts + OUs (security, shared, platform-prod, sandbox); IAM Identity Center in `eu-west-2`; break-glass permission set; `aws configure sso` working; root sign-in alarm; **stop using root** |
| 3 | `nineteenseventytwo-cloud` repo created; `bootstrap/aws` applied locally: state bucket + KMS CMK + native S3 locking, GitHub OIDC providers, `gha-tf-plan` / `gha-tf-apply` roles; state migrated |
| 4 | SCPs and RCPs via CI, rolled out sandbox → OU → root; org CloudTrail → S3 Object Lock in the security account |
| 5 | GuardDuty + Access Analyzer (delegated to security); KMS CMKs; S3 buckets; the public JWKS bucket and `oidc.eightbitsaxlounge.com` DNS record, ready and empty |

**Constraints that make this Phase 2.5 rather than Phase 6:**
- IAM Identity Center's region is a one-way door
- The cluster OIDC provider must exist before the first IRSA role is useful
- Every day without it is a day something acquires an access key "temporarily"

**Deliverable:** SSO login working, CI applying Terraform with no stored secrets, SCPs enforcing no-IAM-users, and a decision record per SCP naming the threat it mitigates.

**Also do here (network):** Squid egress proxy on OPNsense with the VLAN 20 allowlist, before the cluster starts pulling images unattended.

---

## Phase 3 — Cluster build, hardened and federated from commit one (~24h)

- [ ] kubeadm init on `1972-master-1`, join worker-1/worker-2 — driven by Ansible through the pipeline, not by hand
- [ ] **`service-account-issuer` = `https://oidc.eightbitsaxlounge.com`, `api-audiences` includes `sts.amazonaws.com`** — set at init, cannot be changed cheaply later
- [ ] Publish `/.well-known/openid-configuration` and `/openid/v1/jwks` to the public bucket; register the IAM OIDC provider; prove one pod assuming one role
- [ ] **Cilium** as CNI
- [ ] Before any workload: default-deny NetworkPolicy per namespace, Pod Security Standards (`restricted` / `baseline`), namespaced RBAC, etcd encryption at rest
- [ ] MetalLB (L2) with a VLAN 20 pool
- [ ] Longhorn on the worker SSDs; test a PVC and a restore — backup target S3 in `platform-prod`, via the cluster OIDC role
- [ ] Argo CD; everything from here is GitOps
- [ ] Kubescape scan against the CIS baseline while the cluster is still empty

**Deliverable:** empty but hardened cluster, with a pod holding AWS credentials it was never given. Kubescape before/after as the artifact.

---

## Phase 4 — Services return, HTTPS-only (~24h)

- [ ] ingress-nginx + cert-manager; certs via Let's Encrypt DNS-01, Cloudflare API token scoped to DNS edit only
- [ ] Internal DNS: Unbound overrides pointing `*.lab.eightbitsaxlounge.com` at MetalLB VIPs
- [ ] Redeploy via Argo CD in dependency order, each with its NetworkPolicy allow-pair: NATS JetStream → CouchDB → Data API → chat bot → overlay
- [ ] Kill every plain-HTTP path; services updated for ingress hostnames
- [ ] kube-prometheus-stack, Longhorn-backed; re-add Alloy / OpenCost / Kepler
- [ ] Trivy image scan in CI before push to ghcr.io — pipeline fails on criticals
- [ ] SOPS switched to KMS for in-cluster secrets, decrypted by Argo CD via its OIDC role (age stays for bootstrap)

**Deliverable:** platform back, browser-trusted TLS everywhere, scan gate in CI, no secrets in manifests.

---

## Phase 5 — Security layers + hybrid + public site (~30h)

- [ ] Vault OSS on cluster (Longhorn-backed, Raft), **auto-unseal via KMS CMK using the cluster OIDC role**; migrate workload secrets; Vault Agent injector or CSI driver
- [ ] Vault SSH CA replacing static SSH keys for Pi access
- [ ] cloudflared as a Deployment; Cloudflare Tunnel for the public site; Cloudflare Access in front of Grafana. No inbound ports, ever
- [ ] Public site: Astro/Hugo → Cloudflare Pages
- [ ] Tailscale subnet router bridging VLAN 20 ↔ AWS VPC private subnet; test both directions
- [ ] Terraform VPC in `platform-prod` (no public IPs, VPC endpoints, NAT denied by SCP unless justified)
- [ ] Falco DaemonSet → NATS → Grafana
- [ ] Prowler scheduled against AWS; Checkov already gating Terraform PRs
- [ ] One deliberate misconfiguration drill; write the postmortem
- [ ] Cost review: what stays running, what it costs

**Deliverable:** publicly reachable site, privately reachable dashboards, hybrid tunnel, runtime detection.

---

## Phase 6 — Stretch

- [ ] Graviton EC2 joined as a tainted cloud worker over the tunnel
- [ ] Self-hosted IdP (Authentik or Keycloak) on `1972-console` as homelab SSO; federate into IAM Identity Center
- [ ] WireGuard replacing Tailscale as a self-managed learning rep
- [ ] GCP mirror: identity + KMS + private networking slice in `live/gcp/`
- [ ] `1972-home` Linux side joined as a GPU worker; Ollama and the composer pipeline

---

## Decisions log

| Question | Decision | Why |
|---|---|---|
| Ubuntu version | 24.04 LTS | Supported to 2029 |
| Vault at bootstrap? | No — SOPS/age first, Vault on-cluster in Phase 5 | Vault can't secure the cluster it runs on before that cluster exists |
| ansible-vault vs SOPS | SOPS + age | Per-value encryption, multi-recipient, readable diffs |
| Switch behind Deco satellite? | No — trunk must be wired | VLAN tags don't survive mesh backhaul |
| PC wired port: trunk or access? | Plain VLAN 20 access | Primary use is midi-api → cluster ingress; Wi-Fi covers Trusted; removes a cross-VLAN rule |
| CNI | Cilium, fresh install | Flannel doesn't enforce NetworkPolicy; migration later would be risky |
| Service mesh | Deferred | No concrete need yet; Cilium may cover it |
| GitOps | Argo CD | Cluster state in git; complements the Ansible-for-hosts split |
| **AWS before or after the cluster?** | **Before** | `service-account-issuer` is set at `kubeadm init`; retrofitting means rebuilding the control plane or storing access keys |
| **Cloud repo** | Separate `nineteenseventytwo-cloud` | IaC blast radius separate from platform; multi-cloud-ready; different runner requirements |
| **Cloud CI runners** | GitHub-hosted, not self-hosted | A self-hosted runner with an org-modifying OIDC role is too large a blast radius, and cloud IaC shouldn't depend on homelab uptime |
| **Config / Security Hub** | Deferred; Prowler instead | Per-config-item and per-resource billing on a homelab; Prowler covers CIS for free |
| **Control Tower** | No — plain Organizations + Terraform | Cheaper, more legible, and the mechanics are the point |
| Domain | Cloudflare Registrar | Tunnel, Access, DNS-01, public site, and now the OIDC issuer host |

---

## Standing risks

- **`eightbitsaxlounge` repo is still public** with self-hosted runners in play — fork-PR RCE. Highest-severity open item.
- **`1972-console` on an SD card with 1 GB RAM** — reliability risk under CI load; SSD purchase outstanding; don't let services creep onto it
- **Public OIDC issuer** puts a Cloudflare/S3 dependency in the path of the cluster's AWS access (not in the path of the cluster itself). Accepted; IAM Roles Anywhere is the fallback
- **IAM Identity Center region is a one-way door** — get `eu-west-2` right first time
- **AWS cost creep** — budgets and the `DenyExpensiveResources` SCP are the controls; review monthly
- **GS308E has no spare ports** once DMZ or a dedicated AP wants one
- **No UPS** — Longhorn shouldn't hold anything irreplaceable until there is one
