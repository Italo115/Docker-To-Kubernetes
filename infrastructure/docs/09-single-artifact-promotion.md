# 09 — Single-Artifact Promotion (design note)

> **Status:** proposal / reference. This describes the industry-standard
> "build once, promote the same artifact" model and how it would map onto our
> multi-repo GitOps system. It is **not** how promotions work today — see
> `05-promotions.md` for the current per-environment-tag model and the
> "Gap analysis" section below for the difference.

## 1. The principle

**Build the artifact exactly once. Test that artifact. Promote that same,
byte-for-byte identical artifact through every environment until it reaches
production.**

The thing that runs in prod must be the *same* thing that passed qa, which is
the *same* thing that passed dev. Not a rebuild "from the same commit" — the
identical image, identified by its content digest (`sha256:…`).

Why this matters:

- **Rebuilds are not reproducible.** A rebuild from the same git commit can
  still differ: base image moved, a transitive dependency floated, build cache
  changed, timestamps embedded. "Same commit" ≠ "same bits".
- **You test what you ship.** If qa runs build A and prod runs build B (rebuilt
  for prod), qa never actually tested prod. The promotion gate is a lie.
- **Provenance & rollback are exact.** A digest is a globally unique fingerprint.
  "prod is running `sha256:abc…`" is unambiguous; "prod is running `957-prod`"
  depends on what `957-prod` pointed at *at the time it was pulled*.

The unit that moves between environments is a **reference to an immutable
artifact**, not source code and not a rebuild.

## 2. The cast (services & repos)

Our platform spans several repos and services. Single-artifact promotion
touches all of them:

| Actor | Role | Repo / location |
|---|---|---|
| **App source repos** | One git repo per service (e.g. `sample-app`, `auth-server`, `sample-api`). Application code only. | many, separate |
| **Bitbucket Pipelines** | CI. Builds & pushes the container image **once** per merge to the app repo's main. | each app repo's `bitbucket-pipelines.yml` |
| **`helm-charts`** | The `platform` Helm chart — the deployment *template* shared by all apps. CI packages & pushes it as an OCI artifact. | `helm-charts/` repo |
| **Harbor** | OCI registry at `harbor.example.com/example`. Stores **both** the app images (`<app>`) **and** the chart (`platform`). The single source of immutable artifacts. | `harbor.example.com` |
| **`infrastructure`** | Flux GitOps desired state. Declares *which artifact reference* each env runs, per app, in `apps/<n-env>/<domain>/<app>/values-patch.yaml`. | this repo |
| **Flux** (source / kustomize / helm / image controllers) | Reconciles the cluster to match `infrastructure`. Pulls images & chart from Harbor. | on the cluster |

Two distinct artifacts get versioned and (ideally) promoted:

1. **The app image** — `harbor.example.com/example/<app>@sha256:…`. Changes every
   time app code changes.
2. **The chart** — `oci://harbor.example.com/example/platform:<version>`. Changes
   when deployment *shape* changes (new value, new template). Promoted far less
   often, and across *all* apps at once.

This note focuses on the app image (the thing that changes daily). Chart
promotion is the same idea at a slower cadence — see §8.

## 3. Artifact identity: what "the same artifact" means

There are three ways to name an image. Only one is safe to promote.

| Form | Example | Immutable? | Use |
|---|---|---|---|
| **Digest** | `sample-app@sha256:9f86d0…` | ✅ content-addressed, can never change | **the promotion unit** — what higher envs pin |
| **Immutable tag** | `sample-app:957` or `sample-app:git-a1b2c3d` | ⚠️ only if Harbor enforces immutability | human-readable handle for "which build"; CI assigns once, never reuses |
| **Floating tag** | `sample-app:latest`, `sample-app:957-qa` | ❌ rewritten / per-env | **never** for promotion; fine for "newest dev" convenience only |

**Key change vs today:** drop the per-environment tag *suffix*. A build is
`957` (or the git SHA), not `957-dev` / `957-qa`. The *same* `957` flows through
all envs. The environment is decided by *which env's `values-patch.yaml` points
at `957`*, not by baking the env name into the tag.

Best practice is to pin by **digest** in qa/uat/prod (tag is advisory, digest is
truth). The immutable tag stays useful for humans and for the dev auto-bump.

## 4. The end-to-end flow

```
 App repo (e.g. sample-app)                      helm-charts repo
  │  merge to main                          │  merge to main (chart change)
  ▼                                         ▼
 Bitbucket Pipelines                      Bitbucket Pipelines
  │  docker build  (ONCE)                   │  helm package
  │  tag = 957  (immutable, no -env)        │  push OCI
  ▼                                         ▼
 Harbor: sample-app:957  ──►  digest sha256:9f86…   Harbor: platform:0.5.1
  │                          (immutability rule: tag 957 can never be overwritten)
  │
  │   ┌──────────────────────── infrastructure repo (GitOps) ─────────────────────┐
  │   │                                                                            │
  ▼   ▼                                                                            │
 ① DEV  — Flux ImagePolicy picks newest build → ImageUpdateAutomation writes      │
          apps/1-dev/department/sample-app/values-patch.yaml:  tag 957 (+ digest)  → auto-commit      │
          Flux deploys to app-dev. Tests/observation happen here.                  │
                                                                                   │
          promote = PR copying the EXACT ref dev runs into the next env            │
                                                                                   │
 ② QA   — PR: apps/2-qa/department/sample-app/values-patch.yaml  → 957  @sha256:9f86…  (same digest)   │
          merge → Flux deploys SAME artifact to app-qa. No rebuild, no retag.      │
                                                                                   │
 ③ UAT  — PR: apps/3-uat/department/sample-app/values-patch.yaml → 957 @sha256:9f86…                   │
                                                                                   │
 ④ PROD — PR: apps/4-prod/department/sample-app/values-patch.yaml→ 957 @sha256:9f86…                   │
   └────────────────────────────────────────────────────────────────────────────┘
                                         ▲
                                         │ all four envs ultimately reference
                                         │ ONE Harbor artifact: sha256:9f86…
```

The digest `sha256:9f86…` is identical in every box. That is the whole point:
prod runs the bits qa blessed, which are the bits dev built.

## 5. How a build enters the system (dev)

Unchanged in spirit from today; only the tag shape changes.

1. Developer merges to the app repo's `main`.
2. Bitbucket Pipelines builds the image **once** and pushes
   `harbor.example.com/example/sample-app:957`. Harbor records its digest. The build
   number `957` is **immutable** (Harbor tag-immutability rule forbids
   overwrite) and carries **no `-dev` suffix**.
3. Flux `ImageRepository: sample-app` scans Harbor.
4. Flux `ImagePolicy: sample-app` selects the newest build (numeric, or by build-time
   metadata). Filter no longer needs an env suffix.
5. `ImageUpdateAutomation: dev` writes the new ref into
   `apps/1-dev/department/sample-app/values-patch.yaml` at the `# {"$imagepolicy": …}` marker and
   commits.
6. Flux reconciles `app-dev`; the Deployment rolls.

Dev is the *only* env with image automation. It is the on-ramp: the newest
artifact always lands in dev automatically, and nowhere else automatically.

## 6. How promotion works (qa → uat → prod)

Promotion is a **pull request that copies the exact artifact reference from the
lower env into the higher env's `values-patch.yaml`.** Nothing is rebuilt;
nothing is retagged.

```bash
# What artifact is dev running right now?
yq '.image' apps/1-dev/department/sample-app/values-patch.yaml
# tag: "957"
# digest: "sha256:9f86d081884c7d65…"

# Promote that SAME artifact to qa — copy tag AND digest verbatim
yq -i '.image.tag = "957" | .image.digest = "sha256:9f86d081884c7d65…"' \
  apps/2-qa/department/sample-app/values-patch.yaml

git checkout -b promote/sample-app-957-to-qa
git commit -am "promote(qa): sample-app → 957 (sha256:9f86…)"
git push -u origin HEAD   # open PR, review, merge
```

Merge → Flux pulls `sample-app@sha256:9f86…` into `app-qa`. Because the digest is
pinned, qa is *guaranteed* to run the identical image dev ran — even if someone
later (mis)moves the `957` tag, the digest still resolves to the tested bits.

Same shape for uat and prod. One PR per env per app. The PR *is* the promotion
gate (review + approval + audit trail). Squash so `git log` reads:

```
promote(qa):   sample-app → 957 (sha256:9f86…)
promote(uat):  sample-app → 957 (sha256:9f86…)
promote(prod): sample-app → 957 (sha256:9f86…)
```

### Optional: digest-pinned automation between envs

You can make the copy mechanical without losing the gate: a CI job (or a small
script / GitOps tool like Flux's promotion features) opens the promotion PR
automatically, but a human still approves the merge. The gate is the *merge
approval*, not the typing.

## 7. Rollback

Because every env's state is "a digest in git":

- **Roll back = revert the promotion PR** (or open a new PR pinning the previous
  digest). Flux redeploys the prior artifact. The prior image still exists in
  Harbor (retention must keep it — see §8).
- No "rebuild the old version" — the old artifact is still sitting in Harbor,
  addressable by digest. Pull it, done.

## 8. Harbor's role & required settings

Harbor is the single store of truth for artifacts. For single-artifact
promotion to be sound, Harbor must be configured so artifacts are stable:

- **Tag immutability rules** — on the `example` project, make build tags immutable
  (e.g. immutability rule matching `**` or `[0-9]*`). Once `sample-app:957` is
  pushed it can never be overwritten. This is what makes a tag a safe handle.
- **Retention policy** — must retain *every artifact currently referenced by any
  env*, plus enough history to roll back. A naive "keep last 10" can delete the
  image prod is still pinned to. Safer: retain by "pulled within N days" and/or
  never-GC tags referenced in the `infrastructure` repo.
- **Vulnerability scanning** — Harbor (Trivy) scans on push. You can gate
  promotion on scan results: block promoting an artifact with criticals.
- **Signing (cosign) — optional but recommended** — sign images at build; verify
  signature at promotion / admission. Proves the artifact wasn't swapped.
- **Replication — optional** — if prod ever runs from a separate registry, Harbor
  replicates the *same digest*; you still promote one artifact.
- **Garbage collection** — only ever removes blobs with no tag/reference. With
  immutability + sane retention, GC won't touch live artifacts.

### Chart promotion (`platform`)

The chart is the second artifact. Today base HelmReleases track `0.5.x` (a
floating minor range), which is convenient but technically lets a chart change
reach all envs at once without a per-env gate. For strict single-artifact
behaviour you would:

- Pin an **exact** chart version per env (`0.5.1`, not `0.5.x`) in each env's
  HelmRelease, and promote chart bumps env-by-env via PR, same as images.
- Trade-off: more PRs for chart changes. Most teams pin charts in prod and float
  in dev. Decide per risk appetite.

## 9. Gap analysis — current model vs target

| Aspect | Current (`05-promotions.md`) | Single-artifact target |
|---|---|---|
| Image per env | **Separate build** per env: `957-dev`, `957-qa` are different pushes (often different build numbers, e.g. `8532-dev` vs `8519-qa`). | **One** build `957`; same digest in every env. |
| Tag shape | `<N>-<env>` (env baked into tag). | `<N>` or git SHA, env-agnostic; digest pinned upstream of dev. |
| What's promoted | A *new tag* the higher env's CI must publish ("your CI must publish a matching `<N>-qa` or retag in Harbor"). | A *reference* (tag+digest) copied verbatim — no new artifact. |
| Guarantee | qa may run different bits than dev. | qa runs byte-identical bits to dev. |
| Rollback | Re-point to an older `<N>-<env>` (if it still exists). | Revert PR → previous digest (still in Harbor). |
| Harbor | Many per-env tags of essentially the same code. | One artifact, many references. Fewer tags, immutable. |

The current per-env-suffix scheme is the thing that breaks single-artifact: the
`-dev` / `-qa` suffix forces (or implies) a separate artifact per environment.

## 10. Migration plan (current → single-artifact)

Incremental, low-risk, app-by-app:

1. **CI: stop suffixing.** Change each app's `bitbucket-pipelines.yml` to push a
   single immutable tag `<N>` (or `git-<shortsha>`) with **no `-env`**. Keep
   pushing `-dev` temporarily during transition if needed.
2. **Harbor: enable tag immutability** on the `example` project; set a
   rollback-safe retention policy.
3. **Chart: support digest pinning.** Ensure `platform` renders
   `image: {{ .repo }}{{ if .digest }}@{{ .digest }}{{ else }}:{{ .tag }}{{ end }}`
   so `values-patch.yaml` can carry an optional `image.digest`. (Verify current
   template; add if missing.)
4. **Dev automation: drop the suffix filter.** Update `ImagePolicy` filter to
   select newest `<N>` (no `-${image_tag_suffix}`); have
   `ImageUpdateAutomation` write tag **and** digest. (Flux image-reflector can
   reflect digests.)
5. **Promotion: copy tag+digest** in the promotion PR (§6) instead of minting a
   new `<N>-<env>` tag. Update `05-promotions.md` once cut over.
6. **Retire `image_tag_suffix`** from `cluster-config-<env>` once no policy or
   tag depends on it.
7. **Optional hardening:** cosign signing + admission verification; gate
   promotion on Trivy scan results.

Do one app end-to-end (e.g. `sample-app`) as a pilot, confirm dev→qa→prod runs one
digest, then roll out to the rest.

## 11. TL;DR

- Build **once**, get a digest, promote **that digest** dev → qa → uat → prod.
- The environment is chosen by *which env's `values-patch.yaml` pins the digest*,
  not by a tag suffix.
- Promotion = a PR copying `tag + digest` from the lower env to the higher env.
  No rebuild, no retag.
- Harbor holds one immutable artifact; Flux deploys it everywhere; rollback is a
  git revert to a previous digest.
- The migration from today is mostly "stop adding `-env` to tags + pin digests +
  make Harbor tags immutable."
