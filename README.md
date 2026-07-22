# FluxCD + Helm GitOps Starter

A ready-to-adapt **GitOps monorepo** for running applications on Kubernetes with
[Flux v2](https://fluxcd.io/) and Helm. It gives you a single-cluster,
multi-environment (dev / qa / uat / prod) platform driven entirely from Git:
push a change, Flux reconciles it.

Every organization-specific value has been replaced with an obvious placeholder,
so you can clone this, run a find-and-replace, point it at your own Git remote
and registry, and bootstrap. See the **[Placeholder checklist](#placeholder-checklist)** below.

## What's inside

| Directory | Purpose |
|---|---|
| `helm-charts/` | Source + CI for a single generic application chart (`platform`) that renders one app per release (Deployment + Service + optional Ingress + optional CNPG Postgres database), plus a custom Traefik `error-pages` container image. CI (`bitbucket-pipelines.yml`) packages the chart and pushes it to an OCI registry. |
| `infrastructure/` | The Flux bootstrap target. Reconciles, in dependency order: infra secrets → controllers (cert-manager, Traefik, Harbor, Nexus, MinIO, CNPG, Reflector, Reloader, monitoring: Prometheus/Loki/Tempo/OTel/Promtail) → infra configs → per-env secrets → per-env apps. |
| `infrastructure/docs/` | Nine how-to guides: architecture, adding a service, adding a database, secrets (SOPS), promotions, bootstrap, debugging, disaster recovery, single-artifact promotion. **Start here.** |

## Architecture in one paragraph

One physical cluster hosts four logical environments, isolated by namespace
(`app-dev`, `app-qa`, `app-uat`, `app-prod`) and pinned to node pools via
`nodeSelector`. Each app is declared once in `apps/0-base/<domain>/<app>/`
(a `HelmRelease` + values + `ImagePolicy`) and specialized per environment through
Kustomize overlays (`nameSuffix: -<env>` + a `values-patch.yaml`), with Flux
`postBuild.substituteFrom` injecting per-env values from the
`cluster-config-<env>` ConfigMaps in `clusters/my-cluster/`. Secrets are
SOPS/GPG-encrypted. Image tags auto-update on dev/qa via `ImageUpdateAutomation`
and are PR-promoted upward. Full details in
[`infrastructure/docs/01-architecture.md`](infrastructure/docs/01-architecture.md).

## Prerequisites

- A Kubernetes cluster and `kubectl` access
- [`flux`](https://fluxcd.io/flux/installation/) CLI, [`kustomize`](https://kustomize.io/), [`helm`](https://helm.sh/)
- A Git remote Flux can pull from (this template uses Bitbucket; any Git host works)
- An OCI container registry (this template uses Harbor)
- A GPG key for SOPS secret encryption
- [`sops`](https://github.com/getsops/sops) for editing encrypted secrets

## Quick start

1. Work through the **[Placeholder checklist](#placeholder-checklist)** below.
2. Push this repo to your own Git remote.
3. Bootstrap Flux onto your cluster following
   [`infrastructure/docs/06-bootstrap.md`](infrastructure/docs/06-bootstrap.md).
4. Add your first service following
   [`infrastructure/docs/02-adding-a-service.md`](infrastructure/docs/02-adding-a-service.md).

## Placeholder checklist

Replace these across the repo before bootstrapping. Most are a simple global
find-and-replace; the `<ANGLE_BRACKET>` tokens must be filled with real values.

**Global search-and-replace** (pick your own values):

| Placeholder | Meaning | Appears in |
|---|---|---|
| `example.com` / `kube.example.com` | Public / cluster base domains | ingress hosts, docs, values |
| `harbor.example.com` | Container registry hostname | Harbor release, sources, image refs |
| `example` | Harbor project **and** the Flux `HelmRepository` name for your chart | `sources/example.yaml`, `imageProject`, image paths |
| `my-org` | Git host workspace / org | `gotk-sync.yaml` (Git URLs), docs |
| `my-cluster` | Flux bootstrap directory (`clusters/my-cluster/`) and the `path:` in `gotk-sync.yaml` | cluster dir, docs, kubeconfig name |
| `app-dev` / `app-qa` / `app-uat` / `app-prod` | Per-env namespaces | `cluster-config-*.yaml`, docs |
| `platform-admin@example.com` | cert-manager ACME + chart maintainer email | `cluster-issuer.yaml`, `Chart.yaml` |
| `fluxcdbot@example.com` | Git author for automated image-tag commits | `apps/*/image-automation.yaml` |
| `sample-app` | The example application (rename/copy for real apps) | `apps/0-base/department/application-name/`, overlays |

**Fill-in values** (must be set to real values for the feature to work):

| Placeholder | What to put |
|---|---|
| `<YOUR_GPG_FINGERPRINT>` | Your SOPS GPG key fingerprint (`.sops.yaml`, docs) |
| `<TRAEFIK_CLUSTER_IP>` | Traefik Service ClusterIP (only if you use `harbor-hosts-fix`) |
| `<PUBLIC_LB_IP>` | Your load balancer's public IP (comment reference only) |
| `<node-name>` | Node names for `kubectl label node ...` in bootstrap |
| `<KEYVAULT_NAME>`, `<RESOURCE_GROUP>`, `<STORAGE_ACCOUNT>`, `<AZURE_REGION>` | Azure resources for the (optional) disaster-recovery flow in `docs/08` |

**Secrets** — the files under `infrastructure/secrets/` are templates:
`template-secret.yaml`, `template-encrypted.yaml` (an *illustrative* SOPS shape,
not real ciphertext), `cloudflare-api.yaml`, `harbor-pull.yaml`, `minio-secret.yaml`.
Fill them with your own values and encrypt with `sops -e -i <file>` before
committing. See [`infrastructure/docs/04-secrets.md`](infrastructure/docs/04-secrets.md).

## Extending to more environments

This scaffold ships working `1-dev` and `2-qa` app overlays. The docs describe
`3-uat` and `4-prod` as the promotion targets — create them by copying the
`2-qa` overlay (and the matching `secrets/<n-env>/` and `apps-<env>.yaml`
Kustomizations), adjusting `nameSuffix`, namespace, and `cluster-config-<env>`.
See [`infrastructure/docs/06-bootstrap.md`](infrastructure/docs/06-bootstrap.md).

## License

Apache 2.0 — see [LICENSE](LICENSE).
