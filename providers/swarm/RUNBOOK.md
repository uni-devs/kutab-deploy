# Kutab Swarm — Live Bring-Up Runbook

Ordered procedure for standing up the cluster on real servers and onboarding the
first tenant. Reference material lives in [README.md](./README.md); this file is
the step-by-step you actually follow on the day.

Run every command from the repository root on the **manager** node, as the user
that owns the deployment (the same user the Control Plane runs as).

---

## 0. Prerequisites (per node)

- Docker Engine installed and running.
- Outbound 443 (Let's Encrypt) and the Swarm ports open between nodes:
  `2377/tcp` (management), `7946/tcp+udp` (gossip), `4789/udp` (overlay).
- On the manager, these CLIs: `openssl`, `htpasswd` (`apt install apache2-utils`).
- Docker logged in to GHCR so nodes can pull private images:

  ```bash
  echo '<github-token>' | docker login ghcr.io -u '<github-user>' --password-stdin
  ```

  If `~/.docker/config.json` was copied from Docker Desktop, remove any
  `credsStore: desktop.exe` / `credHelpers` entries first — they break Linux Swarm pulls.

---

## 1. Bootstrap the first node (Phase 0 — single node)

```bash
deployment/providers/swarm/scripts/bootstrap-cluster.sh <manager-public-ip-or-host>
```

This initialises Swarm, labels the node for **all** roles
(`kutab.app/db/cache/monitoring`, `*_pool=shared`), creates the `kutab-shared`
overlay network, and prepares the `configs/`, `envs/`, and `secrets/` directories.

**Verify:**

```bash
docker node ls
docker node inspect self --format '{{ .Spec.Labels }}'
docker network inspect kutab-shared --format '{{.Driver}} {{.Scope}} {{.Attachable}}'   # overlay swarm true
```

---

## 2. Deploy the shared infrastructure stack

```bash
deployment/providers/swarm/scripts/deploy-infra.sh <ops-domain> <acme-email>
```

Generates all monitoring/ingress configs (Traefik, Prometheus + alert rules,
**Alertmanager**, Loki, Promtail, Grafana, node-exporter, cAdvisor, Portainer),
creates secrets, and deploys the `kutab-infra` stack. Admin credentials are
written to `deployment/providers/swarm/envs/infrastructure/access.txt`.

**Verify (allow ~1–2 min for TLS issuance):**

```bash
docker stack services kutab-infra        # every service REPLICAS = n/n
```

- `https://prometheus.<ops-domain>/targets` → prometheus, traefik, node-exporter,
  cadvisor all **UP** (tenant targets appear after step 4).
- `https://prometheus.<ops-domain>/alerts` → rules loaded (including
  `KutabBackendExceptions` / `KutabBackendExceptionSpike`).
- `https://alertmanager.<ops-domain>` → reachable (basic-auth = the `monitor` user
  in `access.txt`).
- `https://grafana.<ops-domain>` → log in with the Grafana creds from `access.txt`.

---

## 3. Wire alert delivery (one-time)

Edit `deployment/providers/swarm/configs/alertmanager/alertmanager.yml`, fill in
**one** receiver block (Slack / webhook / email), then re-run step 2 (existing
secrets are preserved). Confirm a test alert is delivered, e.g.:

```bash
# Fire a throwaway alert straight at Alertmanager from the manager:
docker run --rm --network kutab-shared curlimages/curl -s -XPOST \
  http://alertmanager:9093/api/v2/alerts \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"PingTest","severity":"warning","tenant":"smoke"}}]'
```

> Until a receiver is filled in, alerts still show in the Alertmanager UI but no
> notification is sent — the default receiver is intentionally a no-op.

---

## 4. Provision the first tenant

```bash
deployment/providers/swarm/scripts/deploy-tenant.sh <slug> \
  --platform-base-domain <ops-domain> \
  --display-name "<Display Name>"
```

Deploys the tenant stack `kutab-<slug>` and runs migrations as a one-off job.
Managed hosts: `<slug>.<ops-domain>` (frontend), `api.<slug>.<ops-domain>`,
`ws.<slug>.<ops-domain>`. For a custom domain add `--custom-domain <fqdn>`.

**Verify:**

```bash
docker stack services kutab-<slug>       # all services healthy
```

- Frontend and API load over HTTPS.
- `https://prometheus.<ops-domain>/targets` → the tenant's `kutab-tenants` target is UP.
- **Logs reach Loki:** in Grafana → Explore → Loki, query the tenant's containers
  and confirm application log lines appear (this works because the tenant env now
  sets `LOG_CHANNEL=stderr`).

---

## 5. Verify backend exception monitoring

Trigger a single, harmless backend error (e.g. hit a route that throws in a
non-production check, or run a tinker snippet that reports an exception), then:

- `https://prometheus.<ops-domain>` → query `kutab_exceptions_total` and
  `kutab_exceptions_by_type_total` → the counter increments for the tenant.
- Grafana → Loki → filter the tenant's container at level `ERROR` → the stack
  trace is searchable.
- On the DB/app node, the tenant's `storage/logs/exceptions.log` (inside the
  backend container / `backend-logs` volume) holds a focused exception log.

Remove the test trigger afterwards.

---

## 6. Scale out (Phase 1 — split the shared DB node)

When the second tenant is onboarded, separate the data tier onto its own node
(the recommended near-term topology). On the **new** node, join the Swarm
(`docker swarm join ...` using `docker swarm join-token`), then from the manager:

```bash
# New node = shared DB + cache only:
docker node update \
  --label-add kutab.db=true --label-add kutab.cache=true \
  --label-add kutab.db_pool=shared --label-add kutab.cache_pool=shared \
  <new-node>

# Original node = app + monitoring only (drop the data-tier labels):
docker node update \
  --label-rm kutab.db --label-rm kutab.cache \
  <original-node>
```

Redeploy the infra stack and each tenant stack so the MySQL/Valkey containers
reschedule onto the DB node. Continue adding **app** nodes (`kutab.app=true`,
distinct `kutab.app_pool`) and raising `*_REPLICAS` as load grows; see the
architecture document's growth-path table for Phases 2–3.

---

## Rollback / safety notes

- `deploy-infra.sh` and `deploy-tenant.sh` **preserve** existing secrets and env
  files by default. Use `--force-secrets` / `--force-env` only when intentionally
  rotating.
- Config files under `configs/` are regenerated by `deploy-infra.sh` on each run —
  edit the heredocs in the script (the source of truth), not just the rendered files,
  for changes that must survive a redeploy. (The Alertmanager receiver in step 3 is
  the exception you edit in-place, then re-run.)
- A failed tenant deploy can be removed with `docker stack rm kutab-<slug>`; volumes
  (`mysql-data`, `valkey-data`) survive unless explicitly pruned.
