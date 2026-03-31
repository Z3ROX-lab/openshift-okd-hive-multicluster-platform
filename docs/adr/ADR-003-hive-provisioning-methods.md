# ADR-003 — Hive : Méthodes de Provisioning

| | |
|---|---|
| **Statut** | Accepted |
| **Date** | 2026-03-31 |
| **Auteur** | Stéphane Seloi (Z3ROX) |
| **Projet** | openshift-okd-hive-multicluster-platform |

---

## Contexte

Hive supporte plusieurs méthodes pour provisionner et gérer des clusters OKD/OpenShift.
Ce document clarifie les différences entre IPI, UPI, Agent-based et Adopt,
et justifie le choix retenu pour ce projet.

---

## 1. Les 4 méthodes de provisioning Hive

```
┌─────────────────────────────────────────────────────────────┐
│                      HIVE OPERATOR                          │
│                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │   IPI    │  │   UPI    │  │  Agent   │  │  Adopt   │   │
│  │          │  │          │  │  Based   │  │          │   │
│  │ Hive crée│  │ Tu crées │  │ Bare     │  │ Cluster  │   │
│  │ tout     │  │ l'infra  │  │ metal    │  │ existant │   │
│  │ (cloud)  │  │ toi-même │  │ ISO boot │  │ adopté   │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. IPI — Installer Provisioned Infrastructure

### Principe

```
ClusterDeployment CR
└── Hive lance openshift-install en mode IPI
     └── openshift-install appelle l'API cloud
          ├── crée VMs / instances
          ├── crée réseau / VPC / VNet
          ├── crée load balancers
          ├── crée DNS records
          └── installe OKD dessus
               └── cluster prêt ✅
```

### Ce que génère openshift-install create manifests

```
install-dir/
├── manifests/                           ← configs cluster
│   ├── cluster-config.yaml              ← config générale
│   ├── cluster-dns-02-config.yml        ← DNS
│   ├── cluster-infrastructure-02-config.yml  ← infra cloud
│   ├── cluster-network-02-config.yml    ← OVN config
│   ├── cluster-proxy-01-config.yaml     ← proxy egress
│   ├── cluster-scheduler-02-config.yml  ← scheduler
│   ├── cvo-overrides.yaml               ← cluster version
│   └── openshift-config-secret-pull-secret.yaml
│
└── openshift/                           ← configs OpenShift
    ├── 99_cloud-creds-secret.yaml       ← credentials Azure/AWS
    ├── 99_kubeadmin-password-secret.yaml
    ├── 99_openshift-cluster-api_master-machines-0.yaml  ← master 1
    ├── 99_openshift-cluster-api_master-machines-1.yaml  ← master 2
    ├── 99_openshift-cluster-api_master-machines-2.yaml  ← master 3
    └── 99_openshift-cluster-api_worker-machineset-0.yaml ← workers
```

### Exemple Machine manifest (master Azure)

```yaml
# 99_openshift-cluster-api_master-machines-0.yaml
apiVersion: machine.openshift.io/v1beta1
kind: Machine
metadata:
  name: cluster-master-0
spec:
  providerSpec:
    value:
      vmSize: Standard_D8s_v3    # ← taille VM Azure
      location: westeurope
      osDisk:
        diskSizeGB: 128
        managedDisk:
          storageAccountType: Premium_LRS
      publicIP: false
```

### Hive + IPI — ce qui se passe concrètement

```
ClusterDeployment CR appliqué
         │
         ▼
Hive operator
         │
         └── crée pod "hive-install-manager"
              │
              └── lance openshift-install create cluster
                   (même binaire que toi en manuel !)
                   │
                   ├── génère manifests/ automatiquement
                   ├── appelle API Azure
                   ├── crée l'infra
                   └── cluster OKD prêt ✅
                        └── Hive stocke le kubeconfig
```

### Manifests custom injectables via Hive

```yaml
# ClusterDeployment avec manifests custom
spec:
  provisioning:
    installConfigSecretRef:
      name: my-install-config    # ← ton install-config.yaml
    manifestsSecretRef:
      name: my-custom-manifests  # ← tes fichiers manifests/
                                 #   ex: MachineSet custom
                                 #       NetworkPolicy
                                 #       MachineConfig
```

### Plateformes IPI supportées

```
AWS        ✅ GA — le mieux supporté
Azure      ✅ GA — notre choix
GCP        ✅ GA
vSphere    ✅ GA
OpenStack  ✅ GA
Nutanix    ✅ GA
```

---

## 3. UPI — User Provisioned Infrastructure

### Principe

```
Tu crées l'infra toi-même
         │
         ├── VMs créées manuellement
         ├── réseau configuré manuellement
         ├── DNS configuré manuellement
         └── LB configuré manuellement
              │
              ▼
         openshift-install create manifests
         openshift-install create ignition-configs
              │
              ▼
         Tu boottes les VMs avec les ignition configs
              │
              ▼
         openshift-install wait-for install-complete
              │
              ▼
         Cluster prêt → tu passes le kubeconfig à Hive
```

### Avantages UPI

```
✅ Contrôle total sur l'infra
✅ Intégration réseau existant
✅ Bare metal
✅ Clouds non supportés en IPI
✅ Conformité infra spécifique (GovCloud, etc.)
```

---

## 4. Agent-based — Bare Metal

### Principe

```
Hive génère une ISO FCOS avec agent embarqué
         │
         ▼
Tu boottes les serveurs avec cette ISO
         │
         ▼
L'agent contacte Hive (Assisted Installer)
         │
         ▼
Hive orchestre l'installation sur les serveurs
         │
         ▼
Cluster bare metal prêt ✅
```

### Ce que tu as fait sur ton OKD SNO Airgap

```
Agent-based installer (variante SNO) :

openshift-install create agent-config
openshift-install agent create image  ← ISO FCOS + ignition
         │
         └── tu as booté la VM VMware avec cet ISO
              → OKD s'est installé tout seul ✅

Pas de manifests/ générés séparément
car agent-based = tout dans l'ISO
```

---

## 5. Adopt — Cluster existant

### Principe

```
Tu as déjà un cluster OKD/OpenShift
         │
         ▼
ClusterDeployment avec installed: true
         │
         ├── Hive ne provisionne RIEN
         ├── Hive adopte le cluster existant
         └── Hive peut appliquer :
              ├── SyncSets (Day-2 ops) ✅
              ├── SyncIdentityProviders ✅
              └── ClusterDeprovision (destroy) ✅
```

### Exemple ClusterDeployment Adopt

```yaml
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: my-existing-cluster
spec:
  installed: true              # ← clé : cluster déjà installé
  clusterName: my-cluster
  baseDomain: okd.lab
  platform:
    none: {}                   # ← pas de provisioning cloud
  provisioning:
    installConfigSecretRef:
      name: install-config
  clusterMetadata:
    adminKubeconfigSecretRef:
      name: my-kubeconfig      # ← kubeconfig du cluster existant
    clusterID: "my-cluster-id"
    infraID: "my-infra-id"
```

---

## 6. Comparaison des méthodes

| | **IPI** | **UPI** | **Agent** | **Adopt** |
|---|---|---|---|---|
| Infra créée par | Hive/openshift-install | Toi | Toi (serveurs) | Existante |
| Plateformes | Cloud (AWS/Azure/GCP...) | Tout | Bare metal | Tout |
| Automatisation | Totale ✅ | Partielle | Semi-auto | Aucune |
| Contrôle infra | Faible | Total ✅ | Total ✅ | N/A |
| Day-2 SyncSets | ✅ | ✅ | ✅ | ✅ |
| Complexité | Faible ✅ | Élevée | Moyenne | Faible ✅ |
| Coût cloud | VMs auto | VMs manuelles | Pas de cloud | Existant |

---

## 7. IPI vs UPI — la même base, openshift-install

```
LES DEUX utilisent openshift-install — même binaire !

IPI :
  openshift-install create cluster
  └── fait TOUT en une commande ✅

UPI :
  openshift-install create manifests        ← étape 1
  openshift-install create ignition-configs ← étape 2
  [tu crées l'infra manuellement]           ← étape 3
  openshift-install wait-for bootstrap-complete ← étape 4
  openshift-install wait-for install-complete   ← étape 5
```

---

## 8. Décision — méthode retenue pour ce projet

**IPI sur Azure** est retenu pour les raisons suivantes :

```
1. Automatisation complète
   → Hive gère tout via le ClusterDeployment CR
   → GitOps-first : 1 CR = 1 cluster ✅

2. Validation du concept Hive IPI end-to-end
   → Démontre la capacité enterprise ACM/MCE
   → Les missions utilisent IPI sur cloud ✅

3. Azure déjà configuré
   → Service Principal existant (projet HyperShift)
   → VNet/Subnet/DNS zone déjà maîtrisés ✅

4. Coût maîtrisé via SNO éphémère
   → 1 VM Standard_D8s_v3 ON-DEMAND ~$1.50/session
   → Destroy immédiat après validation ✅
```

### Ce qui est documenté mais pas provisionné en continu

```
manifests/clusterpools/azure-ha-pool.yaml
└── 2 clusters HA (3 masters + 2 workers)
    Coût : ~$400/mois
    Documenté pour référence enterprise ✅
    Non provisionné en continu (homelab budget) ⚠️
```

---

## Références

- [Hive GitHub](https://github.com/openshift/hive)
- [Hive Using Hive Docs](https://github.com/openshift/hive/blob/master/docs/using-hive.md)
- [OKD IPI Azure](https://docs.okd.io/latest/installing/installing_azure/ipi/installing-azure-default.html)
- [OKD UPI](https://docs.okd.io/latest/installing/installing_bare_metal/installing-bare-metal.html)
- [ADR-001 — Hive vs HyperShift](ADR-001-hive-vs-hypershift.md)
- [ADR-002 — HyperShift Multi-Platform HA](ADR-002-hypershift-multiplatform-ha.md)
