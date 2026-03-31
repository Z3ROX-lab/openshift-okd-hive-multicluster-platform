# Phase 1 — Hive Operator Bootstrap

## Statut : ✅ Complete

## Méthode d'installation

Hive v1.1.16 installé via Kustomize (sans OLM).
Le catalog Harbor ne contenait pas le package hive-operator.

## Séquence d'installation

```bash
# 1. Clone du repo Hive
git clone https://github.com/openshift/hive.git --depth=1 --branch v1.1.16

# 2. CRDs (20 CRDs)
oc apply -f config/crds/

# 3. Operator via Kustomize
oc apply -k config/

# 4. RBAC manquants (non inclus dans kustomize upstream)
oc apply -f manifests/hive/06-rbac-fixes.yaml

# 5. Variables d'environnement manquantes
oc patch deployment hive-operator -n hive --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-",
   "value": {"name": "POD_NAME", "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}}},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-",
   "value": {"name": "POD_NAMESPACE", "valueFrom": {"fieldRef": {"fieldPath": "metadata.namespace"}}}}
]'

# 6. HiveConfig CR
oc apply -f manifests/hive/05-hiveconfig.yaml
```

## Résultat

```
NAME                                READY   STATUS    AGE
hive-controllers                    1/1     Running   ✅
hive-operator                       1/1     Running   ✅
```

## CRDs installées (20)

- clusterdeployments.hive.openshift.io
- clusterpools.hive.openshift.io
- clusterclaims.hive.openshift.io
- syncsets.hive.openshift.io
- clusterimagesets.hive.openshift.io
- clusterprovisions.hive.openshift.io
- machinepools.hive.openshift.io
- hiveconfigs.hive.openshift.io
- + 12 autres

## Issues rencontrées et fixes

| Issue | Fix |
|---|---|
| OLM catalog Harbor incomplet | Installation via Kustomize |
| leases RBAC manquant | Role hive-operator-leader-election |
| config.openshift.io RBAC manquant | ClusterRole hive-operator-openshift-config |
| POD_NAME/POD_NAMESPACE manquants | Patch deployment env vars |
| ArgoCD namespaced mode incompatible | oc apply direct |
