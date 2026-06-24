# Kutab Deployment Platform V2

This folder is the new deployment-platform home. The old script-first flow lives in
`old/prod-deployment` and should be treated as a compatibility adapter only.

The Control Plane owns tenant intent and deployment operations. Providers translate
that desired state into concrete infrastructure actions.

## Console (`kutab-deploy`)

`deployment/bin/kutab-deploy` is the provider-aware operator console. No args → an
interactive **gum** TUI (it offers to install gum if missing, then prints help if
declined); or run a subcommand to script it. General actions live at the root;
provider-specific actions under each provider.

```text
deployment/
  bin/kutab-deploy        console
  lib/                    common.sh · tui.sh · providers.sh
  scripts/                bootstrap-vm · preflight · sync-config   (provider-agnostic)
  providers/
    swarm/   provider.sh + scripts/ templates/ configs/ envs/ secrets/
    compose/ provider.sh + scripts/ templates/ envs/ secrets/
```

General (any provider):

```bash
kutab-deploy bootstrap-vm     # packages · Docker · ufw · fail2ban · auto-updates · gum/sops/age
kutab-deploy preflight        # prerequisite check
kutab-deploy sync-config --remote <git-url>   # SOPS/age-encrypted config+secret snapshot
```

Providers — `kutab-deploy <provider> <action> [args]` (actions = scripts under
`providers/<provider>/scripts/`):

```bash
# swarm = the shared, pooled multi-tenant cluster
kutab-deploy swarm deploy-tenant acme --platform-base-domain kutab.app --app-pool shared
# compose = one dedicated box per client (scaling is just `compose up --scale`)
kutab-deploy compose deploy acme --tenant-domain acme.com --acme-email ops@acme.com
kutab-deploy compose scale  acme --backend 3 --worker 2
```

**Which provider:** use **swarm** for the shared cluster; **compose** for a client on
their own node. A client can alternatively join the swarm as a labelled worker
(`kutab-deploy swarm bootstrap-swarm --role client --client-name X`). `sync-config`
encrypts every `providers/*/{secrets,envs}` with SOPS+age — the age key at
`~/.config/sops/age/keys.txt` must be backed up or snapshots can't be decrypted.

Adding a future provider = a new `providers/<name>/provider.sh` (name/desc +
`provider_actions`/`provider_flow`) and its `scripts/`; the console discovers it
automatically.

## Runtime Model

- Default tenant isolation: one runtime stack per tenant.
- Default data isolation: one database and database user per tenant.
- Default infrastructure: self-hosted first, with provider interfaces kept portable.
- Strategic direction: Kubernetes-compatible specs, even when the first adapter runs
  Compose or Swarm.

## Provider Contract

Every provider should implement this lifecycle:

1. `plan` builds a `TenantRuntimeSpec` and ordered deployment steps.
2. `apply` executes the plan or returns a dry-run result.
3. `inspect` reports runtime state and health metadata.
4. `rollback` rolls back to a known deployment operation.
5. `destroy` removes runtime resources only after backup and retention checks.

## Tenant Runtime Spec

The runtime spec is intentionally provider-neutral. It contains:

- tenant identity and release channel
- frontend, API, websocket, and custom frontend domains
- image references
- database provider/name/user/secret reference
- cache provider/namespace
- storage provider/scope/secret reference
- runtime secret references
- replicas
- feature flags
- health checks

Secret values must not be written to Git or logs. Store references only.

## First Provider

The first provider is Docker Swarm. It lives in:

```text
deployment/providers/swarm
```

Use it for the current production phase while the team is not ready to operate
Kubernetes.

## Next Provider Targets

- `self_hosted_kubernetes`: namespaces, secrets, config maps, jobs, ingress.
- `dedicated_vm`: isolated VM/node using the same `TenantRuntimeSpec`.
- `managed_cloud`: ECS/Fargate or managed Kubernetes once the team is ready.

## Operator Rules

- Do not run tenant migrations automatically on app container boot.
- Do not store secret values in generated manifests.
- Make every operation idempotent and auditable.
- Prefer image digests for production releases.
- Keep CLI output machine-readable with a `--json` option.
