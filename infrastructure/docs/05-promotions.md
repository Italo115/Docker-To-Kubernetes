# 05 — Promotions

Image tags flow `dev → qa → uat → prod`. Dev and qa auto-bump from matching Harbor tags; uat and prod promotions are PRs.

## How a tag lands in dev or qa

1. Developer pushes code; CI builds the image and pushes it to Harbor as `<N>-dev` or `<N>-qa` (e.g. `957-dev`).
2. Flux `ImageRepository: <app>` scans Harbor every 1m.
3. `ImagePolicy: <app>-<env>` (filter `^(?P<num>[0-9]+)-${image_tag_suffix}$`) selects the highest matching env tag.
4. `ImageUpdateAutomation: dev` or `qa` rewrites `apps/<n-env>/<domain>/<app>/values-patch.yaml` at the `# {"$imagepolicy": ...}` marker, commits as `fluxcdbot@example.com`, and pushes.
5. Flux reconciles within ~5m; the HelmRelease re-renders with the new tag; the Deployment rolls.

## Promoting manually

```bash
# Read the tag the lower env is currently running
yq '.image.tag' apps/2-qa/<domain>/<app>/values-patch.yaml
# e.g. "957-qa"

# Convert to the uat tag (your CI must publish a matching <N>-uat or you must retag in Harbor)
# Then update uat's patch:
yq -i '.image.tag = "957-uat"' apps/3-uat/<domain>/<app>/values-patch.yaml

# Commit and push as a PR
git checkout -b promote/<app>-957-to-uat
git add apps/3-uat/<domain>/<app>/values-patch.yaml
git commit -m "promote(uat): <app> → 957-uat"
git push -u origin HEAD
```

`uat` and `prod` have no `ImageUpdateAutomation`. Their tags stay put until the next PR.

## Promoting qa → uat → prod

Same shape as above. The convention is one PR per environment per app. Squash on merge so `git log` reads:

```
promote(uat): ai-assistant-api → 957-uat
promote(prod): ai-assistant-api → 957-prod
```

## Catching drift

```bash
# Per-app: which tag is each env running?
for env in dev qa uat prod; do
  case "$env" in dev) path=1-dev ;; qa) path=2-qa ;; uat) path=3-uat ;; prod) path=4-prod ;; esac
  printf '%-8s ' "$env"
  yq '.image.tag' "apps/$path/<domain>/<app>/values-patch.yaml" 2>/dev/null || echo "—"
done

# Cluster-wide: what's actually deployed
kubectl --context=<cluster> -n app-<env> get deploy -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

If a deployed image doesn't match the patch, Flux is stuck — see `07-debugging.md`.

## When dev is broken and you must NOT auto-promote

The auto-bump on dev is opt-out by removing the `# {"$imagepolicy": ...}` marker. To freeze a single app:

```yaml
# apps/1-dev/<domain>/<app>/values-patch.yaml
image:
  tag: "957-dev"  # frozen 2026-05-25 — see incident #1234
```

To freeze all of dev or qa, set `auto_image_updates: "false"` in the matching `clusters/my-cluster/cluster-config-<env>.yaml`. (Currently the `ImageUpdateAutomation` always runs; this flag is reserved — see `06-bootstrap.md` for the gating change if you need a hard kill switch.)

## Hotfixes that skip envs

Sometimes prod needs a fix that dev/qa don't have yet. The PR pattern still applies; just be honest in the commit message:

```
promote(prod): ai-assistant-api → 962-prod (hotfix CVE-2026-XXXX, skipping dev/qa)
```

Then backport to dev/qa as a separate PR so the envs reconverge.

## Adding a new environment

See `06-bootstrap.md#adding-a-new-environment`. A new tenant is a few files under `clusters/my-cluster/` + `apps/` + `secrets/`; no second cluster bootstrap.
