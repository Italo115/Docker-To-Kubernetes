# 01 — Architecture

Single-tenant Flux v2 monorepo running on a **single physical cluster** that hosts four logical environments (dev / qa / uat / prod). One Helm chart renders any app from a values file.

## Why single cluster

The cluster is split into four dedicated node pools labelled `workload=<tier>`:

| Pool label              | Role                                                             |
|-------------------------|------------------------------------------------------------------|
| `infrastructure`        | cert-manager, traefik, harbor, nexus, minio, reflector, CNPG op |
| `postgres`              | CNPG Postgres pods                                              |
| `dev`                   | App pods for dev, qa, uat                                       |
| `prod`                  | App pods for prod                                               |

Pods land on the correct pool via `nodeSelector` (soft pinning — no taints yet). Tenant isolation between envs is by **namespace** (`app-dev`, `app-qa`, `app-uat`, `app-prod`), not by cluster.

## Repo layout

```
infrastructure/                              # this repo
├── .sops.yaml                               # SOPS creation rules (GPG fingerprint)
├── README.md                                # entry point → docs/
├── docs/                                    # the maps
│
├── clusters/
│   └── my-cluster/                                 # THE ONLY Flux bootstrap target
│       ├── flux-system/                     # bootstrap-generated
│       ├── cluster-config-dev.yaml          # per-env substitution ConfigMaps:
│       ├── cluster-config-qa.yaml           #   environment, app_namespace,
│       ├── cluster-config-uat.yaml          #   image_tag_suffix, workload_pool
│       ├── cluster-config-prod.yaml
│       ├── infrastructure.yaml              # → infrastructure/controllers (once)
│       ├── infrastructure-configs.yaml      # → infrastructure/configs (once)
│       ├── secrets-infrastructure.yaml      # → secrets/5-infrastructure (once)
│       ├── secrets-dev.yaml                 # → secrets/1-dev
│       ├── secrets-qa.yaml                  # → secrets/2-qa
│       ├── secrets-uat.yaml                 # → secrets/3-uat
│       ├── secrets-prod.yaml                # → secrets/4-prod
│       ├── apps-dev.yaml                    # → apps/1-dev,  substitutes cluster-config-dev
│       ├── apps-qa.yaml                     # → apps/2-qa,   substitutes cluster-config-qa
│       ├── apps-uat.yaml                    # → apps/3-uat,  substitutes cluster-config-uat
│       └── apps-prod.yaml                   # → apps/4-prod, substitutes cluster-config-prod
│
├── infrastructure/
│   ├── controllers/                         # cluster-wide operators (Helm)
│   │   ├── cert-manager/  cnpg/  harbor/  minio/  monitoring/
│   │   ├── nexus/  priority-classes/  reflector/  reloader/
│   │   ├── sources/  storage/  traefik/
│   │   └── kustomization.yaml
│   │   # Each controller's HelmRelease values: nodeSelector.workload=infrastructure
│   └── configs/
│       ├── cluster-issuer.yaml              # cert-manager / Let's Encrypt
│       ├── pg-cluster.yaml                  # CNPG Cluster; affinity.nodeSelector.workload=postgres
│       ├── pg-monitoring.yaml
│       └── kustomization.yaml
│
├── apps/
│   ├── kustomizeconfig.yaml                 # nameReference config — see "Name collisions" below
│   ├── 0-base/<domain>/<app>/               # ONE source of truth per app
│   │   ├── values.yaml                      # the only file most edits touch
│   │   ├── release.yaml                     # HelmRelease (boilerplate)
│   │   ├── image-policy.yaml                # ImageRepository + ImagePolicy
│   │   └── kustomization.yaml               # generates <app>-values ConfigMap
│   ├── 1-dev/                               # image-automation enabled for -dev tags
│   │   ├── kustomization.yaml               # lists apps + image-automation.yaml
│   │   ├── image-automation.yaml
│   │   └── <domain>/<app>/
│   │       ├── values-patch.yaml            # image.tag + nodeSelector{workload:dev}
│   │       └── kustomization.yaml           # nameSuffix: -dev; configurations: ../../../kustomizeconfig.yaml
│   ├── 2-qa/                                # same shape, image-automation enabled for -qa tags
│   │   ├── image-automation.yaml
│   │   └── <domain>/<app>/{kustomization,values-patch}.yaml   # nameSuffix: -qa; nodeSelector{workload:dev}
│   ├── 3-uat/                               # same shape, no image-automation
│   │   └── <domain>/<app>/{kustomization,values-patch}.yaml   # nameSuffix: -uat; nodeSelector{workload:dev}
│   └── 4-prod/                              # same shape, prod pool
│       └── <domain>/<app>/{kustomization,values-patch}.yaml   # nameSuffix: -prod; nodeSelector{workload:prod}
│
└── secrets/
    ├── 0-base/                              # SOPS-encrypted, namespace app-dev baked into the body
    ├── 5-infrastructure/                    # harbor-pull, cloudflare-api, minio-secret
    └── 1-dev/  2-qa/  3-uat/  4-prod/       # each: namespace: app-<env>, resources: [../0-base]
        └── kustomization.yaml               # Kustomize namespace transformer rewrites without re-encrypting
```

The chart itself lives in the sibling `helm-charts/` repo as `platform`, published to `oci://harbor.example.com/example` by Bitbucket Pipelines on `main`. Flux consumes it via a `HelmRepository`.

## Flux reconcile graph (single cluster, four tenants)

```
GitRepository: flux-system
        │
        ├─→ secrets-infrastructure  ── harbor-pull, cloudflare-api, minio-secret
        │
        ├─→ infrastructure          (waits for secrets-infrastructure)
        │           │
        │           ▼
        │   infrastructure-configs  (waits for infrastructure)
        │           │
        │           ▼
        │   ┌───────┴────────┬────────────────┬────────────────┐
        │   ▼                ▼                ▼                ▼
        │ apps-dev         apps-qa         apps-uat         apps-prod
        │ ↑                ↑               ↑                ↑
        │ │                │               │                │
        ├─→ secrets-dev   secrets-qa     secrets-uat      secrets-prod
        │
        └─→ (all four apps-<env> also have dependsOn: secrets-<env>)
```

Each `apps-<env>` Flux Kustomization sets `postBuild.substituteFrom: cluster-config-<env>` so `${environment}`, `${app_namespace}`, `${cluster_domain}`, `${pg_cluster}`, `${image_tag_suffix}`, `${auto_image_updates}`, `${workload_pool}` resolve per env.

## How a single app gets to a pod

1. **`apps/0-base/<domain>/<app>/values.yaml`** is the canonical declaration (image, port, ingress, database).
2. **`apps/<n-env>/<domain>/<app>/values-patch.yaml`** patches env deltas (image tag, host, `nodeSelector.workload`).
3. The env's `kustomization.yaml` lists the app under `resources:`. Listing = enabling.
4. Kustomize processes `apps/<n-env>/<domain>/<app>/kustomization.yaml` which:
   - imports `../../../0-base/<domain>/<app>` (HelmRelease + base ConfigMap + ImagePolicy)
   - applies `nameSuffix: -<env>` to every resource (HelmRelease, ConfigMaps, ImagePolicy, ImageRepository)
   - generates `<app>-values-env` from `values-patch.yaml`
   - loads `../../../kustomizeconfig.yaml` so name references inside the HelmRelease's `spec.valuesFrom[].name` and the ImagePolicy's `spec.imageRepositoryRef.name` follow the suffix
5. Flux passes `${app_namespace}` etc. into the rendered HelmRelease via postBuild substitution.
6. The HelmRelease pulls `platform` chart from Harbor OCI and renders Deployment + Service + (optional) Certificate + IngressRoute + (optional) DB bootstrap Job + Secret + RBAC.
7. The chart's Deployment + DB-bootstrap Job set `nodeSelector` from `.Values.nodeSelector` → pod lands on the right node pool.
8. If `database.enabled`: the bootstrap Job uses the CNPG superuser secret (mirrored cross-namespace via Reflector) to create the role + DB + cross-grants, then writes the app's connection Secret. The Deployment envFroms it; Reloader rolls pods if the password rotates.

## Name collisions — why every overlay applies `nameSuffix`

Every HelmRelease + its ConfigMaps live in the `flux-system` namespace. With four envs deploying the same set of apps from the same base, the resources would collide (`ai-assistant-api` HelmRelease in flux-system, four times). The env overlay adds `nameSuffix: -<env>` so they become `ai-assistant-api-dev`, `-qa`, `-uat`, `-prod`.

Kustomize would normally leave the HelmRelease's `spec.valuesFrom[].name` pointing at the un-suffixed ConfigMap name — `apps/kustomizeconfig.yaml` registers that field as a `nameReference` so it follows the rename. Same for `ImagePolicy.spec.imageRepositoryRef.name` → `ImageRepository`.

Side effect: the `# {"$imagepolicy": ...}` marker in `values-patch.yaml` must point at the suffixed ImagePolicy name (`flux-system:ai-assistant-api-dev:tag`).

## Where each pain point gets solved

| Old pain | New design |
|---|---|
| Four flux bootstraps for one cluster | Single `clusters/my-cluster/` bootstrap; four `apps-<env>` Kustomizations inside |
| Same namespace across envs (`app-dev` everywhere) | One namespace per env: `app-dev`/`app-qa`/`app-uat`/`app-prod`, set by per-env `cluster-config-<env>` |
| Resource name collisions across envs | Per-overlay `nameSuffix: -<env>` + nameReference config |
| Re-encrypting SOPS per env | Kustomize `namespace:` transformer rewrites the namespace at apply time; SOPS untouched |
| Pods landing on wrong node tier | `nodeSelector.workload=<pool>` per overlay; chart renders into Deployment + Job |
| Values duplicated between chart and apps | Chart's `values.yaml` is empty defaults. `apps/0-base/<domain>/<app>/values.yaml` is the only file |
| `db-role.yaml` + SOPS + values per DB | `database:` block in app values; chart emits role + DB + Secret |
| Image tag bumps | Auto on dev (per env tag suffix from cluster-config-dev); PR-promoted upstream |

See `02-adding-a-service.md` for the dev-facing walkthrough.
