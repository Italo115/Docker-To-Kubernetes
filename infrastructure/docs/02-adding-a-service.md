# 02 — Adding a service

A new microservice ships with **four files in `apps/0-base/<domain>/<app>/`** plus a small per-env overlay where it runs. That's the whole contract.

## TL;DR

```
apps/
├── kustomizeconfig.yaml         ← already exists; handles HelmRelease + ImagePolicy name refs
├── 0-base/<domain>/<app-name>/
│   ├── values.yaml              ← edit this; the single source of truth for the app
│   ├── release.yaml             ← copy-paste, change name only
│   ├── image-policy.yaml        ← ImageRepository + ImagePolicy, declared once
│   └── kustomization.yaml       ← copy-paste, change name only
└── <n-env>/                     ← for each env where this app should run
    ├── kustomization.yaml       ← add "<domain>/<app-name>" under resources:
    └── <domain>/<app-name>/
        ├── values-patch.yaml    ← image.tag + nodeSelector (+ any other env-specific delta)
        └── kustomization.yaml   ← copy-paste, change nameSuffix to -<env>
```

The ImagePolicy lives in base so the policy definition is not duplicated per environment. Tag updates are written only by env-level automation files that are listed in an env root kustomization, currently `apps/1-dev/image-automation.yaml` and `apps/2-qa/image-automation.yaml`.

## Worked example — `ai-assistant-api`

This is what's already in the repo. Use it as a template.

### `apps/0-base/operations/ai-assistant-api/values.yaml`

```yaml
component: ai-assistant-api
domain: it

image:
  repository: sample-api
  tag: latest                          # overridden per env

port: 8080
replicas: 1

resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 200m, memory: 2Gi }

ingress:
  enabled: true
  host: ai-assistant-api-${environment}.${cluster_domain}

database:
  enabled: true
  envStyle: postgres                   # emits POSTGRES_USER/PASSWORD/HOST/PORT/DB
  owns:
    name: ai_assistant                 # pre-existing DB; chart re-asserts ownership

envFrom:
  - secretRef:
      name: ai-assistant-secret        # Azure / OpenAI / app config from SOPS
```

> `nodeSelector` is set in each env's `values-patch.yaml`, not in `base/`, so dev/qa/uat land on `workload=dev` and prod lands on `workload=prod`.

### `apps/0-base/operations/ai-assistant-api/release.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ai-assistant-api
  namespace: flux-system
spec:
  targetNamespace: ${app_namespace}
  interval: 5m
  chart:
    spec:
      chart: platform
      version: "0.5.x"
      sourceRef: { kind: HelmRepository, name: example, namespace: flux-system }
      interval: 1m
  install: { createNamespace: true, remediation: { retries: 3 } }
  upgrade: { remediation: { retries: 3 } }
  valuesFrom:
    - { kind: ConfigMap, name: ai-assistant-api-values }
    - { kind: ConfigMap, name: ai-assistant-api-values-env, optional: true }
```

### `apps/0-base/operations/ai-assistant-api/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: flux-system
resources:
  - release.yaml
  - image-policy.yaml
configMapGenerator:
  - name: ai-assistant-api-values
    files:
      - values.yaml=values.yaml
generatorOptions:
  disableNameSuffixHash: true
```

### `apps/0-base/operations/ai-assistant-api/image-policy.yaml`

```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata: { name: ai-assistant-api, namespace: flux-system }
spec:
  image: harbor.example.com/example/sample-api
  interval: 1m
  secretRef: { name: harbor-pull }
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata: { name: ai-assistant-api, namespace: flux-system }
spec:
  imageRepositoryRef: { name: ai-assistant-api }     # rewritten to -dev/-qa/-uat/-prod by kustomizeconfig
  filterTags:
    pattern: "^(?P<num>[0-9]+)-${image_tag_suffix}$"
    extract: "$num"
  policy:
    numerical: { order: asc }     # asc = pick highest number (latest build); desc would pick the LOWEST
```

### Dev overlay — `apps/1-dev/operations/ai-assistant-api/`

`values-patch.yaml`:

```yaml
image:
  tag: "221-dev"  # {"$imagepolicy": "flux-system:ai-assistant-api-dev:tag"}
nodeSelector:
  workload: dev
```

> The `$imagepolicy` marker points at the **suffixed** ImagePolicy name (`ai-assistant-api-dev`). The overlay applies `nameSuffix: -dev` so the ImagePolicy resource ends up with that name; the ImageUpdateAutomation looks it up by exact name.

`kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: flux-system
nameSuffix: -dev
configurations:
  - ../../../kustomizeconfig.yaml
resources:
  - ../../../0-base/operations/ai-assistant-api
configMapGenerator:
  - name: ai-assistant-api-values-env
    files:
      - values.yaml=values-patch.yaml
generatorOptions:
  disableNameSuffixHash: true
```

### Wire it into the env

`apps/1-dev/kustomization.yaml`:

```yaml
resources:
  - operations/ai-assistant-api          # ← add this line
  - operations/ai-assistant-frontend
  - operations/python-ocr
  - image-automation.yaml
```

That's it. Push and Flux reconciles within ~5 min.

## Promoting to qa/uat/prod

```bash
mkdir -p apps/2-qa/operations/ai-assistant-api
cp apps/1-dev/operations/ai-assistant-api/kustomization.yaml apps/2-qa/operations/ai-assistant-api/
# Edit: change `nameSuffix: -dev` to `-qa`.
cat > apps/2-qa/operations/ai-assistant-api/values-patch.yaml <<'YAML'
image:
  tag: "221-qa"
nodeSelector:
  workload: dev          # qa/uat share the dev node pool; prod uses workload: prod
YAML
# Add `- operations/ai-assistant-api` to apps/2-qa/kustomization.yaml
```

No image-automation in uat/prod — those promotions are PRs.

## Verify before pushing

```bash
kustomize build --load-restrictor=LoadRestrictionsNone apps/1-dev | grep -E '^(kind:|  name:)'

helm template <app> ../helm-charts/platform \
  -f apps/0-base/<domain>/<app>/values.yaml \
  -f apps/1-dev/<domain>/<app>/values-patch.yaml | less
```

## When the app needs a database

The `database:` block above does everything. The chart emits a helm `pre-install,pre-upgrade` Job that uses the CNPG superuser (mirrored cross-namespace by Reflector) to:

1. Create role `<component>-app` if absent — minted password on first run, reused thereafter.
2. Create the owned database with role as owner.
3. Apply extensions + schemas.
4. Grant `CONNECT + USAGE + SELECT` on each `reads:` entry's `public` schema.
5. Write `${pg_cluster}-<component>-app` Secret with username/password/host/port/dbname/uri/jdbc-uri keys.

The Deployment `envFrom`s that Secret automatically. With `envStyle: postgres` you also get explicit `POSTGRES_*` aliases; `envStyle: spring` gives `SPRING_DATASOURCE_*`. See `03-adding-a-database.md` for failure modes.

The bootstrap Job inherits `.Values.nodeSelector` so it lands on the same pool as the app, alongside CNPG (which is on `workload=postgres`).

## Conventions worth knowing

- The HelmRelease lives in `flux-system`; the workload lives in `${app_namespace}` (`app-<env>`, one per env).
- `${cluster_domain}`, `${environment}`, `${app_namespace}`, `${image_tag_suffix}`, `${workload_pool}` are Flux `postBuild.substituteFrom` variables — resolved at reconcile time from each env's `cluster-config-<env>` ConfigMap. Helm never sees them.
- `nameSuffix: -<env>` is mandatory in every env overlay; without it, four envs deploying the same app collide in `flux-system`.
- The `# {"$imagepolicy": "..."}` marker is load-bearing. After suffixing, the marker points at `flux-system:<app>-<env>:tag`. `ImageUpdateAutomation` writes to that exact line.
- `disableNameSuffixHash: true` on every ConfigMap generator keeps the ConfigMap name stable across edits.
- An app's `envFrom:` (from `values.yaml`) is merged with the chart's auto-added DB creds envFrom. Both apply.
- `env:` (explicit) overrides `envFrom:` (bulk) on key collision — so `envStyle: postgres` POSTGRES_* always wins over POSTGRES_* in an envFrom-imported secret.
