# 07 — Debugging

Quick reference for the failure modes you'll actually hit. Ordered by frequency.

## Flux: my change isn't applied

```bash
# 1. Is Flux even seeing it? Check Git source sync.
flux get sources git
# LAST UPDATED should be within the last minute or two.

# 2. Which Kustomization owns it? Check whichever path your file lives under.
flux get kustomization
# READY=False is the signal. Look at the MESSAGE column.

# 3. Force reconcile (cuts wait from interval to seconds).
flux reconcile source git flux-system
flux reconcile kustomization apps --with-source
flux reconcile helmrelease <app> -n flux-system

# 4. Manifest-level reason
kubectl describe kustomization apps -n flux-system | sed -n '/Status:/,/Events:/p'
kubectl describe helmrelease <app>     -n flux-system | sed -n '/Status:/,/Events:/p'
```

## "ImagePullBackOff" on a fresh app

- Pull secret missing in the app namespace: `kubectl -n app-<env> get secret harbor-pull`. If absent, check the matching `secrets/<n-env>/` kustomization imports the shared secret and that its manifest's `namespace:` matches `app-<env>`.
- Tag literally doesn't exist in Harbor: `crane ls harbor.example.com/example/<repo>` or check the Harbor UI.
- Wrong registry: `kubectl -n app-<env> get deploy/<app> -o jsonpath='{.spec.template.spec.containers[0].image}'`. If it's not `harbor.example.com`, the chart's `global.registry` default is leaking through — set it in cluster-config or values.yaml.

## DB bootstrap Job fails

See `03-adding-a-database.md` for the full table. Fast path:

```bash
kubectl -n app-<env> get jobs -l app.kubernetes.io/name=<app>
kubectl -n app-<env> logs job/<app>-db-bootstrap
```

## SOPS: "could not decrypt"

```bash
# Is the key in the cluster?
kubectl -n flux-system get secret sops-gpg
# Does the key match the file?
kubectl -n flux-system get secret sops-gpg -o jsonpath='{.data.sops\.asc}' \
  | base64 -d | gpg --show-keys | grep ^fp
# Compare to the fingerprint in .sops.yaml and the file's sops.pgp[].fp.
```

## Image-automation didn't bump the tag

```bash
# 1. Is the ImagePolicy reading from Harbor?
kubectl -n flux-system get imagerepository <app>-<env> -o jsonpath='{.status.lastScanResult}'
# canonicalImageName should match what you expect; tagsCount > 0

# 2. Is the policy selecting any tag?
kubectl -n flux-system get imagepolicy <app>-<env> -o jsonpath='{.status.latestImage}'
# If empty, the filterTags.pattern doesn't match any tag. Re-check the regex
# (note ${image_tag_suffix} must resolve to e.g. "dev" via cluster-config).

# 3. Is the automation actually writing?
kubectl -n flux-system get imageupdateautomation dev -o yaml | tail -30
# Look at status.lastPushCommitStatus / status.lastAutomationRunTime.

# 4. The marker line is sensitive — confirm it's intact:
grep -n imagepolicy apps/1-dev/<domain>/<app>/values-patch.yaml
# Expect:    tag: "957-dev"  # {"$imagepolicy": "flux-system:<app>-dev:tag"}
```

## HelmRelease stuck "upgrade failed"

```bash
flux logs --kind=HelmRelease --name=<app> -n flux-system --since 30m
# Often "Job has reached the specified backoff limit" — the bootstrap Job is failing.

# Inspect the helm history
helm -n app-<env> history <app>
# Roll back to a known good revision if needed
helm -n app-<env> rollback <app> <N>
# Then push the fix and let Flux re-converge.
```

If a HelmRelease is wedged with `another operation is in progress`:

```bash
flux suspend helmrelease <app> -n flux-system
helm -n app-<env> uninstall <app> --keep-history
# Fix the underlying issue
flux resume helmrelease <app> -n flux-system
```

## "MountVolume.SetUp failed for volume X / secret not found"

The `<app>-values-env` ConfigMap is missing. Either:
- `apps/<n-env>/<domain>/<app>/kustomization.yaml` doesn't have `configMapGenerator`, or
- The env's overlay isn't imported by `apps/<n-env>/kustomization.yaml`, so Kustomize never generates it.

Run `kustomize build --load-restrictor=LoadRestrictionsNone apps/<n-env> | grep '<app>-values'` — you should see TWO ConfigMaps (`-values` and `-values-env`).

## Postgres connection from inside a pod

```bash
kubectl -n app-<env> exec -it deploy/<app> -- bash
# inside:
env | grep ^SPRING_DATASOURCE
psql "${URI}" -c '\l'
```

If `psql` isn't in the image, use a debug pod:

```bash
kubectl -n app-<env> run -it --rm pgdebug --image=ghcr.io/cloudnative-pg/postgresql:16 -- bash
# then read the creds Secret manually
kubectl -n app-<env> get secret postgres-<app>-app -o yaml
```

## Everything looks healthy but the app 502s

```bash
# Is the Traefik IngressRoute attached?
kubectl -n app-<env> get ingressroute.traefik.io <app> -o yaml | grep -A3 routes:

# Is the cert ready?
kubectl -n app-<env> get certificate <app>-tls
# READY=True or False; if False, see kubectl describe for the cert-manager reason.

# Is the Service backed by pods?
kubectl -n app-<env> get endpoints <app>
# ENDPOINTS column must be non-empty.
```

## When in doubt

```bash
# All Flux conditions across the cluster
flux get all -A

# Full event stream for the namespace
kubectl -n app-<env> get events --sort-by=.lastTimestamp | tail -50

# Tail the controllers
kubectl -n flux-system logs deploy/kustomize-controller -f
kubectl -n flux-system logs deploy/helm-controller       -f
kubectl -n flux-system logs deploy/source-controller     -f
```
