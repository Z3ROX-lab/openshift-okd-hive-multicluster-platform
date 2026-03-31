# ADR-004 — IAM Strategy : Keycloak as Central Identity Provider

| | |
|---|---|
| **Statut** | Accepted |
| **Date** | 2026-03-31 |
| **Auteur** | Stéphane Seloi (Z3ROX) |
| **Projets** | Tous les projets Z3ROX-lab |

---

## Contexte

Dans une architecture multi-cluster hub and spoke, l'identité des utilisateurs
doit être gérée de façon centralisée. Ce document justifie le choix de Keycloak
comme IAM central et documente le pattern de mapping vers les RBAC Kubernetes/OKD.

---

## 1. Qu'est-ce qu'un IAM ?

```
IAM = Identity and Access Management

SOURCE DE VÉRITÉ des identités :
  ├── Gère les users (CRUD)
  ├── Gère les passwords + MFA
  ├── Gère les groupes et rôles
  ├── Audit logs des connexions
  ├── Fédération LDAP/AD
  ├── Social login (Google, GitHub...)
  └── Protocoles : OIDC + OAuth2 + SAML

≠ Broker OIDC (Dex, Pinniped)
  → qui traduit les tokens sans gérer les identités
  → voir ADR-005
```

---

## 2. Options évaluées

### Option A — Keycloak (retenu ✅)

```
Type        : IAM open source (Red Hat)
Protocoles  : OIDC + OAuth2 + SAML
Hébergement : On-premise / self-hosted
Licence     : Apache 2.0 ✅
Souveraineté: Données en France ✅
Intégration : Native OKD identityProviders
```

### Option B — Microsoft Entra ID (Azure AD)

```
Type        : IAM SaaS Microsoft
Protocoles  : OIDC + OAuth2 + SAML
Hébergement : Azure Cloud (US jurisdiction) ⚠️
Licence     : Payant (P1/P2)
Souveraineté: Données hors France ⚠️
Intégration : Via OIDC ou Dex
```

### Option C — Okta

```
Type        : IAM SaaS
Protocoles  : OIDC + OAuth2 + SAML
Hébergement : Cloud US ⚠️
Licence     : Payant
Souveraineté: Données hors France ⚠️
```

### Option D — AWS Cognito

```
Type        : IAM SaaS AWS
Protocoles  : OIDC + OAuth2
Hébergement : AWS Cloud
Licence     : Pay-per-use
Souveraineté: Données hors France ⚠️
Couplage    : AWS uniquement ❌
```

---

## 3. Comparaison

| | **Keycloak** | **Entra ID** | **Okta** | **Cognito** |
|---|---|---|---|---|
| Open source | ✅ | ❌ | ❌ | ❌ |
| Self-hosted | ✅ | ❌ | ❌ | ❌ |
| Souveraineté FR | ✅ | ⚠️ | ⚠️ | ⚠️ |
| RGPD natif | ✅ | ⚠️ SCC | ⚠️ | ⚠️ |
| Coût | Gratuit ✅ | $$ | $$$ | Pay/use |
| OKD natif | ✅ | Via OIDC | Via OIDC | Via OIDC |
| SAML | ✅ | ✅ | ✅ | ❌ |
| Multi-cluster | ✅ | ✅ | ✅ | ❌ |
| Enterprise support | Red Hat ✅ | Microsoft | Okta | AWS |

---

## 4. Pattern Hub Centralisé retenu

```
┌─────────────────────────────────────────────────────────┐
│  HUB — OKD SNO                                          │
│                                                         │
│  Keycloak (IAM central)                                 │
│  └── realm: okd                                         │
│       ├── users: stephane, admin, dev                   │
│       ├── groups:                                       │
│       │    ├── cluster-admins                           │
│       │    ├── developers                               │
│       │    └── viewers                                  │
│       └── clients:                                      │
│            ├── openshift (OKD hub)                      │
│            ├── argocd-dex                               │
│            ├── spoke-1                                  │
│            └── spoke-2                                  │
└──────────────────────┬──────────────────────────────────┘
                       │ OIDC
          ┌────────────┼──────────────────┐
          │            │                  │
          ▼            ▼                  ▼
   ┌──────────┐  ┌──────────┐      ┌──────────┐
   │  OKD Hub │  │ ArgoCD   │      │  Spoke N │
   │  Console │  │  (Dex)   │      │  Console │
   └──────────┘  └──────────┘      └──────────┘

Source de vérité unique ✅
Révocation centralisée ✅
Audit centralisé ✅
```

### Alternatives au hub centralisé

```
Option A — Hub centralisé (notre choix)
  1 Keycloak → N clusters
  + Simple à gérer
  + Révocation immédiate sur tous les clusters
  - Spoke dépend du hub pour SSO
  - Si hub OFF → login impossible sur spokes

Option B — Keycloak par spoke
  N Keycloak → N clusters
  + Résilience totale ✅
  + Spoke autonome
  - N fois plus de maintenance
  - Synchronisation des users complexe

Option C — Fédération Keycloak
  Keycloak hub → fédère N Keycloak spokes
  + Résilience + centralisation
  - Très complexe
  - Sur-ingénierie pour homelab
```

---

## 5. Mapping Keycloak → RBAC

### Sur OKD/OpenShift

```
ÉTAPE 1 — Keycloak émet un token JWT
  {
    "sub": "stephane",
    "preferred_username": "stephane",
    "email": "stephane@okd.lab",
    "groups": ["cluster-admins", "developers"]
  }

ÉTAPE 2 — OKD OAuth extrait les claims
  spec:
    identityProviders:
    - openID:
        claims:
          groups: [groups]              ← claim Keycloak
          preferredUsername: [preferred_username]
          email: [email]

ÉTAPE 3 — OKD crée automatiquement les Groups
  Group "cluster-admins" ← créé à la 1ère connexion
  Group "developers"     ← créé à la 1ère connexion

ÉTAPE 4 — ClusterRoleBinding mappe Group → ClusterRole
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: keycloak-cluster-admins
  subjects:
  - kind: Group
    name: cluster-admins     ← groupe OKD (= groupe Keycloak)
    apiGroup: rbac.authorization.k8s.io
  roleRef:
    kind: ClusterRole
    name: cluster-admin
```

### Sur Kubernetes vanilla

```
Différence clé : pas de Groups auto → création manuelle requise

ÉTAPE 1 — kube-apiserver configuré OIDC
  --oidc-issuer-url=https://keycloak.okd.lab/realms/okd
  --oidc-groups-claim=groups
  --oidc-username-claim=preferred_username

ÉTAPE 2 — User se connecte via kubelogin
  kubectl oidc-login get-token \
    --oidc-issuer-url=...
    --oidc-client-id=kubernetes

ÉTAPE 3 — Groups doivent exister AVANT le ClusterRoleBinding
  ← OKD les crée auto ✅
  ← Kubernetes vanilla : à créer manuellement ❌

ÉTAPE 4 — ClusterRoleBinding identique à OKD ✅
```

### Tableau comparatif OKD vs Kubernetes vanilla

| | **OKD/OpenShift** | **Kubernetes vanilla** |
|---|---|---|
| OAuth server | Intégré ✅ | Externe requis |
| Keycloak support | Natif ✅ | Via OIDC flags |
| Groups auto | ✅ à la 1ère connexion | ❌ manuel |
| Console web | ✅ intégrée | Dashboard séparé |
| Clusters managés | N/A | kubelogin requis |

---

## 6. Keycloak dans le contexte NIS2 / RGPD

```
NIS2 exige :
  ✅ MFA pour les accès privilégiés
     → Keycloak OTP / WebAuthn natif

  ✅ Audit des connexions
     → Keycloak event logging
     → export vers SIEM (Splunk, Loki)

  ✅ Révocation immédiate des accès
     → Keycloak : désactiver user → révocation immédiate
     → sur tous les clusters via hub centralisé

  ✅ Principe du moindre privilège
     → Keycloak groups → ClusterRoles granulaires
     → namespace-scoped RoleBindings

RGPD :
  ✅ Données hébergées en France (homelab)
  ✅ Pas de transfert hors UE
  ✅ Droit à l'effacement : suppression user Keycloak
     → accès révoqué immédiatement
```

---

## 7. Décision

**Keycloak est retenu comme IAM central** pour :

```
1. Open source + Red Hat support enterprise ✅
2. Souveraineté française (self-hosted) ✅
3. Intégration native OKD identityProviders ✅
4. Conformité NIS2/RGPD native ✅
5. Coût zéro (vs Okta/Entra ID) ✅
6. Support OIDC + SAML + OAuth2 ✅
7. Pattern hub centralisé = 1 seule source de vérité ✅
```

---

## 8. Conséquences

### Positives
- SSO unifié sur tous les clusters (hub + spokes)
- Révocation centralisée et immédiate
- Audit centralisé via Keycloak event logs
- Compatible missions enterprise (Keycloak = Red Hat = OpenShift)

### Négatives / Contraintes
- Keycloak devient un SPOF pour l'authentification
  → mitigation : PVC persistant + backup realm export
- Spokes dépendent du hub pour le login initial
  → mitigation : tokens de longue durée si hub temporairement OFF

---

## Références

- [Keycloak Documentation](https://www.keycloak.org/docs/)
- [OKD Identity Providers](https://docs.okd.io/latest/authentication/identity_providers/configuring-oidc-identity-provider.html)
- [NIS2 Directive](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32022L2555)
- [ADR-005 — OIDC Brokering: Dex vs Direct OIDC](ADR-005-oidc-brokering-dex-vs-direct.md)
- [ArgoCD Components Architecture](../argocd-components.md)
