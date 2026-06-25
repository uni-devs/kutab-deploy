#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"   # node_state_* (local helpers below still win)
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"

CLUSTER_DOMAIN="${1:-}"
ACME_EMAIL="${2:-}"
FORCE_SECRETS=false
DRY_RUN=false

shift $(( $# >= 1 ? 1 : 0 ))
shift $(( $# >= 1 ? 1 : 0 ))

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-secrets) FORCE_SECRETS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '1,120p' "$PROVIDER_ROOT/README.md"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
password() { openssl rand -base64 36 | tr -d '/+=' | head -c 32; }

[[ -n "$CLUSTER_DOMAIN" && -n "$ACME_EMAIL" ]] || fail "Usage: $0 <cluster-domain> <acme-email> [--force-secrets] [--dry-run]"
command -v docker >/dev/null || fail "docker is required"
command -v openssl >/dev/null || fail "openssl is required"
command -v htpasswd >/dev/null || fail "htpasswd is required. Install apache2-utils or httpd-tools."
docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active || fail "Swarm is not active. Run bootstrap-cluster.sh first."

"$SCRIPT_DIR/bootstrap-cluster.sh" >/dev/null

mkdir -p "$PROVIDER_ROOT/configs/traefik/auth"
mkdir -p "$PROVIDER_ROOT/configs/prometheus/rules" "$PROVIDER_ROOT/configs/grafana/provisioning/dashboards" "$PROVIDER_ROOT/configs/grafana/dashboards"
ACCESS_FILE="$DATA_ROOT/envs/infrastructure/access.txt"; mkdir -p "$(dirname "$ACCESS_FILE")"

ensure_secret() {
  local name="$1"
  local value="$2"
  if docker secret inspect "$name" >/dev/null 2>&1; then
    if [[ "$FORCE_SECRETS" != true ]]; then
      log "Keeping existing secret $name"
      return
    fi
    docker secret rm "$name" >/dev/null
  fi
  [[ "$DRY_RUN" == true ]] || printf '%s' "$value" | docker secret create "$name" - >/dev/null
  log "Created secret $name"
}

TRAEFIK_PASSWORD="$(password)"
PROMETHEUS_PASSWORD="$(password)"
GRAFANA_USER="admin"
GRAFANA_PASSWORD="$(password)"
PORTAINER_PASSWORD="$(password)"

if [[ "$DRY_RUN" != true ]]; then
  htpasswd -nb admin "$TRAEFIK_PASSWORD" > "$PROVIDER_ROOT/configs/traefik/auth/traefik.htpasswd"
  htpasswd -nb monitor "$PROMETHEUS_PASSWORD" > "$PROVIDER_ROOT/configs/traefik/auth/prometheus.htpasswd"
  ensure_secret grafana_admin_user "$GRAFANA_USER"
  ensure_secret grafana_admin_password "$GRAFANA_PASSWORD"
  ensure_secret portainer_admin_password "$(htpasswd -nbB admin "$PORTAINER_PASSWORD" | cut -d: -f2-)"
  chmod 600 "$PROVIDER_ROOT/configs/traefik/auth/"*.htpasswd
fi

cat > "$PROVIDER_ROOT/configs/traefik/dynamic/security.yml" <<'YAML'
http:
  middlewares:
    security-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: strict-origin-when-cross-origin
YAML

cat > "$PROVIDER_ROOT/configs/prometheus/prometheus.yml" <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 30s
rule_files:
  - /etc/prometheus/rules/*.yml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
  - job_name: traefik
    static_configs:
      - targets: ['traefik:8082']
  - job_name: node-exporter
    static_configs:
      - targets: ['tasks.node-exporter:9100']
  - job_name: cadvisor
    static_configs:
      - targets: ['tasks.cadvisor:8080']
  - job_name: kutab-tenants
    dockerswarm_sd_configs:
      - host: unix:///var/run/docker.sock
        role: tasks
    relabel_configs:
      - source_labels: ['__meta_dockerswarm_task_desired_state']
        regex: running
        action: keep
      - source_labels: ['__meta_dockerswarm_service_label_prometheus_scrape']
        regex: true
        action: keep
      - source_labels: ['__meta_dockerswarm_task_address', '__meta_dockerswarm_service_label_prometheus_port']
        separator: ':'
        target_label: __address__
      - source_labels: ['__meta_dockerswarm_service_label_prometheus_path']
        target_label: __metrics_path__
      - source_labels: ['__meta_dockerswarm_service_label_kutab_tenant']
        target_label: tenant
      - source_labels: ['__meta_dockerswarm_node_hostname']
        target_label: node
      - source_labels: ['__meta_dockerswarm_service_name']
        target_label: service
YAML

cat > "$PROVIDER_ROOT/configs/prometheus/rules/kutab-alerts.yml" <<'YAML'
groups:
  - name: kutab-platform
    rules:
      - alert: KutabTenantTargetDown
        expr: up{job="kutab-tenants"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Tenant metrics target is down"
          description: "Tenant {{ $labels.tenant }} on {{ $labels.node }} has not responded to Prometheus for 2 minutes."
      - alert: KutabHighFailedJobs
        expr: kutab_failed_jobs_last_hour_total > 5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High failed job count"
          description: "Tenant {{ $labels.tenant }} has more than 5 failed jobs in the last hour."
      - alert: KutabQueueBacklog
        expr: sum by (tenant, queue) (kutab_queue_jobs_total) > 100
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Queue backlog is growing"
          description: "Tenant {{ $labels.tenant }} queue {{ $labels.queue }} has more than 100 pending jobs."
      - alert: KutabHighContainerCpu
        expr: sum by (container_label_com_docker_swarm_service_name) (rate(container_cpu_usage_seconds_total[5m])) > 1.5
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High container CPU usage"
          description: "Service {{ $labels.container_label_com_docker_swarm_service_name }} is using high CPU."
      - alert: KutabNodeDiskFilling
        expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}) < 0.15
        for: 15m
        labels:
          severity: critical
        annotations:
          summary: "Node disk has less than 15% free space"
          description: "Disk {{ $labels.mountpoint }} on {{ $labels.instance }} is running low."
      - alert: KutabTrafficSpike
        expr: sum(rate(traefik_service_requests_total[5m])) > 50
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Traffic spike detected"
          description: "Traefik request rate is above the current baseline threshold."
      - alert: KutabHighHttpErrors
        expr: sum(rate(traefik_service_requests_total{code=~"5.."}[5m])) > 1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "HTTP 5xx errors detected"
          description: "Traefik is seeing sustained 5xx responses."
      - alert: KutabBackendExceptions
        expr: sum by (tenant) (increase(kutab_exceptions_total[15m])) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Backend exceptions are firing"
          description: "Tenant {{ $labels.tenant }} reported more than 10 backend exceptions in the last 15 minutes. Check Loki (tenant container, level ERROR) or storage/logs/exceptions.log on the node."
      - alert: KutabBackendExceptionSpike
        expr: sum by (tenant) (increase(kutab_exceptions_total[5m])) > 50
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Backend exception spike"
          description: "Tenant {{ $labels.tenant }} reported more than 50 backend exceptions in 5 minutes - likely an outage or a bad release."
YAML

mkdir -p "$PROVIDER_ROOT/configs/alertmanager"
cat > "$PROVIDER_ROOT/configs/alertmanager/alertmanager.yml" <<'YAML'
# Alertmanager routing for the Kutab platform.
#
# Out of the box this uses a no-op "default" receiver so the stack starts
# cleanly and alerts are still visible in the Alertmanager UI
# (https://alertmanager.<cluster-domain>, behind the prometheus-auth basic-auth).
# To actually get PAGED, fill in ONE of the receiver blocks below with your real
# Slack / webhook / email endpoint and redeploy the infra stack.
global:
  resolve_timeout: 5m
route:
  receiver: default
  group_by: ['alertname', 'tenant']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # Page faster for anything labelled critical.
    - matchers:
        - severity = "critical"
      receiver: default
      group_wait: 10s
      repeat_interval: 1h
receivers:
  - name: default
    # Option A: Slack
    # slack_configs:
    #   - api_url: "https://hooks.slack.com/services/XXXX/YYYY/ZZZZ"
    #     channel: "#kutab-alerts"
    #     send_resolved: true
    #
    # Option B: generic webhook (PagerDuty/Opsgenie bridge, etc.)
    # webhook_configs:
    #   - url: "https://example.com/alerts"
    #     send_resolved: true
    #
    # Option C: email
    # email_configs:
    #   - to: "ops@kutab.example.com"
    #     from: "alertmanager@kutab.example.com"
    #     smarthost: "smtp.example.com:587"
    #     auth_username: "alertmanager@kutab.example.com"
    #     auth_password: "CHANGE_ME"
    #     send_resolved: true
inhibit_rules:
  # A critical alert for a tenant silences the matching warning for the same tenant.
  - source_matchers: [severity = "critical"]
    target_matchers: [severity = "warning"]
    equal: ['tenant', 'alertname']
YAML

cat > "$PROVIDER_ROOT/configs/loki/loki-config.yml" <<'YAML'
auth_enabled: false
server:
  http_listen_port: 3100
common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
YAML

cat > "$PROVIDER_ROOT/configs/promtail/promtail-config.yml" <<'YAML'
server:
  http_listen_port: 9080
positions:
  filename: /tmp/positions.yaml
clients:
  - url: http://loki:3100/loki/api/v1/push
scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: ['__meta_docker_container_label_com_docker_swarm_service_name']
        target_label: service
      - source_labels: ['__meta_docker_container_label_kutab_tenant']
        target_label: tenant
      - source_labels: ['__meta_docker_container_id']
        target_label: container_id
YAML

cat > "$PROVIDER_ROOT/configs/grafana/provisioning/datasources/datasources.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
YAML

cat > "$PROVIDER_ROOT/configs/grafana/provisioning/dashboards/dashboards.yml" <<'YAML'
apiVersion: 1
providers:
  - name: Kutab
    orgId: 1
    folder: Kutab
    type: file
    disableDeletion: false
    updateIntervalSeconds: 60
    options:
      path: /etc/grafana/dashboards
YAML

cat > "$PROVIDER_ROOT/configs/grafana/dashboards/kutab-platform-overview.json" <<'JSON'
{
  "uid": "kutab-platform-overview",
  "title": "Kutab Platform Overview",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "tags": ["kutab", "platform"],
  "time": {"from": "now-6h", "to": "now"},
  "panels": [
    {"type": "stat", "title": "Tenant Targets Up", "gridPos": {"x": 0, "y": 0, "w": 6, "h": 4}, "targets": [{"expr": "sum(up{job=\"kutab-tenants\"})"}]},
    {"type": "stat", "title": "HTTP 5xx / min", "gridPos": {"x": 6, "y": 0, "w": 6, "h": 4}, "targets": [{"expr": "sum(rate(traefik_service_requests_total{code=~\"5..\"}[5m])) * 60"}]},
    {"type": "stat", "title": "Failed Jobs Last Hour", "gridPos": {"x": 12, "y": 0, "w": 6, "h": 4}, "targets": [{"expr": "sum(kutab_failed_jobs_last_hour_total)"}]},
    {"type": "stat", "title": "Pending Queue Jobs", "gridPos": {"x": 18, "y": 0, "w": 6, "h": 4}, "targets": [{"expr": "sum(kutab_queue_jobs_total)"}]},
    {"type": "timeseries", "title": "Requests by Service", "gridPos": {"x": 0, "y": 4, "w": 12, "h": 8}, "targets": [{"expr": "sum by (service) (rate(traefik_service_requests_total[5m]))"}]},
    {"type": "timeseries", "title": "Container CPU by Service", "gridPos": {"x": 12, "y": 4, "w": 12, "h": 8}, "targets": [{"expr": "sum by (container_label_com_docker_swarm_service_name) (rate(container_cpu_usage_seconds_total[5m]))"}]},
    {"type": "timeseries", "title": "Node Memory Available", "gridPos": {"x": 0, "y": 12, "w": 12, "h": 8}, "targets": [{"expr": "node_memory_MemAvailable_bytes"}]},
    {"type": "timeseries", "title": "Node Disk Free %", "gridPos": {"x": 12, "y": 12, "w": 12, "h": 8}, "targets": [{"expr": "100 * node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay\"}"}]}
  ]
}
JSON

cat > "$PROVIDER_ROOT/configs/grafana/dashboards/kutab-tenant-operations.json" <<'JSON'
{
  "uid": "kutab-tenant-operations",
  "title": "Kutab Tenant Operations",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "tags": ["kutab", "tenant"],
  "time": {"from": "now-7d", "to": "now"},
  "templating": {
    "list": [
      {"name": "tenant", "type": "query", "datasource": "Prometheus", "query": "label_values(kutab_app_info, tenant)", "refresh": 1}
    ]
  },
  "panels": [
    {"type": "stat", "title": "Users", "gridPos": {"x": 0, "y": 0, "w": 6, "h": 4}, "targets": [{"expr": "sum(kutab_users_total{tenant=\"$tenant\"})"}]},
    {"type": "stat", "title": "Active Subscriptions", "gridPos": {"x": 6, "y": 0, "w": 6, "h": 4}, "targets": [{"expr": "sum(kutab_subscriptions_total{tenant=\"$tenant\",status=\"active\"})"}]},
    {"type": "stat", "title": "Open Tickets", "gridPos": {"x": 12, "y": 0, "w": 6, "h": 4}, "targets": [{"expr": "sum(kutab_support_tickets_total{tenant=\"$tenant\",status=~\"open|pending\"})"}]},
    {"type": "stat", "title": "Active Sessions", "gridPos": {"x": 18, "y": 0, "w": 6, "h": 4}, "targets": [{"expr": "sum(kutab_active_sessions_total{tenant=\"$tenant\"})"}]},
    {"type": "barchart", "title": "Lecture Peak Hours UTC", "gridPos": {"x": 0, "y": 4, "w": 12, "h": 8}, "targets": [{"expr": "sum by (hour) (kutab_lecture_peak_hour_total{tenant=\"$tenant\"})"}]},
    {"type": "timeseries", "title": "Lecture States", "gridPos": {"x": 12, "y": 4, "w": 12, "h": 8}, "targets": [{"expr": "sum by (state) (kutab_lectures_total{tenant=\"$tenant\"})"}]},
    {"type": "timeseries", "title": "Queue Backlog", "gridPos": {"x": 0, "y": 12, "w": 12, "h": 8}, "targets": [{"expr": "sum by (queue) (kutab_queue_jobs_total{tenant=\"$tenant\"})"}]},
    {"type": "timeseries", "title": "Invoice Amount by Status", "gridPos": {"x": 12, "y": 12, "w": 12, "h": 8}, "targets": [{"expr": "sum by (status, currency) (kutab_invoice_amount_total{tenant=\"$tenant\"})"}]}
  ]
}
JSON

cat > "$DATA_ROOT/envs/infrastructure/infrastructure.env" <<EOF
CLUSTER_DOMAIN=$CLUSTER_DOMAIN
ACME_EMAIL=$ACME_EMAIL
CONFIG_ROOT=$PROVIDER_ROOT/configs
EOF

cat > "$ACCESS_FILE" <<EOF
Traefik Dashboard: https://traefik.$CLUSTER_DOMAIN
Traefik User: admin
Traefik Password: $TRAEFIK_PASSWORD

Prometheus: https://prometheus.$CLUSTER_DOMAIN
Prometheus User: monitor
Prometheus Password: $PROMETHEUS_PASSWORD

Grafana: https://grafana.$CLUSTER_DOMAIN
Grafana User: $GRAFANA_USER
Grafana Password: $GRAFANA_PASSWORD

Portainer: https://portainer.$CLUSTER_DOMAIN
Portainer User: admin
Portainer Password: $PORTAINER_PASSWORD
EOF
chmod 600 "$ACCESS_FILE"

export CLUSTER_DOMAIN ACME_EMAIL CONFIG_ROOT="$PROVIDER_ROOT/configs"

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: docker stack deploy -c $PROVIDER_ROOT/templates/infra-stack.yml kutab-infra"
else
  docker stack deploy -c "$PROVIDER_ROOT/templates/infra-stack.yml" kutab-infra
  log "Infrastructure deploy submitted"
  node_state_set INFRA 1
  log "Access credentials: $ACCESS_FILE"
fi
