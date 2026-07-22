# platform

Single-app Helm chart. **One HelmRelease → one application.** All shape (Deployment, Service, optional ingress, optional auto-provisioned Postgres database) is described by a single `values.yaml` consumed by Flux from the `infrastructure` repo.

| Field | Required | Notes |
|---|---|---|
| `component` | yes | Stable identifier — appears in resource names, labels, DB role. |
| `domain` | yes | One of `core`, `commercial`, `finance`, `operations`, `it`, `supplychain`. |
| `image.repository` | yes | Image repo under `global.registry/global.imageProject`. |
| `image.tag` | yes | Overlays bump this; image-automation may rewrite on dev. |
| `port` | yes | Container port (also the Service port). |
| `ingress.enabled` | no | When true, emits Certificate + Traefik IngressRoute. |
| `ingress.extraHosts[]` | no | Extra `Host()` names this one instance also answers. Added to the IngressRoute match (OR'd) and the cert SANs. Lets N DNS names resolve to a single pod set. |
| `deployment.strategy` | no | Deployment update strategy. Default `RollingUpdate` with `maxSurge:1, maxUnavailable:0` in 0-base — old pod keeps serving until the new one passes readiness. |
| `probes.readiness` | no | Readiness probe. 0-base sets a generic `tcpSocket` floor; override with an `httpGet` health check when the app has one. |
| `database.enabled` | no | When true, auto-provisions Postgres role + DB + Secret. |
| `database.owns.name` | yes if enabled | Database name to own. |
| `database.reads[]` | no | Other databases this app gets read-only access to. |

## What gets rendered

```
HelmRelease (one of these per app)
  └── chart values
        ├── Deployment
        ├── Service
        ├── [if ingress.enabled] cert-manager Certificate + Traefik IngressRoute
        └── [if database.enabled]
              ├── Secret <pgCluster>-<component>-app     (creds, populated by Job)
              ├── ServiceAccount + Role + RoleBinding     (scoped to the Secret above)
              └── Job <release>-db-bootstrap              (pre-install/pre-upgrade hook)
                    creates role + db + extensions + schemas + cross-grants,
                    then writes the Secret.
```

## How to use it (from the infrastructure repo)

```yaml
# apps/base/sample-api/release.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: sample-api
spec:
  chart:
    spec:
      chart: platform
      version: "0.3.x"
      sourceRef:
        kind: HelmRepository
        name: example
        namespace: flux-system
  valuesFrom:
    - kind: ConfigMap
      name: sample-api-values    # generated from apps/base/sample-api/values.yaml
```

## Point several envs' DNS at one instance (`ingress.extraHosts`)

To save resources you can run an app in **one** env and have other envs' hostnames
resolve to it. Example — the dev instance of `sample-api` also answers qa + uat:

```yaml
# apps/1-dev/operations/sample-api/values-patch.yaml  (the OWNING env)
ingress:
  extraHosts:
    - sample-api-qa.example.com
    - sample-api-uat.example.com
```

Then **remove** `operations/sample-api` from `apps/2-qa/kustomization.yaml`
and `apps/3-uat/kustomization.yaml` so no pod/Service/IngressRoute/DB is created
there (that's the saving, and it avoids two routes claiming the same Host). Point
the qa/uat DNS records at the Traefik LB; cert-manager reissues the dev cert with
the extra SANs. Note: all collapsed hostnames hit the **owning** env's pod,
database, secrets and image tag — the other envs are no longer isolated.

`extraHosts` can't live in `apps/0-base` (shared by all envs; `${environment}`
can't expand to another env's name) — it belongs in the owning env's overlay.

**Why this needs no cross-namespace ref or Reflector:** the extra Host names are
added to the owning route, so the IngressRoute, its backing Service, and its TLS
cert secret all live in the same namespace (`app-dev`). Nothing crosses a
namespace boundary.

Contrast with the alternative topology — a stub IngressRoute in `app-uat`
pointing at the Service in `app-dev`. That *is* cross-namespace, but still needs
no Reflector: Traefik already runs with `allowCrossNamespace: true`, so the route
just sets `services[].namespace: app-dev`, and cert-manager issues the uat cert
locally in `app-uat`. Reflector would only be an optimization if you wanted to
*reuse the same TLS secret* across namespaces (to avoid a second cert issuance /
Let's Encrypt rate limits) — not a requirement. Prefer the `extraHosts` approach;
it avoids the boundary entirely.

## Versioning

Bump `Chart.yaml:version` on any chart change. The Flux `HelmRelease` consumes `0.3.x` (or pinned, per env). CI in `bitbucket-pipelines.yml` packages and pushes to `oci://harbor.example.com/example`.
