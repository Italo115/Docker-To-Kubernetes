# 06 — Cluster bootstrap

**One bootstrap, one cluster.** All four envs (dev/qa/uat/prod) run as tenants of `clusters/my-cluster/`.

## Prerequisites

- `flux` CLI installed locally (`brew install fluxcd/tap/flux`)
- `kubectl` access to the cluster (`KUBECONFIG` set)
- SSH key registered in Bitbucket that can read this repo
- The GPG private key for SOPS (see `04-secrets.md` for export)
- Node labels applied to the cluster (see "Node pool labels" below)

## Node pool labels

Before bootstrapping, label each node by pool. Soft pinning only — no taints.

```bash
# Replace <node-N> with the actual node names from `kubectl get nodes`.
kubectl label node <infra-node-1> workload=infrastructure
kubectl label node <postgres-node-1> workload=postgres
# dev pool spans two nodes — app-dev pods schedule on either.
kubectl label node <node-name> workload=dev
kubectl label node node-0 workload=dev
kubectl label node <prod-node-1> workload=prod
```

Confirm:

```bash
kubectl get nodes -L workload
```

## Bootstrap the cluster

```bash
export KUBECONFIG=~/.kube/my-cluster

flux bootstrap git \
  --url=ssh://git@bitbucket.org/my-org/infrastructure.git \
  --branch=main \
  --path=clusters/my-cluster \
  --private-key-file=~/.ssh/id_rsa \
  --components-extra=image-reflector-controller,image-automation-controller
```

When prompted *"Please give the key access to your repository?"* answer `y` — the key is already authorised in Bitbucket.

This:
- creates the `flux-system` namespace + Flux controllers (with image automation)
- writes `clusters/my-cluster/flux-system/{gotk-components,gotk-sync,kustomization}.yaml` and pushes them
- starts reconciling `clusters/my-cluster/`, which fans out to four `apps-<env>`, four `secrets-<env>`, plus `infrastructure` + `infrastructure-configs` + `secrets-infrastructure`

For dev work pre-merge, append `--branch=<feature-branch>` to target a non-main branch.

## Install the SOPS GPG key in the new cluster

Flux can't decrypt secrets until this exists:

```bash
# On a machine that has the private key
gpg --export-secret-keys --armor <YOUR_GPG_FINGERPRINT> | \
  kubectl create secret generic sops-gpg \
    --namespace=flux-system \
    --from-file=sops.asc=/dev/stdin
```

If your local key is on another machine, transfer the ASCII-armored export via a secure channel (1Password / Vault / `gpg --export-secret-keys --armor ... | wormhole send`). Don't email it.

## Verify

```bash
flux get sources git
flux get kustomization
# apps-dev, apps-qa, apps-uat, apps-prod, infrastructure, infrastructure-configs,
# secrets-infrastructure, secrets-dev/-qa/-uat/-prod, flux-system — all Ready=True

# Per-env app namespaces
for env in dev qa uat prod; do
  kubectl -n app-$env get pods
done

# Where each tier landed
kubectl get pods -A -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName | sort -k3
```

If `secrets-*` is stuck with `Error: Decryption failed`, the GPG key isn't in `flux-system/sops-gpg`. See `04-secrets.md`.

## Optional: pre-commit hook to prevent unencrypted secrets

In every clone of this repo:

```bash
cat > .git/hooks/pre-commit <<-'SH'
#!/usr/bin/env bash
set -e
for f in $(git diff --cached --name-only --diff-filter=ACM | grep -E '^secrets/.*\.yaml$' || true); do
  if ! grep -q '^sops:' "$f"; then
    echo "REFUSED: $f looks unencrypted (no 'sops:' block). Run: sops -e -i $f"
    exit 1
  fi
done
SH
chmod +x .git/hooks/pre-commit
```

## Rebootstrap (e.g. migrating from per-env clusters)

```bash
# Wipe existing Flux state (also prunes everything Flux owns)
flux uninstall --namespace=flux-system --silent

# (Optional) drop existing app namespaces if you want a fully clean slate
kubectl delete ns app-dev app-qa app-uat app-prod 2>/dev/null

# Bootstrap onto the new clusters/my-cluster path
flux bootstrap git \
  --url=ssh://git@bitbucket.org/my-org/infrastructure.git \
  --branch=main \
  --path=clusters/my-cluster \
  --private-key-file=~/.ssh/id_rsa \
  --components-extra=image-reflector-controller,image-automation-controller

# Re-install the sops-gpg secret (see above)
```

`prune: true` on every Flux Kustomization means re-bootstrapping picks up cleanly.

## Adding a new environment

To add a fifth tenant (say `loadtest`) to the existing cluster:

```bash
# 1. Per-env substitution ConfigMap
cp clusters/my-cluster/cluster-config-qa.yaml clusters/my-cluster/cluster-config-loadtest.yaml
# Edit: environment, app_namespace, image_tag_suffix, workload_pool

# 2. Per-env Flux Kustomizations
cp clusters/my-cluster/apps-qa.yaml      clusters/my-cluster/apps-loadtest.yaml
cp clusters/my-cluster/secrets-qa.yaml   clusters/my-cluster/secrets-loadtest.yaml
# Edit names + substituteFrom to point at cluster-config-loadtest and paths to apps/loadtest, secrets/loadtest

# 3. Apps overlay
mkdir apps/loadtest
echo 'apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []' > apps/loadtest/kustomization.yaml

# 4. Secrets overlay
mkdir secrets/loadtest
cat > secrets/loadtest/kustomization.yaml <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: loadtest
resources:
  - ../0-base
YAML
```

Commit + push. Flux picks up the new Kustomizations on the next reconcile — no second bootstrap.
