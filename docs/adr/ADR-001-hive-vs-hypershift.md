# ADR-001 — Hive vs HyperShift : choix de l'approche multi-cluster

| | |
|---|---|
| **Statut** | Accepted |
| **Date** | 2026-03-30 |
| **Auteur** | Stéphane Seloi (Z3ROX) |
| **Projet** | openshift-okd-hive-multicluster-platform |

---

## Contexte

Dans le cadre du portfolio Cloud Native Security Architect, deux projets distincts implémentent du multi-cluster sur OKD. Tous deux utilisent le même management cluster (OKD SNO homelab) comme hub, mais avec des approches fondamentalement différentes pour provisionner et gérer les clusters cibles.

Cette ADR documente pourquoi **Hive** a été choisi pour ce projet, en complément de HyperShift qui fait l'objet d'un projet séparé.

---

## Le pattern commun : Hub and Spoke

Les deux approches partagent le même pattern architectural de base.

```
┌──────────────────────────────────────────────┐
│           HUB — OKD SNO (homelab)            │
│                                              │
│  Management cluster : ne fait tourner        │
│  aucune application métier.                  │
│  Son seul rôle : gérer les spokes.           │
│                                              │
│  • Hive / HyperShift operator                │
│  • ArgoCD (GitOps engine)                    │
│  • Vault (secrets management)                │
│  • Keycloak (OIDC SSO)                       │
└──────────────────┬───────────────────────────┘
                   │
       ┌───────────┼───────────┐
       │           │           │
       ▼           ▼           ▼
  ┌─────────┐ ┌─────────┐ ┌─────────┐
  │ SPOKE 1 │ │ SPOKE 2 │ │ SPOKE N │
  │         │ │         │ │         │
  │workloads│ │workloads│ │workloads│
  └─────────┘ └─────────┘ └─────────┘
```

> **Analogie** : le HUB est la tour de contrôle aéroportuaire.
> Les SPOKEs sont les avions : ils volent de façon autonome
> mais obéissent aux instructions de la tour.

La différence majeure entre Hive et HyperShift réside dans **ce qui tourne sur les spokes**.

---

## Option A — HyperShift (Hosted Control Planes)

```
┌──────────────────────────────────────────────────────────┐
│                    HUB — OKD SNO                         │
│                                                          │
│  HyperShift Operator                                     │
│  └── Hosted Control Plane (pods OKD)  ← CP ICI dans hub │
│       ├── kube-apiserver (pod)                           │
│       ├── etcd (pod)                                     │
│       ├── kube-controller-manager (pod)                  │
│       └── openshift-oauth (pod)                          │
│                                                          │
└────────────────────────┬─────────────────────────────────┘
                         │
                         │ mTLS / Tailscale
                         │ (workers se connectent au CP)
                         │
              ┌──────────┴──────────┐
              │   SPOKE — Azure     │
              │                     │
              │   Workers UNIQUEMENT│
              │   ┌───────────────┐ │
              │   │  worker node  │ │
              │   │  (Spot VM)    │ │
              │   └───────────────┘ │
              │                     │
              │  ❌ Pas de masters  │
              │  ❌ Pas d'etcd      │
              │  ❌ Pas autonome    │
              └─────────────────────┘

Si le HUB s'éteint → control plane mort → spoke inaccessible ❌
```

**Caractéristiques :**
- Control plane hébergé **dans le hub** sous forme de pods
- Les workers Azure sont de simples nœuds de calcul
- Le cluster spoke n'est **pas autonome**
- Démarrage rapide (~5 min)
- Densité élevée (N clusters = N × quelques pods)
- Coût faible (pas de VMs masters sur Azure)

---

## Option B — Hive (Full Cluster Provisioning)

```
┌──────────────────────────────────────────────────────────┐
│                    HUB — OKD SNO                         │
│                                                          │
│  Hive Operator                                           │
│  └── ClusterPool / ClusterDeployment                     │
│       └── lance l'OpenShift Installer (IPI)              │
│            └── appelle l'API Azure                       │
│                                                          │
└────────────────────────┬─────────────────────────────────┘
                         │
                         │ OpenShift Installer (IPI)
                         │ Azure API calls
                         │
              ┌──────────┴──────────┐
              │   SPOKE — Azure     │
              │                     │
              │   Cluster OKD COMPLET
              │   ┌───────────────┐ │
              │   │  master node  │ │  ← etcd, API server,
              │   │  master node  │ │    controller manager
              │   │  master node  │ │    sur des VMs Azure
              │   └───────────────┘ │
              │   ┌───────────────┐ │
              │   │  worker node  │ │
              │   │  worker node  │ │
              │   └───────────────┘ │
              │                     │
              │  ✅ Cluster autonome│
              │  ✅ Survit si hub OFF
              └─────────────────────┘

Si le HUB s'éteint → cluster continue de tourner ✅
```

**Caractéristiques :**
- Cluster OKD **complet et autonome** provisionné sur Azure
- Masters + workers = VMs Azure dédiées
- Provisioning via OpenShift Installer (IPI) ~30–45 min
- Coût plus élevé (VMs masters en plus)
- Pattern identique à **ACM/MCE** en enterprise Red Hat

---

## Comparaison détaillée

```
                    HIVE              HYPERSHIFT
                    ────              ──────────

Cluster cible       Full OKD stack    Hosted CP (pods)
                    autonome          + workers

Control plane       Sur Azure (VMs)   Dans le hub (pods)

Survie hub OFF      ✅ Oui            ❌ Non

Démarrage           ~30–45 min        ~5 min

Densité             Faible            Élevée
                    (VMs masters)     (pods légers)

Coût Azure          $$$ masters       $ workers only
                    + workers

Cas d'usage         Enterprise        Dev/test
                    lifecycle mgmt    multi-tenancy

Équivalent Red Hat  ACM + Hive        HyperShift / ROSA HCP

Complexité          Moyenne           Élevée
opérationnelle      (IPI standard)    (networking spécifique)

GitOps Day-2        SyncSets          SyncSets / NodePool
```

---

## Décision

**Hive est choisi pour ce projet** pour les raisons suivantes :

**1. Complémentarité portfolio**
HyperShift est déjà implémenté dans `okd-hypershift-security-platform`. Les deux projets ensemble couvrent les deux patterns dominants du marché enterprise Red Hat.

**2. Pattern ACM/MCE**
Hive est le moteur de provisioning sous-jacent d'**Advanced Cluster Management (ACM)** et **MCE**. Maîtriser Hive en open source permet d'arriver en mission avec le même modèle mental que les produits Red Hat licenciés.

**3. Autonomie des clusters**
Dans un contexte de mission enterprise (Orange, Telefónica, Nokia…), les clusters de production doivent survivre à une panne du management cluster. Hive garantit cette autonomie, HyperShift non.

**4. Lifecycle management réaliste**
`ClusterPool` + `ClusterClaim` + hibernation + `SyncSets` Day-2 représentent des opérations réelles pratiquées en mission sur ACM. Ce projet les démontre en open source.

**5. Contrainte homelab**
Hive tourne entièrement sur le management cluster OKD SNO existant (~600MB–1GB overhead). Les clusters cibles sont provisionnés sur Azure — aucune ressource supplémentaire homelab n'est nécessaire.

---

## Conséquences

### Positives
- Démontre deux patterns complémentaires sur le même hub OKD SNO
- Réutilise ArgoCD, Vault et Keycloak déjà déployés
- Prépare aux missions ACM/MCE (Red Hat licencié)
- Clusters Azure autonomes = scénario production réaliste

### Négatives / Contraintes
- Coût Azure plus élevé (VMs masters) → mitigation : hibernation + Spot VMs
- Provisioning long (~30–45 min) → mitigation : ClusterPool pré-provisionne en avance
- Pas de provisionning bare metal homelab → les spokes vivent sur Azure uniquement

---

## Architecture finale retenue

```
┌─────────────────────────────────────────────────────────────────┐
│              OKD SNO (homelab) = HUB commun                     │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Ce projet (Hive)                      │  │
│  │                                                          │  │
│  │  Hive Operator → ClusterPool → 2 clusters OKD Azure     │  │
│  │  ArgoCD        → ApplicationSet → apps sur les spokes   │  │
│  │  Vault         → Azure SP credentials injectés          │  │
│  │  SyncSets      → Kyverno + RBAC + NetworkPolicies       │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              Projet companion (HyperShift)                │  │
│  │                                                          │  │
│  │  HyperShift → Hosted Control Planes (pods)              │  │
│  │  Workers Azure Spot uniquement                           │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
               ┌──────────────┴──────────────┐
               │                             │
               ▼                             ▼
  ┌────────────────────┐        ┌────────────────────┐
  │  OKD Cluster A     │        │  OKD Cluster B     │
  │  Azure westeurope  │        │  Azure westeurope  │
  │  Full stack ✅     │        │  Full stack ✅     │
  │  Autonome ✅       │        │  Autonome ✅       │
  └────────────────────┘        └────────────────────┘
```

---

## Références

- [OpenShift Hive — GitHub](https://github.com/openshift/hive)
- [HyperShift — GitHub](https://github.com/openshift/hypershift)
- [okd-hypershift-security-platform](https://github.com/Z3ROX-lab/okd-hypershift-security-platform) — projet companion
- [Red Hat ACM — Hive architecture](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management)
