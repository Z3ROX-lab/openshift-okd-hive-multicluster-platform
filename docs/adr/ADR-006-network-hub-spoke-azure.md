# ADR-006 — Network Architecture : Hub Homelab → Spoke Azure

| | |
|---|---|
| **Statut** | Accepted |
| **Date** | 2026-04-01 |
| **Auteur** | Stéphane Seloi (Z3ROX) |
| **Projets** | openshift-okd-hive-multicluster-platform |
| **Référence** | ADR-001 okd-hypershift-security-platform (problème LB Azure) |

---

## Contexte

Le hub OKD SNO tourne sur un homelab (GEEKOM A6, VMware Workstation, IP privée
`192.168.241.10`). Les clusters spokes sont provisionnés sur Azure (IP publiques).
Ce document analyse les flux réseau entre hub et spokes, et explique pourquoi
l'architecture Hive SNO n'a pas le problème de Load Balancer rencontré sur HyperShift.

---

## 1. Le problème HyperShift (rappel ADR-001)

```
HYPERSHIFT — flux réseau problématique
────────────────────────────────────────

HUB homelab (192.168.241.10)
└── Hosted Control Plane (pods)
     ├── kube-apiserver   ← CP tourne ICI sur le hub
     ├── etcd
     └── kube-controller

         │
         │ Workers Azure doivent joindre le CP
         │ via un Load Balancer
         ▼

Azure Load Balancer PUBLIC
└── tente de router vers 192.168.241.10 ❌
     └── BLOQUÉ : Azure LB public ne peut pas
          router vers une IP privée homelab
          non accessible depuis internet

→ Solution HyperShift : Tailscale Funnel (Phase 6)
  ou exposer le CP homelab via IP publique
```

---

## 2. Pourquoi Hive SNO n'a pas ce problème

```
HIVE SNO SPOKE — flux réseau
──────────────────────────────

HUB homelab (192.168.241.10)
└── hive-controllers pod
     └── hive-install-manager pod (éphémère)
          │
          │ SORTANT uniquement
          │ hub → Azure (pas l'inverse !)
          ▼

Azure API (management.azure.com)
└── crée les ressources Azure :
     ├── Resource Group
     ├── VNet / Subnet / NSG
     ├── Load Balancer public
     └── VM master (Standard_D8s_v3)
          │
          ▼
     OKD SNO spoke
     └── API server exposé via Azure LB public
          └── hub peut le joindre ✅
              (hub → internet → Azure LB → spoke API)
```

---

## 3. Comparaison des flux réseau

```
                    HYPERSHIFT           HIVE SNO SPOKE
                    ──────────           ──────────────

Direction prob.     Azure → Homelab ❌   Homelab → Azure ✅
                    (workers → CP hub)   (hub → spoke API)

Load Balancer       LB Azure → IP        LB Azure → VM Azure
                    privée homelab       (tout sur Azure) ✅
                    ❌ BLOQUÉ

Hub expose          CP sur homelab ❌    Rien — hub est
quelque chose ?     (problématique)      juste orchestrateur ✅

Spoke autonome ?    ❌ Non               ✅ Oui
                    (CP sur hub)         (CP sur Azure VMs)

Solution            Tailscale Funnel     Pas nécessaire ✅
réseau requise      (Phase 6 HyperShift)
```

---

## 4. Flux réseau complets — Hive IPI SNO

```
PHASE PROVISIONING (~45 min)
──────────────────────────────

hub:hive-install-manager
  │
  ├──► quay.io (release images)
  │    via tinyproxy (10.128.0.2:8888) ✅
  │
  ├──► management.azure.com (Azure API)
  │    via tinyproxy ✅
  │    → crée VM, VNet, NSG, LB, DNS
  │
  └──► spoke API LB (après install)
       via internet public ✅
       → vérifie que le cluster est prêt


PHASE OPÉRATIONNELLE (Day-2)
──────────────────────────────

hub:hive-clustersync
  │
  └──► spoke API LB (internet public) ✅
       → applique les SyncSets

hub:hive-controllers
  │
  └──► spoke API LB (internet public) ✅
       → réconcilie ClusterDeployment status

hub:argocd-application-controller
  │
  └──► spoke API LB (internet public) ✅
       → déploie les apps via ApplicationSet


SPOKE SNO AZURE (autonome)
───────────────────────────

spoke VM azure
  │
  ├──► quay.io (images containers)
  │    via Azure NAT Gateway / LB sortant ✅
  │
  ├──► hub:keycloak (SSO)
  │    via internet public ✅
  │    (keycloak.apps.sno.okd.lab)
  │
  └──► aucune connexion vers hub API requise ✅
       (spoke est autonome !)
```

---

## 5. Configuration réseau Azure créée par Hive IPI

```
Hive IPI crée automatiquement :

VNet: 10.0.0.0/16
└── Subnet masters: 10.0.0.0/24
     └── VM master (Standard_D8s_v3)
          ├── NIC privée : 10.0.0.x
          └── NSG rules :
               ├── Inbound 6443 (API server) ← via LB
               ├── Inbound 443 (Ingress)     ← via LB
               └── Inbound 22 (SSH)          ← optionnel

Load Balancer public
├── Frontend IP : IP publique Azure
├── Backend     : VM master
└── Rules :
     ├── 6443 → API server ✅
     └── 443  → Ingress ✅

DNS records (dans hive.okd.lab zone) :
├── api.spoke-1.hive.okd.lab    → LB IP publique
└── *.apps.spoke-1.hive.okd.lab → LB IP publique
```

---

## 6. Sécurité — surface d'attaque

```
EXPOSÉ sur internet (nécessaire) :
  ├── API server :6443   ← hub doit joindre le spoke
  └── Ingress :443/:80   ← apps du spoke

NON exposé :
  ├── etcd :2379/:2380   ← interne au spoke uniquement
  ├── Kubelet :10250     ← interne au spoke
  └── SSH :22            ← optionnel, désactivé en prod

RECOMMANDATIONS SecOps :
  ├── Restreindre :6443 aux IPs du hub uniquement
  │    NSG rule : allow 6443 from <hub-public-ip>
  ├── Certificate rotation automatique (cert-manager)
  └── NetworkPolicies via SyncSets (Phase 3)
```

---

## 7. Cas particulier — hub derrière NAT

```
Hub homelab → internet via box Orange/SFR
└── IP publique dynamique (CGNAT possible)

Risque :
  Azure NSG pourrait bloquer le hub si on
  restreint :6443 à une IP fixe

Solution pour homelab :
  → Laisser :6443 ouvert (0.0.0.0/0)
  → Protéger via mTLS (certificats OKD) ✅
  → En production : VPN / ExpressRoute
```

---

## 8. Décision

**Architecture Hive SNO retenue sans modification réseau** car :

```
1. Flux hub → Azure (sortant) ✅
   Pas de problème de routage Azure → homelab

2. Spoke 100% autonome sur Azure ✅
   CP sur Azure VMs, pas dépendant du hub

3. Tinyproxy suffit pour l'egress du hub ✅
   Déjà validé pour ArgoCD repo-server

4. Pas de Tailscale requis pour le provisioning ✅
   Contrairement à HyperShift (ADR-001 companion)
```

---

## 9. Conséquences

### Positives
- Pas de configuration réseau supplémentaire ✅
- Tinyproxy existant couvre tous les besoins egress ✅
- Spoke autonome — survit si hub homelab s'éteint ✅
- Architecture plus simple que HyperShift ✅

### Négatives / Contraintes
- API server spoke exposé sur internet (port 6443)
  → mitigation : NSG + mTLS OKD certificates
- IP publique homelab dynamique → pas de NSG strict
  → acceptable pour homelab portfolio
- Keycloak hub doit être accessible depuis Azure
  → via Route OKD publique (déjà le cas) ✅

---

## Références

- [ADR-001 — Hive vs HyperShift](ADR-001-hive-vs-hypershift.md)
- [ADR-001 HyperShift — Azure LB problem](https://github.com/Z3ROX-lab/okd-hypershift-security-platform/docs/adr/ADR-001-azure-lb-routing.md)
- [OKD IPI Azure networking](https://docs.okd.io/latest/installing/installing_azure/ipi/installing-azure-default.html)
- [Azure NSG documentation](https://docs.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview)
