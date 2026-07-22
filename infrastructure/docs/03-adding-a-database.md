# 03 — Databases

There is **no separate workflow** for adding a database. The app's `values.yaml` declares it, the chart provisions it.

```yaml
database:
  enabled: true
  envStyle: postgres                # spring | postgres | none
                                    #   spring   → SPRING_DATASOURCE_{USERNAME,PASSWORD,URL}
                                    #   postgres → POSTGRES_{USER,PASSWORD,HOST,PORT,DB}
                                    #   none     → only the default envFrom (raw keys)
  owns:
    name: sample_service            # database name
    extensions: [pgcrypto]          # CREATE EXTENSION IF NOT EXISTS ...
    schemas: [reporting]            # CREATE SCHEMA IF NOT EXISTS ... AUTHORIZATION owner
  reads:
    - sample_core                      # read-only access onto other apps' DBs
    - sample_finance
```

Regardless of `envStyle`, the chart always adds an `envFrom: secretRef:` for the creds Secret, which exposes the raw keys (`username`, `password`, `host`, `port`, `dbname`, `uri`, `jdbc-uri`) as env vars with those literal names. `envStyle` just adds the conventional aliases on top.

## What gets created when

| Resource | Where | When | Lifecycle |
|---|---|---|---|
| Role `<component>-app` | CNPG cluster | first install of the app | persists across uninstalls |
| Database `<owns.name>` | CNPG cluster | first install | persists across uninstalls |
| Secret `${pg_cluster}-<component>-app` | app namespace | first install | kept on uninstall (`helm.sh/resource-policy: keep`) |
| ServiceAccount + Role + RoleBinding | app namespace | every install | recreated each release |
| Job `<release>-db-bootstrap` | app namespace | every install/upgrade (helm hook) | TTL 1h after success |

The password is generated on the very first run (32 chars, base64-tr). Every subsequent bootstrap run **reuses** the existing password by reading it from the Secret. Re-running the Job is safe.

## Cross-DB reads

When `reads: [foo, bar]`, the bootstrap Job connects as superuser to each named DB and runs:

```sql
GRANT CONNECT ON DATABASE foo TO <reader-role>;
GRANT USAGE   ON SCHEMA public TO <reader-role>;
GRANT SELECT  ON ALL TABLES IN SCHEMA public TO <reader-role>;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO <reader-role>;
```

So the reading app gets `SELECT` on existing AND future tables under `public`. Other schemas need separate grants — declare them on the owning app's `database.owns.schemas` and use a separate grants Job if needed.

## What happens if I disable / remove the database

`database.enabled: false` (or removing the app from the env overlay) does **not** drop the database or revoke the role. By design — we protect against accidental data loss. To actually clean up:

```bash
kubectl -n postgresql exec -it postgres-1 -- psql -U postgres <<-SQL
  DROP DATABASE "sample_service";
  DROP ROLE "my-service-app";
SQL
kubectl -n app-<env> delete secret postgres-my-service-app
```

## When the bootstrap Job fails

```bash
kubectl -n app-<env> logs job/<release>-db-bootstrap
```

Common failures:

| Symptom | Cause | Fix |
|---|---|---|
| `could not translate host name "postgres-rw"` | Reflector hasn't mirrored the superuser secret | check `kubectl -n reflector logs deploy/reflector` and the `reflector.v1.k8s.emberstack.com` annotations on `postgres-superuser` in `postgresql` |
| `permission denied for database` | bootstrap ran on the wrong cluster (wrong PG superuser) | confirm `global.pgCluster` in the chart matches `cluster-config.pg_cluster` |
| `relation "..." already exists` during `CREATE EXTENSION` | benign on re-runs | the script uses `IF NOT EXISTS`; if you see this with a hard error, your extension list contains a typo |
| Job hangs at `CONNECT` | NetworkPolicy blocks cross-namespace | open `egress` from the app namespace to `postgresql/5432` |

If the role's password got out-of-sync (e.g. someone changed it manually in psql), delete the Secret and re-trigger the Job:

```bash
kubectl -n app-<env> delete secret postgres-my-service-app
flux reconcile helmrelease my-service -n flux-system --with-source
```

The Job will mint a new password, ALTER the role to match, and rewrite the Secret. Reloader rolls the pod.

## Why not the CNPG `Database` CRD?

The `Database` CRD requires the owner role to pre-exist (managed centrally in `Cluster.spec.managed.roles`). That re-introduces the duplication this refactor is designed to remove — every new app would have to be added to BOTH its own values AND `infrastructure/configs/pg-cluster.yaml`. The bootstrap Job pattern keeps the declaration in one place at the cost of a 60-line shell script that runs once per release.
