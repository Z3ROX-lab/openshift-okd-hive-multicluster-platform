# openshift-okd-hive-multicluster-platform

> **Multi-Cluster Lifecycle Management on OKD** — Provisioning and GitOps-driven Day-2 operations using OpenShift Hive, ArgoCD, and HashiCorp Vault on a homelab OKD SNO management cluster.

[![OKD](https://img.shields.io/badge/OKD-4.15-red)](https://okd.io)
[![Hive](https://img.shields.io/badge/Hive-v1-blue)](https://github.com/openshift/hive)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-Community-green)](https://argo-cd.readthedocs.io)
[![Vault](https://img.shields.io/badge/Vault-0.28.0-yellow)](https://www.vaultproject.io)
[![License](https://img.shields.io/badge/License-Apache%202.0-lightgrey)](LICENSE)

---

## 📐 Architecture Overview — Hub and Spoke

Ce projet implémente le pattern **Hub and Spoke** : l'OKD SNO homelab est le **hub** (management cluster), les clusters OKD provisionnés sur Azure sont les **spokes** (workload clusters autonomes).

```
┌─────────────────────────────────────────────────────────────────┐
│                  HUB — OKD SNO (homelab)                        │
│                  sno-master @ 192.168.241.10                    │
│                                                                 │
│  ┌───────────┐  ┌───────────┐  ┌──────────┐  ┌─────────────┐  │
│  │  ArgoCD   │  │   Hive    │  │  Vault   │  │  Keycloak   │  │
│  │ Community │  │ Operator  │  │  v0.28.0 │  │  OIDC SSO   │  │
│  └─────┬─────┘  └─────┬─────┘  └────┬─────┘  └─────────────┘  │
│        │              │             │                           │
│        │ GitOps       │ IPI         │ secrets injection         │
└────────┼──────────────┼─────────────┼───────────────────────────┘
         │              │             │
         │              │ Azure API   │
         │    ┌──────────┴──────┐     │
         │    │                 │     │
         ▼    ▼                 ▼     │
┌──────────────────┐   ┌──────────────────┐
│   SPOKE 1        │   │   SPOKE 2        │
│   OKD Cluster A  │   │   OKD Cluster B  │
│   Azure westeurope│  │   Azure westeurope│
│                  │   │                  │
│   ┌────────────┐ │   │   ┌────────────┐ │
│   │  masters   │ │   │   │  masters   │ │
│   │  (3 VMs)   │ │   │   │  (3 VMs)   │ │
│   ├────────────┤ │   │   ├────────────┤ │
│   │  workers   │ │   │   │  workers   │ │
│   │  (Spot)    │ │   │   │  (Spot)    │ │
│   └────────────┘ │   │   └────────────┘ │
│                  │   │                  │
│  ◄─ SyncSets ──► │   │  ◄─ SyncSets ──► │
│  ◄─ ArgoCD   ──► │   │  ◄─ ArgoCD   ──► │
└──────────────────┘   └──────────────────┘
  Autonome ✅                Autonome ✅
  (survit si hub OFF)        (survit si hub OFF)
```

---

## 🔄 Le pattern Hub and Spoke

Le hub **ne fait tourner aucune application métier**. Son seul rôle est de **gérer les spokes** :

```
HUB (OKD SNO homelab)
│
├── Hive      → crée / détruit / hiberne les clusters spokes
├── ArgoCD    → déploie les apps sur les spokes via ApplicationSet
├── Vault     → distribue les secrets aux spokes
└── Keycloak  → SSO centralisé pour tous les spokes

SPOKE (OKD Azure)
│
├── Reçoit ses configs depuis le HUB (SyncSets, ArgoCD)
├── Tourne tout seul si le HUB s'éteint  ✅
└── Ne connait pas les autres spokes
```

> **Analogie** : le HUB est la tour de contrôle aéroportuaire — elle donne les instructions.
> Les SPOKEs sont les avions — ils volent de façon autonome mais obéissent à la tour.

---

## 🔀 Hive vs HyperShift — deux approches du hub and spoke

*Voir [ADR-001 — Hive vs HyperShift](docs/adr/ADR-001-hive-vs-hypershift.md) pour la décision complète.*

```
┌─────────────────────────────────────────────────────────────┐
│              OKD SNO (homelab) = HUB commun                 │
└───────────────────────┬─────────────────────────────────────┘
                        │
           ┌────────────┴────────────┐
           │                         │
           ▼                         ▼
┌─────────────────────┐   ┌──────────────────────┐
│    HIVE (ce projet) │   │ HYPERSHIFT (companion)│
│                     │   │                       │
│  Spokes = vrais     │   │  Spokes = Hosted      │
│  clusters OKD       │   │  Control Planes       │
│  sur Azure          │   │  (pods sur le hub)    │
│  (masters + workers)│   │  + workers Azure      │
│                     │   │                       │
│  Cluster AUTONOME ✅│   │  Cluster dépendant ❌ │
│  Survit si hub OFF  │   │  du hub pour le CP    │
└─────────────────────┘   └──────────────────────┘
  → Enterprise lifecycle     → Dev/test, densité
    management                 multi-tenancy
```

| | **Hive (ce projet)** | **HyperShift** |
|---|---|---|
| Cluster cible | Autonome, full OKD stack | Hosted Control Plane (pods) |
| Azure workload | Masters + workers | Workers uniquement |
| Survie si hub OFF | ✅ Oui | ❌ Non |
| Coût cloud | Plus élevé | Faible |
| Provisioning | ~30–45 min (IPI) | ~5 min |
| Cas d'usage | Enterprise lifecycle | Dev/test, densité |

---

## 🎯 Target Architecture vs Lab Validation Strategy

Ce projet documente deux niveaux d'architecture : la **cible enterprise** (ce qu'on déploierait en mission) et la **configuration de validation** (ce qui est effectivement testé dans ce homelab).

### Target Architecture — Enterprise (2 clusters HA)

```
HUB — OKD SNO (homelab)
└── Hive ClusterPool "azure-okd-pool"
     ├── SPOKE 1 — OKD HA Cluster A (Azure westeurope)
     │    ├── 3 masters  Standard_D8s_v3  ON-DEMAND
     │    └── 2 workers  Standard_D4s_v3  Spot
     └── SPOKE 2 — OKD HA Cluster B (Azure westeurope)
          ├── 3 masters  Standard_D8s_v3  ON-DEMAND
          └── 2 workers  Standard_D4s_v3  Spot

Coût estimé : ~$400/mois (clusters actifs en permanence)
Cas d'usage  : production enterprise, lifecycle management réel
```

### Lab Validation Strategy — OKD SNO Spoke (~$1.50/session)

```
HUB — OKD SNO (homelab)
└── Hive ClusterDeployment "azure-okd-sno-spoke"
     └── SPOKE — OKD SNO (Azure westeurope)
          └── 1 VM  Standard_D8s_v3  ON-DEMAND (masters = pas de Spot)
              Provisioning ~45min → test → screenshots → destroy

Coût estimé : ~$1.50 par session de validation (3h)
Raison      : valider le concept Hive IPI end-to-end sans coût récurrent
```

> **Pourquoi pas Spot pour les masters ?**
> Les masters OKD portent le control plane (etcd + API server). Une éviction Azure Spot
> = cluster mort immédiatement. Les masters doivent impérativement tourner en ON-DEMAND.

> **Pourquoi pas k3s ou MicroShift comme spoke ?**
> Hive gère des clusters OpenShift/OKD natifs. Les SyncSets utilisent des APIs OpenShift
> (SCCs, Routes, Groups) qui n'existent pas sur Kubernetes générique. Un spoke k3s
> donnerait une démo partielle et trompeuse.

> **Pourquoi SNO et pas HA pour la validation ?**
> L'objectif est de valider le workflow Hive IPI end-to-end (ClusterDeployment → provisioning
> → SyncSets → ArgoCD). Un cluster SNO suffit pour cette validation. La topologie HA
> est documentée dans les manifests `clusterpools/azure-ha-pool.yaml`.

---

## 🗺️ Project Phases

```
Phase 1          Phase 2          Phase 3          Phase 4          Phase 5
────────         ────────         ────────         ────────         ────────
Hive             ClusterPool      Day-2            ArgoCD           Vault
Operator    →    Azure        →   SyncSets     →   ApplicationSet → Integration
Bootstrap        ClusterDeploy    (policies)        (cluster gen)   (cloud creds)
                 SNO spoke
🔜 Planned       🔜 Planned       🔜 Planned       🔜 Planned       🔜 Planned
```

| Phase | Description | Config validée | Status |
|-------|-------------|----------------|--------|
| **Phase 1** | Hive operator deployment via ArgoCD on OKD SNO | Homelab ($0) | 🔜 Planned |
| **Phase 2** | ClusterDeployment Azure SNO — validation IPI end-to-end | Azure SNO (~$1.50) | 🔜 Planned |
| **Phase 3** | Day-2 via SyncSets — Kyverno policies + RBAC | Azure SNO (même session) | 🔜 Planned |
| **Phase 4** | ArgoCD ApplicationSet avec cluster generator | Azure SNO (même session) | 🔜 Planned |
| **Phase 5** | Vault integration — Azure credentials + PKI | Homelab ($0) | 🔜 Planned |

---

## 🏗️ Repository Structure

```
openshift-okd-hive-multicluster-platform/
│
├── README.md
├── SECURITY.md
│
├── docs/
│   ├── adr/
│   │   └── ADR-001-hive-vs-hypershift.md
│   ├── phase1-hive-bootstrap.md
│   ├── phase2-clusterpool.md
│   ├── phase3-syncsets.md
│   ├── phase4-applicationset.md
│   └── phase5-vault-integration.md
│
├── argocd/
│   └── applications/
│       ├── hive.yaml
│       └── clusterpools.yaml
│
├── manifests/
│   ├── hive/
│   │   ├── 01-namespace.yaml
│   │   ├── 02-hiveconfig.yaml
│   │   └── values.yaml
│   ├── clusterpools/
│   │   ├── azure-pool.yaml
│   │   └── cluster-imageset.yaml
│   ├── clusterdeployments/
│   │   └── example-claim.yaml
│   └── syncsets/
│       ├── kyverno-policies.yaml
│       ├── rbac-baseline.yaml
│       └── networkpolicies.yaml
│
├── applicationsets/
│   └── multicluster-apps.yaml
│
├── vault/
│   └── policies/
│       └── hive-azure-policy.hcl
│
└── screenshots/
```

---

## 🔐 Security Highlights

```
Management cluster (HUB)              Spokes (Azure clusters)
────────────────────────              ───────────────────────
Vault                                 Kyverno policies (via SyncSets)
└── Azure SP credentials              ├── deny privileged pods
    injectés dans Hive pods           ├── restrict image registries
    (zéro secret en clair Git)        └── require resource limits

ArgoCD                                RBAC (via SyncSets)
└── GitOps-only, OIDC Keycloak        └── least-privilege ClusterRoles

OKD release images                    NetworkPolicies (via SyncSets)
└── pinned digests via                └── deny-all + allow-ingress
    ClusterImageSet
```

---

## 🔧 Prerequisites

| Component | Version | Notes |
|---|---|---|
| OKD SNO | 4.15 | Management cluster (homelab) |
| ArgoCD Community Operator | v0.17.0 | Already deployed ✅ |
| HashiCorp Vault | 0.28.0 | Already deployed ✅ |
| Keycloak | - | Already deployed ✅ |
| Hive Operator | v1.x | Deployed in Phase 1 |
| Azure subscription | Pay-As-You-Go | West Europe — ON-DEMAND for masters |
| OC CLI | 4.15 | `oc` and `kubectl` |

### 💰 Cost Summary

| Environnement | Usage | Coût estimé |
|---|---|---|
| Homelab OKD SNO | Phases 1, 5 | $0 |
| Azure OKD SNO spoke | 1 session ~3h (Phases 2-4) | ~$1.50 |
| **Total projet** | | **~$1.50** |

> Les manifests `clusterpools/azure-ha-pool.yaml` documentent la configuration HA enterprise
> (2 clusters × 3 masters + 2 workers) sans provisionnement continu (coût ~$400/mois).
> La validation IPI end-to-end est réalisée via un cluster SNO éphémère (~3h, destroy immédiat).

---

## 📚 Related Projects

| Projet | Description |
|---|---|
| [`Openshift-OKD-SNO-Airgap-workstation`](https://github.com/Z3ROX-lab/Openshift-OKD-SNO-Airgap-workstation) | Management cluster base (ArgoCD + Vault + Keycloak) |
| [`okd-hypershift-security-platform`](https://github.com/Z3ROX-lab/okd-hypershift-security-platform) | HyperShift — Hosted Control Planes sur Azure (companion) |
| [`okd-sno-supply-chain`](https://github.com/Z3ROX-lab/okd-sno-supply-chain) | Supply chain security (Cosign + Trivy + Harbor) |
| [`ai-security-platform`](https://github.com/Z3ROX-lab/ai-security-platform) | AI Security Platform on K3d |

---

## 👤 Author

**Stéphane Seloi (Z3ROX)** — Cloud Native Security Architect / Platform Security Engineer
- 20+ years in telecom & cloud infrastructure
- CCSP | AWS Solutions Architect | ISO 27001 Lead Implementer
- [GitHub: Z3ROX-lab](https://github.com/Z3ROX-lab) | [Medium: @Z3R0X](https://medium.com/@Z3R0X)

---

*This project is part of a portfolio demonstrating enterprise-grade multi-cluster management capabilities for freelance Cloud Native Security Architect missions (750–850€/day, Île-de-France).*
