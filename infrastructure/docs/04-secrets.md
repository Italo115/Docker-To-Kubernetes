# 04 — Secrets

**SOPS is for human-authored secrets only.** Database credentials, image-pull secrets, and any K8s Secret that an operator manages live elsewhere.

| Type | Where | Encryption | Who creates it |
|---|---|---|---|
| Postgres app role + password | `platform` bootstrap Job → Secret in app namespace | none (in-cluster) | Helm chart |
| Postgres superuser | CNPG-generated `${pg_cluster}-superuser` | none (in-cluster) | CNPG operator |
| OAuth client secret, API token, third-party key | `secrets/<n-env>/<file>.yaml` | SOPS / GPG | Human edits via `sops <file>` |

The CNPG superuser Secret is annotated for cross-namespace mirroring (see `infrastructure/configs/pg-cluster.yaml#inheritedMetadata`); Reflector clones it into every namespace that runs an app with `database.enabled: true`.

## Bootstrap your local GPG keyring

```bash
export KUBECONFIG=~/.kube/<cluster>

# Pull the cluster's GPG private key (used by Flux to decrypt secrets/)
kubectl -n flux-system get secret sops-gpg -o jsonpath='{.data.sops\.asc}' | base64 -d | gpg --import

# Verify
gpg --list-secret-keys --keyid-format long
# expect fingerprint <YOUR_GPG_FINGERPRINT>
```

The repo-root `.sops.yaml` declares the fingerprint and `encrypted_regex`, so `sops` finds the right key automatically.

## Common operations

```bash
# Add a new secret
cat > secrets/<n-env>/my-secret.yaml <<-YAML
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: app-<env>
stringData:
  TOKEN: "the-actual-value"
YAML
sops -e -i secrets/<n-env>/my-secret.yaml
echo '  - my-secret.yaml' >> secrets/<n-env>/kustomization.yaml

# Edit an existing secret (auto-decrypt → editor → auto-re-encrypt)
sops secrets/<n-env>/my-secret.yaml

# Decrypt to stdout for inspection
sops -d secrets/<n-env>/my-secret.yaml

# Remove
git rm secrets/<n-env>/my-secret.yaml
# also remove from secrets/<n-env>/kustomization.yaml
```

`secrets/<n-env>/kustomization.yaml` enumerates each file explicitly — there is no glob. If a file isn't in the list, Flux doesn't apply it. That's the safety net.

## Multi-namespace secrets

If a secret must exist in multiple namespaces (e.g. `harbor-pull` needs to be in `flux-system` and `app-<env>`), include the manifest **twice in the same file** with `---` between documents — once per namespace. SOPS encrypts each document independently.

For secrets that exist in many namespaces, prefer the **Reflector** pattern instead: declare the Secret once in `secrets/<n-env>/`, add the `reflector.v1.k8s.emberstack.com/reflection-allowed: "true"` annotation, and Reflector mirrors it.

## What if I committed a secret unencrypted by accident?

The secret is leaked the moment it lands in Git. Rotation is the only fix:

1. Revoke / rotate the credential at the source (the third party / IdP / whatever).
2. Force-purge the file from history with `git filter-repo --path secrets/<n-env>/<file>.yaml --invert-paths` and force-push.
3. Tell anyone who's cloned the repo to re-clone — their reflogs still have it.

Pre-commit hook to prevent recurrence: `.git/hooks/pre-commit` running `sops -d -i` on each staged `secrets/**/*.yaml` (fails if the file isn't encrypted). See `06-bootstrap.md`.

## Layout

```
secrets/
├── 0-base/            ← app secrets that are the SAME across envs
│   └── *.yaml         (each baked with namespace: app-dev inside SOPS; rewritten per env)
├── 5-infrastructure/  ← cluster-level secrets used by controllers
│   ├── harbor-pull.yaml       (Harbor dockerconfigjson)
│   ├── cloudflare-api.yaml    (cert-manager DNS-01 token)
│   └── minio-secret.yaml      (MinIO root creds)
└── 1-dev/  2-qa/  3-uat/  4-prod/     ← per-env applications of ../0-base
    └── kustomization.yaml     (namespace: app-<env>; resources: [../0-base])
```

`secrets/5-infrastructure/` is applied **once** by the cluster-wide `secrets-infrastructure` Flux Kustomization (`clusters/my-cluster/secrets-infrastructure.yaml`). Per-env kustomizations do NOT import it — that would double-apply identical Secrets.

Each per-env `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: app-<env>          # ← rewrites the namespace of every imported Secret
resources:
  - ../0-base
# - local-overrides.yaml      (add files here ONLY when an env needs a different value)
```

The `namespace:` field is a Kustomize transformer that runs AFTER Flux's SOPS decryption. The decrypted YAML carries `namespace: app-dev`; Kustomize overwrites it with `app-<env>` before applying. **No SOPS re-encryption is needed to put the same secret into all four envs.**

Adding a secret used by every env: drop it in `secrets/0-base/` and list it in `secrets/0-base/kustomization.yaml`. No per-env edits.

Adding a secret used by only one env: drop it in `secrets/<n-env>/` and list it in that env's `kustomization.yaml` (alongside the `../0-base` import).

## Note on the embedded namespace

The SOPS-encrypted Secrets contain `namespace: app-dev` inside the ciphertext. That's irrelevant — the per-env kustomization's `namespace:` transformer overrides whatever the file says at apply time. If you ever change the convention (e.g. add a fifth env), you only need to create `secrets/<n-new-env>/kustomization.yaml` with the right `namespace:` field; the SOPS files stay untouched.

## DB creds

Not here. CNPG generates the role + password per app; the chart writes the connection Secret in the app's namespace. SOPS never sees a DB password.
