# openshift-okd-hive-multicluster-platform

> **Multi-Cluster Lifecycle Management on OKD** — Provisioning and GitOps-driven Day-2 operations using OpenShift Hive, ArgoCD, and HashiCorp Vault on a homelab OKD SNO management cluster.

[![OKD](https://img.shields.io/badge/OKD-4.15-red)](https://okd.io)
[![Hive](https://img.shields.io/badge/Hive-v1-blue)](https://github.com/openshift/hive)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-Community-green)](https://argo-cd.readthedocs.io)
[![Vault](https://img.shields.io/badge/Vault-0.28.0-yellow)](https://www.vaultproject.io)
[![License](https://img.shields.io/badge/License-Apache%202.0-lightgrey)](LICENSE)

---

## 📐 Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│              MANAGEMENT CLUSTER — OKD SNO (homelab)         │
│                                                             │
│  ┌───────────┐  ┌───────────┐  ┌──────────┐  ┌─────────┐  │
│  │  ArgoCD   │  │   Hive    │  │  Vault   │  │Keycloak │  │
│  │ Community │  │ Operator  │  │  Helm    │  │  OIDC   │  │
│  └─────┬─────┘  └─────┬─────┘  └──────────┘  └─────────┘  │
│        │              │                                     │
│        │ GitOps       │ ClusterDeployment / ClusterPool     │
└────────┼──────────────┼─────────────────────────────────────┘
         │              │
         │              │ OpenShift Installer (IPI)
         ▼              ▼
┌──────────────────────────────────────────────────┐
│          TARGET CLUSTERS — Azure / AWS           │
│                                                  │
│  ┌────────────────┐    ┌────────────────┐        │
│  │  OKD Cluster A │    │  OKD Cluster B │  ...   │
│  │  (full stack)  │    │  (full stack)  │        │
│  │  masters+workers    │  masters+workers        │
│  └────────────────┘    └────────────────┘        │
│                                                  │
│  ◄── SyncSets (Kyverno, RBAC, NetworkPolicies) ──►
└──────────────────────────────────────────────────┘
```

### Key Design Decisions

- **Management cluster reuse** — OKD SNO homelab already running ArgoCD + Vault + Keycloak (phases 2a/2b from `Openshift-OKD-SNO-Airgap-workstation`)
- **Hive overhead is minimal** — ~600MB–1GB on management cluster (6 pods), all provisioning workloads run on cloud VMs
- **GitOps-first** — Hive operator and all ClusterDeployments managed via ArgoCD Applications
- **Vault for secrets** — AWS/Azure credentials stored in Vault, injected via Agent Sidecar into Hive provisioner pods
- **Full cluster autonomy** — target clusters are independent OKD installs; management cluster outage does not affect them

### Hive vs HyperShift (companion project)

| | **This project (Hive)** | [okd-hypershift-security-platform](https://github.com/Z3ROX-lab/okd-hypershift-security-platform) |
|---|---|---|
| Target cluster | Autonomous, full OKD stack | Hosted Control Plane (pods) |
| Cloud cost | Higher (masters + workers) | Lower (workers only) |
| Survives mgmt outage | ✅ Yes | ❌ No |
| Use case | Enterprise lifecycle management | Dev/test, multi-tenancy density |
| Provisioning time | ~30–45 min (IPI) | ~5 min |

---

## 🗺️ Project Phases

| Phase | Description | Status |
|-------|-------------|--------|
| **Phase 1** | Hive operator deployment via ArgoCD on OKD SNO | 🔜 Planned |
| **Phase 2** | ClusterPool on Azure/AWS — ClusterClaim lifecycle | 🔜 Planned |
| **Phase 3** | Day-2 via SyncSets — Kyverno policies + RBAC | 🔜 Planned |
| **Phase 4** | ArgoCD ApplicationSet with cluster generator | 🔜 Planned |
| **Phase 5** | Vault integration — cloud credentials + PKI | 🔜 Planned |

---

## 🏗️ Repository Structure

```
openshift-okd-hive-multicluster-platform/
│
├── README.md
├── ARCHITECTURE.md
├── SECURITY.md
│
├── argocd/
│   └── applications/
│       ├── hive.yaml                    # Hive operator Application
│       └── clusterpools.yaml            # ClusterPool Application
│
├── manifests/
│   ├── hive/
│   │   ├── 01-namespace.yaml
│   │   ├── 02-hiveconfig.yaml
│   │   └── values.yaml
│   ├── clusterpools/
│   │   ├── azure-pool.yaml              # ClusterPool Azure
│   │   ├── aws-pool.yaml                # ClusterPool AWS
│   │   └── cluster-imageset.yaml        # OKD 4.15 release image
│   ├── clusterdeployments/
│   │   └── example-deployment.yaml
│   └── syncsets/
│       ├── kyverno-policies.yaml        # Day-2 policies poussées sur les clusters
│       ├── rbac-baseline.yaml
│       └── networkpolicies.yaml
│
├── applicationsets/
│   └── multicluster-apps.yaml           # ArgoCD ApplicationSet + cluster generator
│
├── vault/
│   └── policies/
│       ├── hive-azure-policy.hcl
│       └── hive-aws-policy.hcl
│
├── docs/
│   ├── phase1-hive-bootstrap.md
│   ├── phase2-clusterpool.md
│   ├── phase3-syncsets.md
│   ├── phase4-applicationset.md
│   └── phase5-vault-integration.md
│
└── screenshots/
    └── (portfolio screenshots per phase)
```

---

## 🔧 Prerequisites

| Component | Version | Notes |
|---|---|---|
| OKD SNO | 4.15 | Management cluster (homelab) |
| ArgoCD Community Operator | v0.17.0 | Already deployed |
| HashiCorp Vault | 0.28.0 | Already deployed (dev mode) |
| Hive Operator | v1.x | Deployed in Phase 1 |
| Azure subscription | - | Spot VMs Standard_D4s_v3 |
| OC CLI | 4.15 | `oc` and `kubectl` |

---

## 🔐 Security Highlights

- **Zero hardcoded credentials** — all cloud secrets managed by Vault
- **Kyverno SyncSets** — baseline policies (privileged pod deny, image registry restriction) pushed to all provisioned clusters
- **RBAC SyncSets** — least-privilege ClusterRoles synced automatically
- **Supply chain** — OKD release images verified via `ClusterImageSet` with pinned digests
- **Network isolation** — provisioned clusters use dedicated VNets/VPCs with restricted ingress

---

## 📚 Related Projects

- [`Openshift-OKD-SNO-Airgap-workstation`](https://github.com/Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation) — Management cluster base (ArgoCD + Vault + Keycloak)
- [`okd-hypershift-security-platform`](https://github.com/Z3ROX-lab/okd-hypershift-security-platform) — HyperShift Hosted Control Planes (companion project)
- [`ai-security-platform`](https://github.com/Z3ROX-lab/ai-security-platform) — AI Security Platform on K3d

---

## 👤 Author

**Stéphane Seloi (Z3ROX)** — Cloud Native Security Architect / Platform Security Engineer
- 20+ years in telecom & cloud infrastructure
- CCSP | AWS Solutions Architect | ISO 27001 Lead Implementer
- [GitHub: Z3ROX-lab](https://github.com/Z3ROX-lab)

---

*This project is part of a portfolio demonstrating enterprise-grade multi-cluster management capabilities for freelance Cloud Native Security Architect missions (750–850€/day).*
