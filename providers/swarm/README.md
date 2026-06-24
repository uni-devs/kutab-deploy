# Swarm Provider

This provider is the current production target while the team does not have
Kubernetes expertise. It implements the V2 deployment shape with Docker Swarm:

- one shared infrastructure stack per cluster
- one isolated runtime stack per tenant
- database/user naming derived per tenant
- one scheduler per tenant
- shared overlay network for ingress
- tenant-internal overlay network per tenant stack
- secrets preserved by default
- Traefik + Let's Encrypt at the edge

## Console

Driven by the provider-aware console — see **[deployment/README.md](../../README.md#console-kutab-deploy)**.
Swarm actions (`kutab-deploy swarm <action>`) are the scripts in `scripts/`:
`bootstrap-cluster`, `join-swarm`, `deploy-infra`, `setup-db`, `deploy-tenant`,
`deploy-whatsapp`, `update-deployment`, `autoscaler`. Back-compat aliases
(`bootstrap-swarm`, `infra`, `deploy-tenant`, `whatsapp`, `update`, …) still work.

**Node roles.** A *shared* node hosts pooled tenants + central monitoring; a
*client* node is dedicated to one client (labelled `kutab.client=<name>`, pools =
`<name>`). Swarm labels are applied from a manager — when a worker joins,
`join-swarm` prints the `bootstrap-swarm --node <host> --role …` line to run on a manager.

**Autoscaling.** Static right-sizing (replica counts + CPU/mem reservations &
limits) ships in every stack. For a client node you can additionally enable a
lightweight CPU autoscaler (`autoscaler.sh`, a systemd timer that scales replicas
via Prometheus) — Swarm has no native HPA.

**Config sync.** `sync-config` encrypts `secrets/` + `envs/` with **SOPS + age**
before committing; plaintext stays git-ignored. The age private key lives at
`~/.config/sops/age/keys.txt` — **back it up**, or snapshots can't be decrypted.

## First Node Bootstrap

```bash
deployment/bin/kutab-deploy bootstrap-swarm --advertise-addr <ip> --role shared
# or the script directly:
deployment/providers/swarm/scripts/bootstrap-cluster.sh app.example.com
```

This initializes Swarm if needed, labels the current node (shared or per-client
pools), creates the shared overlay network, and prepares provider directories.

## Deploy Infrastructure

```bash
deployment/providers/swarm/scripts/deploy-infra.sh ops.example.com ops@example.com
```

Expected public tools:

- `traefik.ops.example.com`
- `portainer.ops.example.com`
- `grafana.ops.example.com`
- `prometheus.ops.example.com`

Credentials are written to:

```text
deployment/providers/swarm/envs/infrastructure/access.txt
```

## Deploy Tenant

The Swarm deploy uses `docker stack deploy --with-registry-auth` so every node
can pull the private Kutab images from GHCR. On the server user that runs the
Control Plane/deployment scripts, Docker must be logged in with a Linux-valid
credential config:

```bash
echo '<github-token>' | docker login ghcr.io -u '<github-user>' --password-stdin
```

If the server Docker config was copied from Docker Desktop, remove entries such
as `credsStore: desktop.exe` or `credHelpers.ghcr.io: desktop.exe` from
`~/.docker/config.json` first. Those helpers only exist on Docker Desktop and
will break Swarm deploys on Linux.

```bash
deployment/providers/swarm/scripts/deploy-tenant.sh quranswift \
  --platform-base-domain app.example.com \
  --display-name "Quran Swift"
```

Managed domains:

- frontend: `quranswift.app.example.com`
- API: `api.quranswift.app.example.com`
- websocket: `ws.quranswift.app.example.com`

Custom frontend domain:

```bash
deployment/providers/swarm/scripts/deploy-tenant.sh quranswift \
  --platform-base-domain app.example.com \
  --custom-domain quran.example.org
```

## Node Pools

For one node, bootstrap labels the current node as:

- `kutab.app=true`
- `kutab.db=true`
- `kutab.cache=true`
- `kutab.monitoring=true`
- `kutab.app_pool=shared`
- `kutab.db_pool=shared`
- `kutab.cache_pool=shared`

For a dedicated client node, label the node with a custom pool:

```bash
docker node update \
  --label-add kutab.app=true \
  --label-add kutab.db=true \
  --label-add kutab.cache=true \
  --label-add kutab.app_pool=quranswift \
  --label-add kutab.db_pool=quranswift \
  --label-add kutab.cache_pool=quranswift \
  <node>
```

Then deploy with:

```bash
deployment/providers/swarm/scripts/deploy-tenant.sh quranswift \
  --platform-base-domain app.example.com \
  --app-pool quranswift \
  --db-pool quranswift \
  --cache-pool quranswift
```

## Notes

- Existing env files are reused by default.
- Existing Docker secrets are preserved by default.
- Use `--force-env` only when intentionally regenerating tenant env files.
- Use `--force-secrets` only for intentional secret rotation.
- Migrations run as an explicit one-off job after stack deploy unless
  `--skip-migrate` is passed.

## Monitoring Baseline

The infrastructure stack provisions:

- Prometheus with Swarm service discovery
- node-exporter for node CPU, memory, filesystem, and network metrics
- cAdvisor for container resource usage
- Grafana datasources and dashboards
- Prometheus alert rules for tenant target down, failed jobs, queue backlog,
  traffic spikes, 5xx errors, high container CPU, and low disk space

Tenant nginx services are labeled for Prometheus and scrape the backend
`/metrics` endpoint internally. New tenant env files include:

```text
KUTAB_TENANT_NAME=<tenant>
METRICS_ENABLED=true
```

After updating a running cluster, redeploy infrastructure and then redeploy each
tenant stack so the new exporter services, scrape labels, and tenant metrics env
are applied.
