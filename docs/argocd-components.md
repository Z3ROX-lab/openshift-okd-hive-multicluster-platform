# ArgoCD Components — Architecture & SSO Flow

## Vue d'ensemble des composants ArgoCD
```
┌─────────────────────────────────────────────────────┐
│                    ArgoCD                           │
│                                                     │
│  ┌──────────────────┐                               │
│  │  argocd-server   │  ← UI web + API REST          │
│  └──────────────────┘                               │
│                                                     │
│  ┌──────────────────┐                               │
│  │  app-controller  │  ← reconcile loop             │
│  │                  │    compare Git ↔ cluster      │
│  └──────────────────┘                               │
│                                                     │
│  ┌──────────────────┐                               │
│  │  repo-server     │  ← clone les repos Git        │
│  │                  │    génère les manifests        │
│  │                  │    (Helm, Kustomize, YAML)     │
│  │  HTTPS_PROXY ✅  │    accès internet via          │
│  └──────────────────┘    tinyproxy (10.128.0.2:8888)│
│                                                     │
│  ┌──────────────────┐                               │
│  │  applicationset  │  ← génère des Applications    │
│  │  controller      │    depuis des templates       │
│  └──────────────────┘                               │
│                                                     │
│  ┌──────────────────┐                               │
│  │  redis           │  ← cache interne ArgoCD       │
│  └──────────────────┘                               │
│                                                     │
│  ┌──────────────────┐                               │
│  │  dex             │  ← broker OIDC                │
│  │                  │    SSO entre ArgoCD            │
│  │                  │    et Keycloak                 │
│  └──────────────────┘                               │
└─────────────────────────────────────────────────────┘
```

---

## repo-server — Egress via tinyproxy

Le `repo-server` est le seul composant ArgoCD qui a besoin d'accéder à internet
pour cloner les repos Git (GitHub, GitLab...).

Dans ce cluster airgap, l'accès est fourni via tinyproxy :
```
repo-server
└── HTTPS_PROXY=http://10.128.0.2:8888
     └── tinyproxy (pod OKD node 10.128.0.2)
          └── egress vers github.com ✅
```

Configuration appliquée sur le déploiement ArgoCD :
```yaml
env:
  - name: HTTPS_PROXY
    value: http://10.128.0.2:8888
  - name: HTTP_PROXY
    value: http://10.128.0.2:8888
  - name: NO_PROXY
    value: localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,kubernetes.default.svc,.cluster.local
```

---

## Dex — Broker OIDC

### Rôle

Dex est un broker OIDC qui s'intercale entre ArgoCD et Keycloak.
Il permet à ArgoCD de déléguer l'authentification à n'importe quel
Identity Provider (IdP) sans modification du code ArgoCD.

### Sans Dex vs Avec Dex
```
Sans Dex :
  ArgoCD UI → login → ArgoCD gère les users locaux
              (stockés dans un Secret Kubernetes)

Avec Dex :
  ArgoCD UI → login → Dex → Keycloak → SSO ✅
                       │
                       └── broker OIDC
                           traduit les protocoles
                           entre ArgoCD et Keycloak
```

### Flow d'authentification complet
```
Navigateur          ArgoCD          Dex              Keycloak
──────────          ──────          ───              ────────
    │                  │              │                  │
    │── GET /argocd ──►│              │                  │
    │                  │              │                  │
    │◄─ redirect ──────│              │                  │
    │                  │              │                  │
    │── GET /dex ──────────────────►│                   │
    │                  │              │                  │
    │                  │              │── redirect ─────►│
    │                  │              │                  │
    │◄──────────────────────────────── login page ───────│
    │                  │              │                  │
    │── credentials ────────────────────────────────────►│
    │                  │              │                  │
    │◄─────────────────────────────── code OAuth ────────│
    │                  │              │                  │
    │── code ──────────────────────►│                   │
    │                  │              │── valide code ──►│
    │                  │              │◄─ token ─────────│
    │                  │              │                  │
    │                  │◄─ token Dex ─│                  │
    │◄─ 200 ArgoCD ────│              │                  │
    │   ✅ Connecté    │              │                  │
```

### Dex vs OIDC direct

| | **Via Dex (actuel)** | **OIDC direct** |
|---|---|---|
| IdPs supportés | Multiple (Keycloak, GitHub, LDAP...) | 1 seul |
| Complexité | Plus élevée | Simple |
| Composants | 1 pod supplémentaire | Aucun |
| Cas d'usage | Enterprise multi-IdP | Setup simple |

---

## Importance pour le pattern Hub and Spoke
```
Hub OKD SNO
└── Keycloak (IdP central)
     │
     ├── ArgoCD hub  (via Dex) ✅
     │
     └── ArgoCD spokes (via Dex ou OIDC direct)
          ├── Spoke 1 OKD Azure
          └── Spoke 2 OKD Azure

Pattern enterprise :
  1 Keycloak hub = source de vérité SSO
  N clusters spokes = tous authentifiés au même endroit ✅
  → cohérence IAM sur tous les clusters
  → révocation centralisée
  → audit centralisé
```

---

## État dans ce cluster
```
Pod                              Status    Restarts  Notes
───────────────────────────────  ────────  ────────  ─────
argocd-server                    Running   4         UI + API
argocd-application-controller    Running   0         Reconcile loop
argocd-repo-server               Running   0         Git clone + proxy ✅
argocd-applicationset-controller Running   0         ApplicationSet
argocd-redis                     Running   0         Cache
argocd-dex-server                Running   1         OIDC broker → Keycloak
```

---

## Références

- [ArgoCD Architecture](https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/)
- [Dex OIDC](https://dexidp.io/docs/)
- [Keycloak OIDC](https://www.keycloak.org/docs/latest/securing_apps/)
