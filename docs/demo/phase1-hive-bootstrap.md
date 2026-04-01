# Phase 1 — Hive Operator Bootstrap : Demo & Screenshots

## Statut : ✅ Complete

**Objectif** : Déployer l'operator Hive sur le cluster OKD SNO (hub) et valider que
tous les composants sont opérationnels avant de provisionner des clusters spokes.

---

## Environnement

```
Hub cluster : OKD SNO 4.15 (sno-master @ 192.168.241.10)
Hive version : v1.1.16 (installation via Kustomize)
Date         : 2026-03-31
```

---

## Étape 1 — Installation des CRDs Hive

Les CRDs (Custom Resource Definitions) définissent les nouveaux types d'objets
Kubernetes que Hive va utiliser. Elles doivent être installées avant l'operator.

```bash
cd ~/work/hive
oc apply -f config/crds/
```

**Résultat attendu :** 20 CRDs créées + 1 ajoutée manuellement
(`clusterdeploymentcustomizations` absente de v1.1.16)

---

## Étape 2 — Déploiement de l'operator via Kustomize

```bash
oc apply -k config/
```

---

## Étape 3 — Fixes RBAC (spécifiques installation sans OLM)

> ⚠️ Ces fixes sont requis uniquement pour une installation via Kustomize.
> OLM les applique automatiquement via le bundle.

```bash
# Leader election leases
oc apply -f manifests/hive/06-rbac-fixes.yaml

# Variables d'environnement manquantes dans le deployment
oc patch deployment hive-operator -n hive --type=json -p='[...]'

# cluster-admin requis pour créer hive-controllers ClusterRole
oc adm policy add-cluster-role-to-user cluster-admin \
  -z hive-operator -n hive
```

---

## Étape 4 — Application du HiveConfig

```bash
oc apply -f manifests/hive/05-hiveconfig.yaml
```

Le HiveConfig est le CR singleton qui configure Hive globalement.
L'operator le réconcilie et crée automatiquement tous les composants restants.

---

## Résultat Final — Validation

### Screenshot 1 — Tous les pods Hive Running

![Phase 1 - Hive All Running](../screenshots/phase1-hive-all-running.png)

**Commande :** `oc get all -n hive`

Ce screenshot montre :
- `hive-operator` → cerveau de Hive, réconcilie le HiveConfig
- `hive-controllers` → gère ClusterDeployment / ClusterPool / ClusterClaim
- `hive-clustersync` → applique les SyncSets sur les spokes
- `hive-machinepool` → gère les MachinePools des clusters spokes
- `hiveadmission (x2)` → webhook de validation des CRs Hive
- `HiveConfig Ready: True` ✅

---

### Screenshot 2 — 21 CRDs Hive installées

![Phase 1 - Hive CRDs](../screenshots/phase1-hive-crds.png)

**Commande :** `oc get crd | grep hive`

Ce screenshot montre les 21 CRDs installées, organisées par catégorie :

| CRD | Rôle |
|-----|------|
| `clusterdeployments` | 1 CR = 1 cluster OKD provisionné |
| `clusterpools` | Pool de clusters pré-provisionnés |
| `clusterclaims` | Réclame un cluster d'un pool |
| `syncsets` | Ressources à pousser sur les spokes (Day-2) |
| `clusterimagesets` | Référence l'image OKD release |
| `hiveconfigs` | Configuration globale Hive (singleton) |
| `machinepools` | Gestion des workers des spokes |
| `dnszones` | Zones DNS gérées par Hive |
| `clusterdeploymentcustomizations` | Customisation install-config (ajouté manuellement) |
| + 12 autres | Provisions, relocates, states, syncs... |

---

## Issues rencontrées et fixes

| # | Problème | Cause | Fix |
|---|---------|-------|-----|
| 1 | OLM catalog Harbor incomplet | Image Harbor ne contient pas hive-operator | Installation via Kustomize depuis GitHub |
| 2 | `leases` RBAC manquant | Kustomize upstream incomplet vs bundle OLM | Role `hive-operator-leader-election` créé |
| 3 | `config.openshift.io` RBAC manquant | Proxies/APIServers non dans le ClusterRole | ClusterRole `hive-operator-openshift-config` créé |
| 4 | `POD_NAME`/`POD_NAMESPACE` manquants | Non définis dans le deployment Kustomize | Patch deployment env vars |
| 5 | `hiveadmission` ClusterRole forbidden | operator ne peut pas créer des droits qu'il n'a pas | `cluster-admin` accordé au SA hive-operator |
| 6 | `ClusterDeploymentCustomization` CRD manquante | Absente de v1.1.16, ajoutée en v1.2.x | CRD créée manuellement |
| 7 | ArgoCD namespaced mode incompatible | ArgoCD ne gère pas les ressources cluster-level | `oc apply` direct au lieu d'ArgoCD Application |

---

## Vérification finale

```bash
# Tous les pods Running
oc get pods -n hive

# HiveConfig Ready
oc get hiveconfig hive -o jsonpath='{.status.conditions[0].type}: {.status.conditions[0].status}'
# → Ready: True ✅

# 21 CRDs installées
oc get crd | grep hive | wc -l
# → 21 ✅
```

---

## Prochaine étape

➡️ [Phase 2 — ClusterDeployment Azure SNO](phase2-clusterdeployment.md)

*Tous les fichiers demo sont dans `docs/demo/`*

Provisionnement d'un cluster OKD SNO sur Azure via Hive IPI (~$1.50 pour 3h de validation).
