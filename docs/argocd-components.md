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

### Flow d'authentification ArgoCD complet
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

## Comment ArgoCD cible un spoke spécifique

### Le concept — destination cluster

Chaque ArgoCD Application a un champ `destination` qui indique
sur quel cluster déployer :
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mon-app
  namespace: openshift-operators
spec:
  source:
    repoURL: https://github.com/Z3ROX-lab/...
    path: manifests/mon-app
  destination:
    server: https://api.spoke-1.azure.okd.lab:6443  # ← spoke 1
    namespace: mon-namespace
```

### Le label magique — cluster secret

Hive provisionne un spoke et crée automatiquement un Secret kubeconfig.
ArgoCD détecte ce Secret grâce au label :
```yaml
metadata:
  labels:
    argocd.argoproj.io/secret-type: cluster  # ← ArgoCD enregistre ce cluster
```
```
Hive provisionne spoke-1
└── crée Secret kubeconfig-spoke-1
     └── label: argocd.argoproj.io/secret-type: cluster
          │
          ▼
     ArgoCD détecte → enregistre spoke-1 comme cluster cible
          │
          ▼
     ApplicationSet generator: clusters
     └── génère automatiquement une App par spoke ✅
```

### ApplicationSet cluster generator
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: deploy-sur-tous-les-spokes
spec:
  generators:
  - clusters:
      selector:
        matchLabels:
          spoke: "true"          # ← sélectionne les spokes
  template:
    spec:
      destination:
        server: "{{server}}"     # ← injecté automatiquement
        namespace: mon-app
      source:
        repoURL: https://github.com/Z3ROX-lab/...
        path: manifests/mon-app
```

---

## SSO sur les spokes — comment un user se connecte

### Pattern retenu — Keycloak Hub centralisé + SyncSets
```
┌─────────────────────────────────────────────────────────┐
│  HUB — OKD SNO                                          │
│                                                         │
│  Keycloak                    Hive                       │
│  └── realm: okd              └── SyncSet oauth-config   │
│       ├── user: admin             └── pousse sur        │
│       ├── user: dev                   chaque spoke :    │
│       └── groups:                     OAuth CR +        │
│            ├── cluster-admins         IDP Keycloak hub  │
│            └── developers             + CA cert         │
└──────────────┬──────────────────────────────────────────┘
               │ Tailscale (mTLS)
               │
    ┌──────────┴──────────┐
    │                     │
    ▼                     ▼
┌──────────────┐    ┌──────────────┐
│   SPOKE 1    │    │   SPOKE 2    │
│              │    │              │
│  OAuth CR    │    │  OAuth CR    │
│  └─ IDP:     │    │  └─ IDP:     │
│   Keycloak   │    │   Keycloak   │
│   hub ✅     │    │   hub ✅     │
│              │    │              │
│  User login  │    │  User login  │
│      │       │    │      │       │
└──────┼───────┘    └──────┼───────┘
       │                   │
       └─────────┬─────────┘
                 │ OAuth redirect
                 ▼
        Keycloak HUB ✅
        realm: okd
        (source de vérité unique)
```

### Flow utilisateur complet
```
User                Spoke Console        Keycloak HUB
────                ─────────────        ────────────
 │                       │                    │
 │── GET /console ───────►│                   │
 │                        │                   │
 │◄─ redirect OAuth ──────│                   │
 │                        │                   │
 │── GET /auth ───────────────────────────────►│
 │                        │                   │
 │◄───────────────────────────── login page ───│
 │                        │                   │
 │── admin / password ────────────────────────►│
 │                        │                   │
 │◄───────────────────────────── code OAuth ───│
 │                        │                   │
 │── callback?code ───────►│                  │
 │                        │── valide code ────►│
 │                        │◄─ token ───────────│
 │                        │                   │
 │◄─ 200 Console ─────────│                   │
 │   ✅ Connecté sur spoke │                   │
```

### 3 patterns SSO spokes comparés

| | **Hub centralisé (notre choix)** | **Keycloak par spoke** | **SyncSet OAuth only** |
|---|---|---|---|
| Gestion users | 1 seul endroit ✅ | 1 Keycloak par spoke | Manuel par spoke |
| Résilience | Dépend du hub | Autonome ✅ | Autonome ✅ |
| Complexité | Faible | Élevée | Moyenne |
| Tailscale requis | ✅ Oui | ❌ Non | ❌ Non |
| Cas d'usage | Homelab / dev | Production critique | Simple |

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
- [ArgoCD Cluster Secrets](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters)
- [ArgoCD ApplicationSet Cluster Generator](https://argocd-applicationset.readthedocs.io/en/stable/Generators-Cluster/)
- [Dex OIDC](https://dexidp.io/docs/)
- [Keycloak OIDC](https://www.keycloak.org/docs/latest/securing_apps/)
