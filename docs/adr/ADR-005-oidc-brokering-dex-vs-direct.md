# ADR-005 — OIDC Brokering : Dex vs Direct OIDC

| | |
|---|---|
| **Statut** | Accepted |
| **Date** | 2026-03-31 |
| **Auteur** | Stéphane Seloi (Z3ROX) |
| **Projets** | Tous les projets Z3ROX-lab |

---

## Contexte

Une fois Keycloak choisi comme IAM (voir ADR-004), il faut décider comment
les applications et les clusters consomment les identités Keycloak.
Plusieurs approches existent : OIDC direct, broker Dex, ou proxy OAuth2.

---

## 1. Dex n'est pas un IAM

```
KEYCLOAK = IAM complet (source de vérité)
─────────────────────────────────────────
✅ Gère les users, passwords, groupes
✅ MFA / audit / fédération LDAP
✅ UI admin complète
✅ OIDC + OAuth2 + SAML

DEX = Broker OIDC uniquement (traducteur)
──────────────────────────────────────────
❌ Ne gère PAS les users
❌ Pas de passwords / MFA propre
❌ Pas de console admin utilisateur
✅ Traduit des tokens OIDC entre formats
✅ Connecte plusieurs IdPs vers une app
✅ Très léger (~50MB)

ANALOGIE :
  Keycloak = Mairie (émet les cartes d'identité)
  Dex      = Traducteur / Interprète
             (traduit la carte dans le format
              compris par l'ambassade/app cible)
  App/K8s  = Ambassade (consomme l'identité)
```

---

## 2. Positionnement dans l'écosystème

```
TIER 1 — Sources de vérité (IAM complets)
──────────────────────────────────────────
Keycloak            ← notre choix (ADR-004)
Microsoft Entra ID
Okta / Auth0
AWS Cognito
PingFederate

TIER 2 — Brokers OIDC (adaptateurs)
─────────────────────────────────────
Dex                 ← notre broker ArgoCD
Pinniped            ← broker Kubernetes (VMware/Broadcom)
OAuth2 Proxy        ← proxy générique

TIER 3 — Clients OIDC (consommateurs)
──────────────────────────────────────
ArgoCD              ← utilise Dex comme broker
Kubernetes          ← consomme OIDC directement
Grafana             ← client OIDC direct
OKD                 ← OAuth server intégré
```

---

## 3. Options évaluées

### Option A — Dex comme broker (retenu pour ArgoCD ✅)

```
Keycloak → Dex → Application

Avantages :
  ✅ Supporte plusieurs IdPs simultanément
     (Keycloak + GitHub + LDAP → 1 endpoint OIDC)
  ✅ Traduit les formats de tokens
  ✅ ArgoCD Community Operator intègre Dex nativement
  ✅ Découplage : app ne connaît que Dex

Inconvénients :
  ❌ Composant supplémentaire à gérer
  ❌ Point de défaillance supplémentaire
  ❌ Complexité réseau accrue
```

### Option B — OIDC direct (retenu pour OKD + Grafana ✅)

```
Keycloak → Application (directement)

Avantages :
  ✅ Plus simple, moins de composants
  ✅ Moins de latence (1 hop au lieu de 2)
  ✅ OKD supporte OIDC natif via identityProviders

Inconvénients :
  ❌ 1 seul IdP par configuration
  ❌ App doit supporter OIDC directement
  ❌ Pas compatible tous les clients
```

### Option C — kubelogin / kubectl-oidc-login

```
Keycloak → kubelogin → kubectl → Kubernetes

Avantages :
  ✅ Fonctionne sur clusters managés (EKS, AKS, GKE)
  ✅ Pas de modification kube-apiserver
  ✅ Flow navigateur pour l'utilisateur

Inconvénients :
  ❌ Plugin à installer sur chaque poste
  ❌ Pas adapté aux clusters self-managed
```

### Option D — OAuth2 Proxy

```
Keycloak → OAuth2 Proxy → Application

Avantages :
  ✅ Protège des apps sans support OIDC natif
  ✅ Générique

Inconvénients :
  ❌ Composant supplémentaire
  ❌ Pas de mapping RBAC Kubernetes natif
```

---

## 4. Comparaison

| | **Dex** | **OIDC direct** | **kubelogin** | **OAuth2 Proxy** |
|---|---|---|---|---|
| Complexité | Moyenne | Faible ✅ | Faible ✅ | Moyenne |
| Multi-IdP | ✅ | ❌ | ❌ | ❌ |
| Clusters managés | ✅ | ❌ | ✅ | ✅ |
| ArgoCD natif | ✅ | ❌ | ❌ | ❌ |
| OKD natif | Via ArgoCD | ✅ | N/A | ❌ |
| Kubernetes vanilla | ✅ | ✅ (flags) | ✅ | ✅ |
| Composants | +1 pod | 0 ✅ | +plugin | +1 pod |

---

## 5. Flow détaillé — Dex dans ArgoCD

```
Navigateur       ArgoCD          Dex              Keycloak
──────────       ──────          ───              ────────
    │               │              │                  │
    │─ GET /argocd ►│              │                  │
    │               │              │                  │
    │◄─ redirect ───│              │                  │
    │               │              │                  │
    │─ GET /dex ────────────────► │                  │
    │               │              │                  │
    │               │              │─ redirect ──────►│
    │               │              │                  │
    │◄──────────────────────────── login page ────────│
    │               │              │                  │
    │─ credentials ─────────────────────────────────►│
    │               │              │                  │
    │◄──────────────────────────── code OAuth ────────│
    │               │              │                  │
    │─ code ───────────────────── ►│                  │
    │               │              │─ valide code ───►│
    │               │              │◄─ token KC ──────│
    │               │              │                  │
    │               │◄─ token Dex ─│                  │
    │               │  (traduit)   │                  │
    │◄─ 200 ArgoCD ─│              │                  │
    │  ✅ Connecté  │              │                  │
```

---

## 6. Flow détaillé — OIDC direct sur OKD

```
Navigateur       OKD OAuth        Keycloak
──────────       ─────────        ────────
    │               │                 │
    │─ GET console ►│                 │
    │               │                 │
    │◄─ redirect ───│                 │
    │               │                 │
    │─ GET /auth ───────────────────►│
    │               │                 │
    │◄────────────── login page ──────│
    │               │                 │
    │─ credentials ─────────────────►│
    │               │                 │
    │◄────────────── code OAuth ──────│
    │               │                 │
    │─ callback ────►│                 │
    │               │─ valide code ──►│
    │               │◄─ token KC ─────│
    │               │                 │
    │               │ extrait claims: │
    │               │  groups: [cluster-admins]
    │               │  username: stephane
    │               │                 │
    │               │ crée OKD Group  │
    │               │ "cluster-admins"│
    │               │ (auto) ✅       │
    │◄─ 200 console ─│                 │
    │  ✅ Connecté  │                 │
```

---

## 7. Mapping des claims → RBAC

### OKD (Groups automatiques)

```
Keycloak token                OKD config                    OKD RBAC
──────────────                ──────────                    ────────
{                             spec:                         kind: ClusterRoleBinding
  "groups": [                   identityProviders:          subjects:
    "cluster-admins",           - openID:                   - kind: Group
    "developers"                    claims:                   name: cluster-admins
  ]                                   groups: [groups]  ──►roleRef:
}                                                             name: cluster-admin

→ OKD crée automatiquement
  le Group "cluster-admins" ✅
  à la première connexion
```

### Kubernetes vanilla (Groups manuels)

```
Keycloak token           kube-apiserver flags        K8s RBAC
──────────────           ────────────────────        ────────
{                        --oidc-issuer-url=...       kind: ClusterRoleBinding
  "groups": [            --oidc-groups-claim=groups  subjects:
    "cluster-admins"     --oidc-username-claim=email - kind: Group
  ]                                                    name: cluster-admins
}                                             ──────►roleRef:
                                                        name: cluster-admin

⚠️ Le Group "cluster-admins" doit être
   créé MANUELLEMENT avant le ClusterRoleBinding
   (contrairement à OKD qui le crée auto)
```

### ArgoCD RBAC (niveau applicatif)

```
Keycloak groups      Dex (passthrough)      ArgoCD RBAC (policy.csv)
───────────────      ─────────────────      ────────────────────────
groups:              groups passés           g, cluster-admins, role:admin
  cluster-admins  ──►tels quels ──────────► g, developers, role:readonly
  developers

→ "cluster-admins" Keycloak = admin ArgoCD ✅
→ "developers" Keycloak = read-only ArgoCD ✅

⚠️ ArgoCD RBAC ≠ Kubernetes RBAC
   Deux niveaux indépendants :

   NIVEAU 1 — ArgoCD RBAC (qui peut déployer dans ArgoCD)
   NIVEAU 2 — Kubernetes RBAC (qui peut faire quoi sur le cluster)

   Tu peux être admin ArgoCD sans être admin cluster ✅
```

---

## 8. Notre architecture — décisions par composant

```
Composant          Méthode           Justification
─────────          ───────           ─────────────
OKD Hub console    OIDC direct ✅    OKD supporte nativement
OKD Spoke console  OIDC direct ✅    Via SyncSet oauth-config
ArgoCD             Dex ✅            Operator intègre Dex nativement
Grafana            OIDC direct ✅    Grafana supporte OIDC natif
Vault              OIDC direct ✅    Vault supporte OIDC natif
kubectl (dev)      kubelogin ⚠️     Option pour developers
```

---

## 9. Décision

**Approche hybride retenue** :

```
Dex         → ArgoCD uniquement
              (car ArgoCD Community Operator
               intègre Dex nativement et ne
               supporte pas OIDC direct)

OIDC direct → OKD consoles (hub + spokes)
              Grafana, Vault
              (car ces apps supportent OIDC
               nativement sans broker)

kubelogin   → Non retenu pour ce projet
              (clusters self-managed, pas de
               clusters managés EKS/AKS/GKE)
```

---

## 10. Conséquences

### Positives
- Dex limité à ArgoCD → complexité minimale ✅
- OIDC direct pour OKD → moins de composants ✅
- Architecture cohérente avec Red Hat (Keycloak + OKD) ✅
- Applicable en mission enterprise (même pattern ACM) ✅

### Négatives / Contraintes
- Dex pod supplémentaire sur le hub (~50MB RAM)
- 2 configurations OIDC différentes (Dex + OIDC direct)
- Si ArgoCD migre vers OIDC direct → Dex devient inutile

---

## Références

- [Dex GitHub](https://github.com/dexidp/dex)
- [ArgoCD Dex Integration](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/)
- [OKD OIDC Identity Provider](https://docs.okd.io/latest/authentication/identity_providers/configuring-oidc-identity-provider.html)
- [kubelogin](https://github.com/int128/kubelogin)
- [Pinniped](https://pinniped.dev/)
- [ADR-004 — IAM Strategy: Keycloak](ADR-004-iam-strategy-keycloak.md)
- [ArgoCD Components Architecture](../argocd-components.md)
