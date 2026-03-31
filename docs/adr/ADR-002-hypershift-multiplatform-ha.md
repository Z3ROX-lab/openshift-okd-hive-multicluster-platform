# ADR-002 — HyperShift : Multi-Platform et Haute Disponibilité

| | |
|---|---|
| **Statut** | Accepted |
| **Date** | 2026-03-31 |
| **Auteur** | Stéphane Seloi (Z3ROX) |
| **Projet** | okd-hypershift-security-platform |

---

## Contexte

HyperShift permet d'héberger plusieurs Control Planes OKD sous forme de pods
sur un cluster management (hub). Ce document clarifie l'architecture réelle
de HyperShift, notamment sur les questions de HA et de support multi-plateforme.

---

## 1. Architecture HyperShift — 1 CP par cluster, pas 1 CP partagé

Une idée reçue courante : HyperShift = 1 Control Plane partagé pour tous les clusters.

**La réalité :**

```
HUB OKD SNO
│
├── HostedCluster "cluster-azure"
│    └── Control Plane DÉDIÉ (pods)
│         ├── kube-apiserver-azure     (pod)
│         ├── etcd-azure               (pod)
│         └── kube-controller-azure    (pod)
│              └── workers : Azure Spot VMs
│
├── HostedCluster "cluster-aws"
│    └── Control Plane DÉDIÉ (pods)
│         ├── kube-apiserver-aws       (pod)
│         ├── etcd-aws                 (pod)
│         └── kube-controller-aws      (pod)
│              └── workers : AWS Spot VMs
│
└── HostedCluster "cluster-baremetal"
     └── Control Plane DÉDIÉ (pods)
          ├── kube-apiserver-bm        (pod)
          ├── etcd-bm                  (pod)
          └── kube-controller-bm       (pod)
               └── workers : serveurs physiques
```

Chaque HostedCluster a son propre CP isolé — les données etcd sont distinctes
et les apiserver ne se partagent pas.

---

## 2. Ce qui est partagé vs dédié

```
PARTAGÉ entre tous les HostedClusters
──────────────────────────────────────
HyperShift operator        ✅ 1 instance sur le hub
etcd du hub                ✅ stocke les HostedCluster CRs
Réseau hub (OVN)           ✅
Keycloak hub               ✅ SSO centralisé
ArgoCD hub                 ✅ GitOps centralisé

DÉDIÉ par HostedCluster
────────────────────────
kube-apiserver             1 pod (ou plusieurs si HA)
etcd                       1 pod par défaut (⚠️ pas HA)
kube-controller-manager    1 pod par défaut
openshift-oauth-server     1 pod
NodePool workers           VMs dédiées par cluster
```

---

## 3. Haute Disponibilité — la vérité

### Control Plane

```
Composant              HA par défaut ?   Configurable ?
─────────              ───────────────   ──────────────
kube-apiserver         ✅ 2+ replicas    ✅ Oui
etcd                   ❌ 1 replica      ✅ Oui (3 replicas)
kube-controller-mgr    ❌ 1 replica      ✅ Oui
openshift-oauth        ❌ 1 replica      ✅ Oui

→ CP = "pseudo-HA" par défaut
  apiserver HA ✅ mais etcd single point of failure ⚠️
```

### Workers

```
HA des workers = ton choix via NodePool :

NodePool replicas: 1   → pas HA ❌
NodePool replicas: 3   → HA ✅

spec:
  nodePool:
    replicas: 3         ← minimum pour HA worker
    management:
      upgradeType: Replace
```

### Autonomie si hub OFF

```
Hub s'éteint
└── Control Plane pods morts (sur le hub)
     └── kube-apiserver inaccessible
          └── workers continuent de tourner
               MAIS kubectl/oc ne répond plus ❌
               Les workloads existants continuent ✅
               Nouveaux déploiements impossibles ❌

→ HostedCluster N'EST PAS autonome ❌
  Différence fondamentale avec Hive (voir ADR-003)
```

---

## 4. Support Multi-Plateforme

### Plateformes supportées officiellement

```
Plateforme          Support          Notes
──────────          ───────          ─────
AWS                 ✅ GA            Mieux supporté
Azure               ✅ GA            Notre choix
Bare Metal          ✅ GA            Via Agent provider
KubeVirt            ✅ GA            VMs dans le hub
IBM PowerVS         ✅ GA            IBM Cloud
OpenStack           ⚠️ Tech Preview
vSphere             ⚠️ Tech Preview
GCP                 ❌ Non supporté
```

### Multi-cloud simultané — OUI c'est possible

```
1 hub HyperShift peut gérer des clusters sur N plateformes :

HUB OKD SNO
├── HostedCluster → Azure westeurope  ✅
├── HostedCluster → AWS eu-west-1     ✅
└── HostedCluster → Bare Metal local  ✅

Chaque cluster a ses propres credentials cloud
stockés dans des Secrets distincts référencés
par le HostedCluster CR.
```

---

## 5. SSO sur les HostedClusters

### Pattern retenu — Keycloak Hub centralisé

```
HUB OKD SNO
└── Keycloak hub
     └── realm: okd

HostedCluster CR
└── spec.configuration.oauth
     └── identityProviders:
          └── type: OpenID
               issuer: https://keycloak.apps.sno.okd.lab/realms/okd
```

### Flow utilisateur

```
User → Console spoke → OAuth redirect → Keycloak HUB ✅

Particularité HyperShift :
  L'oauth-server tourne sur le HUB (pod CP)
  → si hub OFF → SSO impossible ❌
  → cohérent avec la non-autonomie du cluster
```

### Comparaison SSO HyperShift vs Hive

```
                    HyperShift         Hive
                    ──────────         ────

OAuth config        HostedCluster CR   SyncSet Day-2
                    (Day-0 install)    (après install)

OAuth server        Sur le HUB (pod)   LOCAL au spoke
                    ❌ non autonome    ✅ autonome

SSO si hub OFF      ❌ impossible      ✅ fonctionne
```

---

## 6. Avantages HyperShift vs clusters classiques

### Densité et coût

```
10 clusters classiques HA :
  10 × 3 masters Standard_D8s_v3 = 30 VMs Azure
  Coût : ~$3,500/mois (masters seuls)

10 HostedClusters HyperShift :
  30 pods CP sur le hub (GEEKOM A6)
  + workers Azure Spot uniquement
  Coût : ~$350/mois (workers seuls)

Économie : ~90% sur les masters ✅
```

```
Temps de provisioning :
  Cluster classique IPI : ~45 min
  HostedCluster        : ~5 min  ✅
```

---

## 7. Cas d'usage recommandés

```
HyperShift est idéal pour :
  ✅ Dev / test / CI (clusters éphémères)
  ✅ Multi-tenant (isolation par CP)
  ✅ Coût optimisé (pas de masters cloud)
  ✅ Provisioning rapide (~5 min)
  ✅ Multi-cloud depuis 1 hub

HyperShift n'est PAS idéal pour :
  ❌ Clusters de production autonomes
  ❌ Sites edge déconnectés
  ❌ Workloads nécessitant survie si hub OFF
  → Utiliser Hive dans ce cas (voir ADR-001, ADR-003)
```

---

## Références

- [HyperShift GitHub](https://github.com/openshift/hypershift)
- [HyperShift HA Configuration](https://hypershift-docs.netlify.app/how-to/agent/create-agent-cluster/)
- [HyperShift Supported Platforms](https://hypershift-docs.netlify.app/reference/api/)
- [okd-hypershift-security-platform](https://github.com/Z3ROX-lab/okd-hypershift-security-platform)
- [ADR-001 — Hive vs HyperShift](ADR-001-hive-vs-hypershift.md)
- [ADR-003 — Hive Provisioning Methods](ADR-003-hive-provisioning-methods.md)
