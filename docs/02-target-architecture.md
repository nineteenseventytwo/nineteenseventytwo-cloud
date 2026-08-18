# Target Architecture
_Last updated: August 2026 — living document_

---

## Goal

A segmented, hybrid home+cloud platform that:

- Exposes selected services publicly and privately with identity-aware access control
- Extends an on-prem Kubernetes control plane with cloud worker nodes without paying for a managed control plane
- Connects on-prem and cloud securely via a dial-out tunnel — no inbound ports at the perimeter
- Implements security as infrastructure: TLS everywhere, no long-lived credentials anywhere, posture scanning, runtime detection
- Serves as a practical training ground mirroring cloud security engineering work (AWS-heavy, multi-cloud, hybrid, agentic workflows)

---

## Network — ✅ DELIVERED

The target network described in earlier revisions of this document is now the live network. See `01-current-state-inventory.md` for the as-built.

```
Internet → Nokia ONT (bridge) → OPNsense (N100) → GS308E (802.1Q) → VLAN 10/20/30/40
                                                                  → Deco X55 (AP mode, VLAN 10)
```

VLAN 10 Trusted · 20 Lab/K8s · 30 IoT · 40 DMZ. Default-deny between VLANs, explicit allows only.

**Remaining network targets:**

| Item | Purpose | Trigger |
|---|---|---|
| Squid egress proxy on OPNsense | Outbound allowlist for VLAN 20 — the classic corporate forward proxy | Before the cluster starts pulling images unattended |
| Omada EAP with SSID→VLAN tagging | Tagged IoT SSID | Arrival of a genuinely untrusted Wi-Fi device |
| UPS 600–800 VA | Graceful shutdown, availability practice | Before Longhorn holds anything you'd miss |
| Expansion switch | GS308E has no spare ports once DMZ is populated | DMZ / dedicated AP needs a port |

### Proxy types in the target estate

| Type | Direction | Tool | Cloud analogue |
|---|---|---|---|
| Reverse proxy | Inbound to services | ingress-nginx + cert-manager | ALB / API Gateway |
| Forward (egress) proxy | Outbound from VLAN 20 | Squid on OPNsense | NAT GW + Network Firewall |
| Tunnel / ZTNA | Dial-out | Cloudflare Tunnel + Access | PrivateLink + IAM, IAP |
| Site-to-site | On-prem ↔ cloud | Tailscale subnet router (WireGuard as the follow-up rep) | Site-to-Site VPN |

---

## Identity model — the spine of everything

**Principle: no credential in the estate lives longer than an hour, and no IAM user or access key exists at all.**

| Principal | Credential source | Lifetime |
|---|---|---|
| Mark (human) | AWS IAM Identity Center → `aws sso login` | 1h role, 8h session |
| GitHub Actions | GitHub OIDC → `AssumeRoleWithWebIdentity` | per job |
| Cluster pods | Cluster OIDC issuer → `AssumeRoleWithWebIdentity` (IRSA-equivalent) | auto-refreshed |
| Pi / host access | SSH ED25519 keys; Vault SSH CA later | key → short-lived certs |
| Bootstrap secrets | SOPS + age — **deliberately no cloud dependency** | n/a |
| Homelab service SSO | Authentik or Keycloak on `1972-console`, later federated into IdC | session |

Full design, account structure, SCP/RCP baseline and bootstrap order: **`04-aws-landing-zone.md`**.

The layered secrets roadmap remains: SOPS/age → GitHub OIDC → Vault OSS with AWS KMS auto-unseal → Vault SSH CA → cert-manager.

---

## Target Kubernetes architecture

### Control plane stays on-prem

Managed control planes cost ~$73/mo. kubeadm control plane on `1972-master-1`; cloud nodes join as tainted workers over the site-to-site tunnel.

### Node layout

| Node | Location | Role | Workloads |
|---|---|---|---|
| `1972-master-1` | On-prem RPi 5 | Control plane | Control plane only |
| `1972-worker-1` | On-prem RPi 5 | Worker (ARM64) | Platform services: NATS, CouchDB, data API, chat, overlay |
| `1972-worker-2` | On-prem RPi 5 | Worker (ARM64) | Observability: kube-prometheus-stack, Alloy, OpenCost, Kepler |
| `1972-home` | On-prem PC (x86) | Worker (GPU) | Ollama, composer pipeline |
| `cloud-aws-worker-1` | AWS Graviton | Worker (tainted) | Burst jobs, cloud-scheduled workloads |
| `1972-console` | On-prem RPi 4 | **Not a node** | Break-glass bootstrap runner only |

### Cluster decisions locked in

| Area | Decision |
|---|---|
| CNI | **Cilium** (fresh build, no migration risk; enforces NetworkPolicy, eBPF observability) |
| Service mesh | **Deferred.** Cilium's own mTLS/mesh capability if a need emerges; Istio only for a concrete requirement. Linkerd dropped. |
| GitOps | **Argo CD** — cluster state from git, no hand-applied manifests |
| Load balancing | MetalLB (L2), pool in VLAN 20 |
| Storage | Longhorn on worker SSDs; S3 backup target in AWS |
| Ingress / TLS | ingress-nginx + cert-manager, Let's Encrypt DNS-01 via a scoped Cloudflare API token |
| NetworkPolicy | Default-deny in every workload namespace before any workload lands |
| Pod Security | `restricted` on workload namespaces, `baseline` on infra |
| RBAC | Namespaced roles; no workload service account gets cluster-admin |
| etcd | Encryption at rest enabled in the kubeadm config |
| Workload cloud identity | Public OIDC issuer at `oidc.eightbitsaxlounge.com` — **set at `kubeadm init`, cannot be changed cheaply later** |
| Image policy | Trivy scan in CI; Kyverno admission policy later |

---

## Target cloud architecture

### AWS (primary) — five accounts

```
Root ── mgmt ── Security OU ── security
             ── Infrastructure OU ── shared, platform-prod
             ── Sandbox OU ── sandbox
```

| Component | Target |
|---|---|
| Identity | IAM Identity Center (`eu-west-2`); zero IAM users, enforced by SCP |
| Workload identity | GitHub OIDC (CI) + cluster OIDC (pods) |
| Preventative controls | SCPs (root deny, region allowlist, no IAM users, no expensive resources), RCPs (org-principals-only, TLS-only), declarative policies (IMDSv2) |
| Audit | Org CloudTrail → S3 with Object Lock in the security account |
| Detection | GuardDuty (delegated to security). Config + Security Hub **deferred on cost** — Prowler on a schedule instead |
| Encryption | Customer-managed KMS CMKs: Terraform state, SOPS/Argo, Vault auto-unseal |
| Secrets | Vault OSS on-cluster for on-prem workloads; Secrets Manager only for cloud-native ones |
| Network | VPC public/private; no public IPs on Lab-facing resources; VPC endpoints; NAT Gateway denied by SCP until justified |
| Hybrid link | Tailscale subnet router VLAN 20 ↔ private subnet; WireGuard self-managed as the follow-up |
| IaC | Terraform in `nineteenseventytwo-cloud`, applied by GitHub-hosted runners via OIDC |
| IaC scanning | Checkov + tflint on every PR |

### GCP (secondary) — deferred

Recreate the identity + encryption + private networking slice once AWS is fully IaC-managed. Same repo, separate `live/gcp/` tree, same Terraform binary. **Do not build cross-cloud abstraction modules** — the concepts map, the resources don't.

| Concept | AWS | GCP |
|---|---|---|
| Human SSO | IAM Identity Center | Cloud Identity + IAM |
| Workload identity | OIDC + AssumeRole | Workload Identity Federation |
| Keys | KMS | Cloud KMS |
| Secrets | Secrets Manager | Secret Manager |
| Private API access | VPC Endpoints | Private Service Connect |
| Org guardrails | SCPs / RCPs | Org Policies |
| Posture | Prowler (+ Security Hub) | Prowler (+ SCC) |

---

## Target security stack (OSS CNAPP)

Mapped to Wiz pillars, for the interview narrative.

| Pillar | Tool | Where |
|---|---|---|
| CSPM | **Prowler** | Scheduled CronJob or GH Action against AWS (+GCP); results to Grafana |
| IaC scanning | **Checkov** + tflint | CI on every PR to `-cloud` and `-platform` |
| Vulnerability + secret scanning | **Trivy** | CI, before push to ghcr.io; fails on criticals |
| KSPM | **Kubescape** | Against CIS/NSA benchmarks — run once while the cluster is still empty, then scheduled |
| Runtime / CWPP | **Falco** | DaemonSet → NATS → Grafana alerts |
| Asset graph | **Steampipe** | Ad-hoc SQL over cloud config |
| Admission control | **Kyverno** | Block unsigned/unscanned images |

---

## Public / private web presence

| | Public | Private |
|---|---|---|
| Content | Project showcase, gigs feed, reading list | Grafana, cluster status, infra ops |
| Stack | Astro or Hugo, static | Existing cluster services |
| Hosting | Cloudflare Pages | On-cluster |
| Path | Cloudflare Pages / Tunnel | Browser → Cloudflare Access (OTP/SSO) → Tunnel → service |
| Inbound ports | Zero | Zero |

---

## Hybrid connectivity

```
VLAN 20 (Lab)
   ├── Tailscale subnet router ──→ AWS VPC private subnet ──→ cloud-aws-worker-1
   └── cloudflared (Deployment) ──→ Cloudflare edge ──→ public internet (selected services)

Cluster pods ──(projected SA token, aud=sts.amazonaws.com)──→ AWS STS ──→ short-lived creds
```

The control plane reaches cloud workers over the tunnel. Cloud workers have no public IPs. Cloudflare Tunnel handles public exposure separately from the private site-to-site link. Pod → AWS API access goes over normal egress using federated tokens, not over the tunnel.

---

## Resolved decisions

| Decision | Outcome |
|---|---|
| Firewall hardware | N100 mini-PC + OPNsense ✅ done |
| ONT mode | Bridge ✅ done — double NAT eliminated |
| PC dual-boot | Stays; wired port is plain VLAN 20, Trusted access via Wi-Fi ✅ |
| CNI | Cilium, fresh install ✅ |
| Service mesh | Deferred until a concrete need; Linkerd dropped |
| Secrets bootstrap | SOPS + age, not ansible-vault ✅ |
| Site-to-site tunnel | Tailscale first, WireGuard as the learning rep |
| Secrets backend | Vault OSS on-prem + Secrets Manager for cloud-native |
| GitOps | Argo CD |
| Cloud repo | Separate `nineteenseventytwo-cloud`, multi-cloud-ready layout, one Terraform binary |

## Open decisions

| Decision | Options | Notes |
|---|---|---|
| Cluster OIDC issuer exposure | Public JWKS bucket vs IAM Roles Anywhere | Public issuer is simpler and available now; Roles Anywhere needs Vault first |
| Terraform vs OpenTofu | — | Terraform assumed |
| IdC identity source | Built-in directory vs self-hosted IdP federation | Start built-in; federate to Authentik/Keycloak once the cluster hosts it — disruptive, so do it while small |
| Config / Security Hub | Enable vs Prowler-only | Prowler-only initially on cost; revisit with a documented tradeoff |
| Cloud worker node | Graviton EC2 as tainted worker | Stretch goal; costs money while running |
