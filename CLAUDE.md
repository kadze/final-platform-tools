# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Platform/DevOps tooling for an AWS EKS cluster used by the 312school Ubuntu cohort. Each top-level directory is an independent tool that gets deployed into the cluster. Deployments run through GitHub Actions — avoid manual `kubectl apply` or `helm upgrade` outside of the defined workflow except during local development.

## Deployment workflow

All tools are deployed via `.github/workflows/deploy-platform-tools.yaml`, which triggers on pushes to `main` and `feature/**` branches. It:
1. Authenticates to AWS using OIDC (`vars.IAM_ROLE`)
2. Updates kubeconfig for `temporary-eks-cluster-${ENVIRONMENT_STAGE}` (currently `dev`)
3. Runs each tool's deploy step in sequence

To add a new tool: add a named step to `deploy-platform-tools.yaml` after the existing steps.

## EKS cluster provisioning (eks-cloudformation)

The cluster itself is created via CloudFormation + a Makefile, not Terraform. This is a one-time setup, not part of CI.

```bash
cd eks-cloudformation
make cluster version=1.34 role=AWSReservedSSO_Administrator-<suffix>
```

Individual targets: `iam`, `eks`, `workers`, `oidc`, `sshkeys`. Each wraps a CloudFormation stack. Parameters come from `cluster_config` (gitignored values file in that directory).

## eks-monitoring (active development)

Three independent Helm charts, one per tool. Each is deployed as its own `helm upgrade --install` step in CI.

**Values layering per chart:** `values.yaml` (shared defaults) + `values-{env}.yaml` overlay.

**Before deploying**, create the Grafana admin secret manually (until story 1.5 CSI driver is wired up):
```bash
kubectl create secret generic grafana-admin-secret \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=$(aws secretsmanager get-secret-value \
    --secret-id monitoring/grafana-admin \
    --query SecretString --output text | jq -r '.password') \
  -n monitoring
```

**Deploy locally (dev) — run in order:**
```bash
# 1. Prometheus (installs Prometheus Operator and its CRDs first)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm dependency update eks-monitoring/prometheus
helm upgrade --install monitoring eks-monitoring/prometheus \
  --namespace monitoring --create-namespace \
  -f eks-monitoring/prometheus/values.yaml \
  -f eks-monitoring/prometheus/values-dev.yaml \
  --wait --timeout 5m

# 2. Alertmanager
helm dependency update eks-monitoring/alertmanager
helm upgrade --install alertmanager eks-monitoring/alertmanager \
  --namespace monitoring --create-namespace \
  -f eks-monitoring/alertmanager/values.yaml \
  -f eks-monitoring/alertmanager/values-dev.yaml \
  --wait --timeout 3m

# 3. Grafana
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm dependency update eks-monitoring/grafana
helm upgrade --install grafana eks-monitoring/grafana \
  --namespace monitoring --create-namespace \
  -f eks-monitoring/grafana/values.yaml \
  -f eks-monitoring/grafana/values-dev.yaml \
  --wait --timeout 3m
```

**New charts (grafana, alertmanager) require `helm dependency update` before first deploy** — their `Chart.lock` files contain placeholder digests and must be regenerated locally.

**Verify:**
```bash
kubectl get pods -n monitoring
# Grafana is now exposed via ingress (grafana.ubuntu-dev.<DOMAIN>) — no port-forward needed
# Grafana credentials: from AWS Secrets Manager secret monitoring/grafana-admin
```

## Architecture: eks-monitoring internals

```
eks-monitoring/
├── prometheus/                         # wraps kube-prometheus-stack v61.3.2
│   ├── Chart.yaml / Chart.lock
│   ├── values.yaml + values-{env}.yaml
│   └── templates/
│       ├── slo-rules.yaml              # PrometheusRule with SLO recording rules + burn-rate alerts
│       ├── servicemonitor-proshop.yaml # scrapes proshop namespace, label app: proshop-backend
│       ├── servicemonitor-versus.yaml  # scrapes versus namespace (conditional on scrapeTargets.versus.enabled)
│       ├── rolebinding-proshop.yaml    # grants Prometheus view access in proshop namespace
│       └── rolebinding-versus.yaml    # grants Prometheus view access in versus namespace
│
├── grafana/                            # wraps grafana chart v8.5.2
│   ├── Chart.yaml / Chart.lock
│   ├── values.yaml + values-{env}.yaml # includes IRSA annotation + CloudWatch datasource
│   └── templates/
│       ├── ingress.yaml               # Ingress via ingress-nginx — grafana.ubuntu-dev.<DOMAIN>
│       ├── dashboards-configmap.yaml  # cluster-overview + SLO panel dashboards as code
│       └── admin-secret.yaml          # placeholder — secret created out-of-band
│
└── alertmanager/                       # wraps prometheus-community/alertmanager v1.12.0
    ├── Chart.yaml / Chart.lock
    ├── values.yaml + values-dev.yaml
    └── templates/
        └── config.yaml                # AlertmanagerConfig placeholder — story 2.3 owns routing
```

**Helm release names (used in service discovery):**
- Prometheus: `monitoring` → Prometheus service: `monitoring-kube-prometheus-prometheus:9090`
- Grafana: `grafana` → Grafana service: `grafana-grafana:80`
- Alertmanager: `alertmanager` → Alertmanager service: `alertmanager:9093`

**SLOs defined in prometheus/templates/slo-rules.yaml:**
- Proshop `POST /api/orders`: 99.5% success rate over 30 days (availability SLO)
- Versus `GET /api/v1/categories/`: p99 < 800ms, 99% compliance over 30 days (latency SLO)

Both SLOs use 30-second recording rule intervals. The `app=` label on scraped metrics is set via `relabelings` in the ServiceMonitors — app teams do not need to emit it themselves.

**Alertmanager ownership split:** `alertmanager/templates/config.yaml` is the single AlertmanagerConfig for the cluster. Story 2.3 (alerting/on-call) adds receivers and routing rules to that file via PR — do not deploy a separate Alertmanager.

## ingress-nginx

Applied as a raw manifest: `kubectl apply -f ingress-nginx/deploy.yaml`. Grafana external access depends on this being deployed first (story 1.3).

## Grafana external URL pattern

`grafana.ubuntu-<env>.<DOMAIN>` — configured in `grafana/values-{env}.yaml` under `customIngress.host`. Update the IP allowlist (`customIngress.annotations.nginx.ingress.kubernetes.io/whitelist-source-range`) in `grafana/values-dev.yaml` when your public IP changes (`curl ifconfig.me`).

## Contribution rules

- Minimum 3 PR approvals required to merge to `main` (see README)
- All deployments through GitHub Actions — no manual production deploys
- Terraform state bucket configs are in `state-buckets-manual/` (one-time manual setup, not CI)
- `charts/` directories are gitignored — run `helm dependency update` locally before testing
