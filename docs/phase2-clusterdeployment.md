# Phase 2 — ClusterDeployment Azure SNO : Demo & Screenshots

## Statut : 🔄 In Progress

**Objectif** : Provisionner un cluster OKD SNO sur Azure via Hive IPI pour valider
le workflow end-to-end (ClusterDeployment → provisioning → kubeconfig).

---

## Environnement

```
Hub cluster  : OKD SNO 4.15 (sno-master @ 192.168.241.10)
Hive version : v1.1.16
Spoke target : OKD SNO Azure westeurope
VM type      : Standard_D8s_v3 ON-DEMAND (masters = pas de Spot !)
Coût estimé  : ~$1.50 pour 3h de validation
Date         : 2026-04-01
```

---

## Prérequis Azure — Service Principal

### Pourquoi un Service Principal ?

```
Hive IPI doit appeler l'API Azure pour créer :
  ├── Resource Group
  ├── VNet / Subnet / NSG
  ├── Load Balancers
  ├── VMs masters (Standard_D8s_v3 ON-DEMAND)
  └── DNS records

→ Hive a besoin d'un compte de service Azure
  avec les droits suffisants = Service Principal
```

### Création du Service Principal

```bash
# Crée le SP dédié Hive
az ad sp create-for-rbac \
  --name "sp-hive-multicluster" \
  --role Contributor \
  --scopes /subscriptions/$(az account show --query id -o tsv) \
  --output json > /tmp/hive-sp.json

# Vérifie (sans afficher les secrets)
cat /tmp/hive-sp.json | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('SP créé ✅')
print('appId:', d['appId'][:8]+'...')
"
```

> ⚠️ **Sécurité** : Ne jamais committer les credentials SP dans Git.
> Utiliser `TF_VAR_*` pour Terraform et Vault pour Hive (Phase 5).

### Création du Secret OKD

```bash
# Crée le Secret azure-creds dans le namespace hive
AZURE_SP=$(cat /tmp/hive-sp.json)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

oc create secret generic azure-creds \
  -n hive \
  --from-literal=osServicePrincipal.json="$(echo $AZURE_SP | python3 -c "
import sys,json
d=json.load(sys.stdin)
import os
out={
  'clientId': d['appId'],
  'clientSecret': d['password'],
  'tenantId': d['tenant'],
  'subscriptionId': '$SUBSCRIPTION_ID'
}
print(json.dumps(out))
")"

# Supprime le fichier temporaire
rm -f /tmp/hive-sp.json
```

---

## Étape 1 — Infra Azure via Terraform

### Pourquoi Terraform et pas az CLI ?

```
az CLI :
  → commandes manuelles
  → pas de state management
  → pas de destroy propre
  → pas reproductible

Terraform :
  → state management ✅
  → plan avant apply ✅
  → destroy propre ✅
  → reproductible ✅
  → GitOps-compatible ✅
```

### Variables sensibles — pattern TF_VAR_

```bash
# Exporter AVANT terraform plan/apply
# Ne JAMAIS écrire ces valeurs dans un fichier Git !
export TF_VAR_subscription_id="YOUR_SUBSCRIPTION_ID"
export TF_VAR_tenant_id="YOUR_TENANT_ID"
export TF_VAR_client_id="YOUR_SP_CLIENT_ID"
export TF_VAR_client_secret="YOUR_SP_CLIENT_SECRET"
```

### Structure Terraform

```
terraform/
├── .gitignore          ← ignore .terraform/, tfstate, .env
├── .terraform.lock.hcl ← versions providers (dans Git ✅)
├── main.tf             ← resource group + DNS zone
├── variables.tf        ← déclaration variables (sensitive=true)
└── outputs.tf          ← dns_zone_name, name_servers
```

### Ressources créées

```hcl
# main.tf
resource "azurerm_resource_group" "hive" {
  name     = "rg-hive-multicluster"
  location = "westeurope"
  tags = {
    project    = "okd-hive-multicluster"
    managed-by = "terraform"
    owner      = "Z3ROX-lab"
  }
}

resource "azurerm_dns_zone" "hive" {
  name                = "hive.okd.lab"
  resource_group_name = azurerm_resource_group.hive.name
}
```

### Screenshot 1 — Terraform Plan

![Phase 2 - Terraform Plan](../screenshots/phase2-terraform-plan.png)

**Commande :** `terraform plan`

Ce screenshot montre :
- `azurerm_dns_zone.hive` → DNS zone `hive.okd.lab` à créer
- `azurerm_resource_group.hive` → Resource group `rg-hive-multicluster` à créer
- Tags : `managed-by=terraform`, `project=okd-hive-multicluster`, `owner=Z3ROX-lab`
- **Plan: 2 to add, 0 to change, 0 to destroy** ✅
- Aucune donnée sensible visible ✅

---

## Étape 2 — Terraform Apply

```bash
cd terraform/
terraform apply
```

### Screenshot 2 — Terraform Apply

![Phase 2 - Terraform Apply](../screenshots/phase2-terraform-apply.png)

**Commande :** `terraform apply`

Ce screenshot montre :
- `Apply complete! Resources: 2 added, 0 changed, 0 destroyed` ✅
- `dns_zone_name = "hive.okd.lab"` ✅
- `dns_zone_name_servers` → 4 name servers Azure (ns1→ns4-03.azure-dns.*) ✅
- `resource_group_name = "rg-hive-multicluster"` ✅
- Subscription ID masquée dans le resource_group_id ✅

---

## Étape 3 — ClusterImageSet OKD 4.15

Le ClusterImageSet référence l'image OKD release à utiliser pour le spoke.

```bash
cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: okd-4.15
spec:
  releaseImage: quay.io/okd/scos-release:4.15.0-0.okd-2024-03-10-010116
EOF

# Vérifie
oc get clusterimageset
```

---

## Étape 4 — Install Config Secret

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: okd-sno-spoke-install-config
  namespace: hive
stringData:
  install-config.yaml: |
    apiVersion: v1
    baseDomain: hive.okd.lab
    metadata:
      name: spoke-1
    compute:
    - name: worker
      replicas: 0
    controlPlane:
      name: master
      replicas: 1
      platform:
        azure:
          type: Standard_D8s_v3
          osDisk:
            diskSizeGB: 128
    networking:
      clusterNetwork:
      - cidr: 10.128.0.0/14
        hostPrefix: 23
      networkType: OVNKubernetes
      serviceNetwork:
      - 172.30.0.0/16
    platform:
      azure:
        baseDomainResourceGroupName: rg-hive-multicluster
        region: westeurope
    pullSecret: '{"auths":{"fake":{"auth":"aWQ6cGFzcwo="}}}'
EOF
```

> ⚠️ **Pull secret** : OKD ne requiert pas de pull secret Red Hat.
> La valeur fictive `{"auths":{"fake":{"auth":"aWQ6cGFzcwo="}}}` est suffisante.

---

## Étape 5 — ClusterDeployment

```bash
cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: okd-sno-spoke
  namespace: hive
spec:
  baseDomain: hive.okd.lab
  clusterName: spoke-1
  platform:
    azure:
      credentialsSecretRef:
        name: azure-creds
      region: westeurope
      baseDomainResourceGroupName: rg-hive-multicluster
  provisioning:
    imageSetRef:
      name: okd-4.15
    installConfigSecretRef:
      name: okd-sno-spoke-install-config
  pullSecretRef:
    name: okd-sno-spoke-install-config
EOF

# Surveille le provisioning
watch "oc get clusterdeployment -n hive && echo '---' && \
  oc get clusterprovision -n hive"
```

---

## Étape 6 — Surveillance du provisioning

```bash
# État du ClusterDeployment
oc get clusterdeployment okd-sno-spoke -n hive -o yaml \
  | grep -A 10 "status:"

# Logs du pod hive-install-manager (créé automatiquement)
oc logs -n hive \
  $(oc get pods -n hive | grep install | awk '{print $1}') \
  -f 2>/dev/null
```

### Screenshot 3 — ClusterDeployment Installed

> 📸 `docs/screenshots/phase2-clusterdeployment-installed.png`
> *À compléter après provisioning (~45 min)*

---

## Étape 7 — Récupération du kubeconfig

```bash
# Récupère le kubeconfig du spoke
oc extract secret/$(oc get cd okd-sno-spoke -n hive \
  -o jsonpath='{.status.adminKubeconfigSecretRef.name}') \
  -n hive --to=/tmp/spoke-kubeconfig --confirm

# Teste la connexion au spoke
export KUBECONFIG=/tmp/spoke-kubeconfig/kubeconfig
oc get nodes
oc get clusterversion
```

---

## Étape 8 — Destroy après validation

```bash
# Destroy le spoke (efface tout sur Azure)
oc delete clusterdeployment okd-sno-spoke -n hive

# Surveille le deprovision
watch oc get clusterdeprovision -n hive

# Destroy l'infra Terraform après session
cd terraform/
terraform destroy
```

---

## Issues rencontrées et fixes

| # | Problème | Cause | Fix |
|---|---------|-------|-----|
| 1 | SP client secret invalide | Secret ID exporté au lieu de la valeur | `az ad sp credential reset` |

---

## Coût de la session

```
VM Standard_D8s_v3 ON-DEMAND  ~3h  : ~$1.15
Disque 128GB SSD               prorata : ~$0.05
Load Balancer + IP publique    ~3h  : ~$0.20
DNS zone                       prorata : ~$0.01
─────────────────────────────────────────────
Total session ~3h                    : ~$1.50 ✅
```

> **Règle** : Toujours `oc delete clusterdeployment` + `terraform destroy`
> après la session de validation → coût résiduel = $0

---

## Prochaine étape

➡️ [Phase 3 — SyncSets Day-2](phase3-syncsets.md)

Application automatique de policies Kyverno, RBAC et OAuth config
sur le cluster spoke via Hive SyncSets.
