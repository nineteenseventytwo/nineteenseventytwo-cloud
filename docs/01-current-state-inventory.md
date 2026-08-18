# Current State Inventory
_Last updated: August 2026 — rewritten after the network rebuild_

> **What changed since June:** the flat `192.168.68.0/24` LAN is gone. OPNsense is the perimeter, the ISP ONT is bridged, four VLANs are live, and all Pis are provisioned from cloud-init with key-only SSH. The old inventory described the pre-rebuild estate; this describes what actually exists now.

---

## Network — REBUILT ✅

### Topology (live)

```
Internet
   │
Nokia XS-2426G-A (ONT — BRIDGE MODE, confirmed with G.Network)
   │  IPoE, VLAN tag 1001 on WAN
OPNsense (N100 mini PC, Intel i226-V NICs) — public IP, no double NAT
   │  802.1Q trunk (wired)
Netgear GS308E
   ├── port 1  trunk → OPNsense
   ├── port 2  untagged VLAN 10 → Deco X55 (AP mode)
   ├── port 3  untagged VLAN 20 → PC (plain access, not trunk)
   └── ports 5–8  untagged VLAN 20 → Pis
Deco X55 (AP mode) → Trusted Wi-Fi on VLAN 10
```

### VLANs

| VLAN | Name | Subnet | Members | Policy |
|---|---|---|---|---|
| 10 | Trusted | 192.168.10.0/24 | Workstations, Deco Wi-Fi clients | Internet; SSH/mgmt into Lab; denied to IoT |
| 20 | Lab / K8s | 192.168.20.0/24 | All Pis, PC wired | Internet (egress proxy planned); denied to Trusted |
| 30 | IoT | 192.168.30.0/24 | Smart home, guest Wi-Fi | Internet only, isolated |
| 40 | DMZ | 192.168.40.0/24 | Cloudflare Tunnel endpoint (not yet populated) | Internet-facing; denied inbound to Lab |

### Services on OPNsense

| Service | State |
|---|---|
| Kea DHCP | Active, per-VLAN scopes, static leases for all Pis |
| Unbound DNS | Active |
| Dnsmasq | Explicitly disabled |
| Squid egress proxy | **Planned** — VLAN 20 outbound allowlist (PyPI, GitHub, ghcr.io, Docker Hub) |

### Open network items

- [ ] GS308E management IP moved to `192.168.10.100` — **confirm done?**
- [ ] Squid egress proxy for VLAN 20 (once active, general browsing from the PC must go over Trusted Wi-Fi)
- [ ] VLAN-aware Wi-Fi (Omada EAP) — deferred until a genuinely untrusted Wi-Fi device arrives; Deco guest isolation covers VLAN 30 in the interim
- [ ] UPS, 600–800 VA with USB signalling — not yet purchased
- [ ] No spare GS308E ports once DMZ wants one — expansion switch may be needed

---

## Compute

### Raspberry Pi nodes — PROVISIONED ✅

| Hostname | Role | Model | RAM | Boot | VLAN 20 IP |
|---|---|---|---|---|---|
| `1972-console-1` | Break-glass / bootstrap CI | RPi 4 | 1 GB | SD card (SSD pending) | 192.168.20.201 |
| `1972-master-1` | K8s control plane (pending) | RPi 5 | 2 GB | External 250 GB SSD | 192.168.20.202 |
| `1972-worker-1` | K8s worker (pending) | RPi 5 | 2 GB | External 250 GB SSD | 192.168.20.203 |
| `1972-worker-2` | K8s worker (pending) | RPi 5 | 2 GB | External 250 GB SSD | 192.168.20.204 |

> Note: `1972-console` was renamed `1972-console-1` during provisioning.

**OS:** Ubuntu Server 24.04 LTS on all Pis.
**Provisioning:** cloud-init, rendered from templates in the platform repo via `make bootstrap-render`, files written to the `system-boot` FAT32 partition root.
**Access:** key-only SSH (`mark-workstation`, ED25519). Verified working from macOS and Windows on VLAN 10, and console → cluster nodes on VLAN 20. Password auth disabled.
**Hardening:** applied _(confirm which — unattended-upgrades, ufw, fail2ban?)_.

- [ ] SSD for `1972-console` — WD Blue SA510 250 GB identified; SD card is a reliability risk while it remains
- [ ] `1972-console` has 1 GB RAM: runner host only, nothing else creeps onto it

### PC node (`1972-home`)

| Attribute | Value |
|---|---|
| IP | VLAN 20, wired access port 3 _(confirm address)_ |
| CPU / RAM / GPU | Ryzen 5 5600X · 32 GB · RTX 4060 8 GB |
| Storage | 2× 1 TB NVMe — Windows / Linux |
| OS | Windows primary; Ubuntu installed, not configured |

Runs `midi-api` as a Windows service (MIDI hardware access keeps it Windows-native). Reaches the cluster via ingress on VLAN 20 — the reason its wired port is plain VLAN 20 rather than a trunk. Trusted-network access comes over Wi-Fi. Not yet a Kubernetes node; GPU reserved for Ollama later.

---

## Kubernetes — NOT YET BUILT

The old cluster is gone with the old network. Nothing is running. Next phase, but **AWS lands first** (see `04-aws-landing-zone.md` §"Why this comes before the cluster").

Locked-in decisions for the rebuild: kubeadm, Cilium CNI, MetalLB L2 with a VLAN 20 pool, Longhorn on worker SSDs, ingress-nginx + cert-manager, default-deny NetworkPolicy and Pod Security Standards from commit one, Argo CD for GitOps.

**Undecided / to set at init:** `service-account-issuer` for AWS federation — must be chosen before `kubeadm init`.

---

## CI/CD — IN PROGRESS

| Component | State |
|---|---|
| GitHub org `nineteenseventytwo` | Created ✅ (was the blocker for org-level runners and ARC scale sets) |
| Platform repo | `nineteenseventytwo-platform`, `init` branch — Makefile-driven, cloud-init templates, SOPS |
| Runner architecture | Ephemeral GHA runners; two images: `ansible-runner` + thin `gha-runner` |
| Runner live on `1972-console-1` | ✅ Containerised, org-scoped runner working end-to-end |
| Secrets | SOPS + age (chosen over ansible-vault: per-value encryption, multi-recipient) |
| Ansible | Containerised — nothing installed on hosts |
| Registry | ghcr.io |

- [ ] **`nineteenseventytwo-eightbitsaxlounge` still public** — self-hosted-runner fork-PR RCE risk. Make private, or move it under the org with fork-PR runs disabled. This is the oldest open security action in the project.

---

## Cloud — NOT STARTED

No AWS account exists. No GCP. See `04-aws-landing-zone.md` for the full plan.

Planned repo: `nineteenseventytwo-cloud` (Terraform for AWS now, GCP later).

---

## Domain & DNS

| | |
|---|---|
| Domain | `eightbitsaxlounge.com`, Cloudflare Registrar |
| DNS | Cloudflare authoritative |
| Pattern | One domain, subdomains per service |
| Planned records | `oidc.` (cluster JWKS), `*.lab.` (internal, Unbound override), public site, Tunnel hostnames |
| Email routing | To be enabled — AWS account aliases |

---

## Security posture

| Area | State |
|---|---|
| Network segmentation | ✅ Four VLANs, default-deny between them |
| Perimeter firewall | ✅ OPNsense, bridge mode, no double NAT |
| SSH | ✅ Key-only, ED25519, password auth off |
| Egress control | ⏳ Squid planned |
| Secrets | ✅ SOPS + age for bootstrap; Vault OSS in Phase 5 |
| TLS on internal services | ❌ No services running yet; cert-manager from day one when they return |
| Cloud identity | ❌ Not started — the current work |
| Kubernetes hardening | ❌ Cluster doesn't exist; hardened-from-commit-one is the plan |
| Image scanning | ❌ Trivy gate planned in Phase 4 |
| Runtime detection | ❌ Falco planned in Phase 5 |
| Public exposure | None. No inbound ports. Cloudflare Tunnel is the only planned path. |

---

## Repositories

| Repo | Purpose | State |
|---|---|---|
| `nineteenseventytwo/nineteenseventytwo-platform` | Infrastructure: cloud-init, Ansible, Makefile, SOPS, cluster manifests | Active, `init` branch |
| `nineteenseventytwo/nineteenseventytwo-cloud` | AWS/GCP IaC, IAM, SCPs | **To create** |
| `mchellmer/nineteenseventytwo-eightbitsaxlounge` | Application services | Active — **make private** |
| `mchellmer/nineteenseventytwo-composer` | AI music arrangement pipeline | Scaffolded, dormant |

---

## Open questions

- [ ] Confirm GS308E management IP relocation
- [ ] Confirm which hardening measures are applied to the Pis, and whether they're codified as an Ansible playbook yet or still manual
- [x] Platform repo's AWS requirement identified: a KMS CMK for **Vault auto-unseal** — see `04-aws-landing-zone.md` §7 note on sequencing this ahead of Vault itself
