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

The monitoring stack is a thin Helm wrapper around `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager). The chart lives at `eks-monitoring/chart/`.

**Values layering:** `values.yaml` (shared defaults) is always applied; one environment overlay is added on top:
- `values-dev.yaml` — shorter retention (7d), 10Gi storage, IP-restricted Grafana ingress
- `values-staging.yaml` / `values-prod.yaml` — defined but not yet deployed

**Deploy locally (dev):**
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm dependency update eks-monitoring/chart
helm upgrade --install monitoring eks-monitoring/chart \
  --namespace monitoring --create-namespace \
  -f eks-monitoring/chart/values.yaml \
  -f eks-monitoring/chart/values-dev.yaml \
  --wait --timeout 5m
```

**Verify:**
```bash
kubectl get pods -n monitoring
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
# Grafana credentials: from AWS Secrets Manager secret monitoring/grafana-admin
```

**Before deploying**, create the Grafana admin secret manually (until story 1.5 CSI driver is wired up):
```bash
kubectl create secret generic grafana-admin-secret \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=$(aws secretsmanager get-secret-value \
    --secret-id monitoring/grafana-admin \
    --query SecretString --output text | jq -r '.password') \
  -n monitoring
```

## Architecture: eks-monitoring internals

```
eks-monitoring/chart/
├── Chart.yaml                          # wraps kube-prometheus-stack v61.3.2
├── values.yaml + values-{env}.yaml     # layered config
└── templates/
    ├── prometheus/
    │   ├── slo-rules.yaml              # PrometheusRule with SLO recording rules + burn-rate alerts
    │   ├── servicemonitor-proshop.yaml # scrapes proshop namespace, label app: proshop-backend
    │   └── servicemonitor-versus.yaml  # scrapes versus namespace
    ├── grafana/
    │   ├── admin-secret.yaml           # placeholder only — secret created out-of-band
    │   └── dashboards-configmap.yaml
    └── alertmanager/
        └── config.yaml                 # AlertmanagerConfig — owned here; story 2.3 adds receivers
```

**SLOs defined in this chart:**
- Proshop `POST /api/orders`: 99.5% success rate over 30 days (availability SLO)
- Versus `GET /api/v1/categories/`: p99 < 800ms, 99% compliance over 30 days (latency SLO)

Both SLOs use 30-second recording rule intervals. The `app=` label on scraped metrics is set via `relabelings` in the ServiceMonitors — app teams do not need to emit it themselves.

**Alertmanager ownership split:** `alertmanager/config.yaml` is the single Alertmanager deployed for the cluster. Story 2.3 (alerting/on-call) adds receivers and routing rules to that file via PR — do not deploy a separate Alertmanager.

## ingress-nginx

Applied as a raw manifest: `kubectl apply -f ingress-nginx/deploy.yaml`. Grafana external access depends on this being deployed first (story 1.3).

## Grafana external URL pattern

`grafana-ubuntu-<env>.312ubuntu.com` — configured in each `values-{env}.yaml` under `kube-prometheus-stack.grafana.ingress.hosts`. Update the IP allowlist in `values-dev.yaml` (`nginx.ingress.kubernetes.io/whitelist-source-range`) when your public IP changes (`curl ifconfig.me`).

## Contribution rules

- Minimum 3 PR approvals required to merge to `main` (see README)
- All deployments through GitHub Actions — no manual production deploys
- Terraform state bucket configs are in `state-buckets-manual/` (one-time manual setup, not CI)
- `charts/` directories are gitignored — run `helm dependency update` locally before testing
