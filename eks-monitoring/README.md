# EKS Monitoring — Prometheus, Grafana & SLOs

**Owner:** teammate6 | **Ticket:** MRP25CUBUN-6 | **Epic:** 2 — Observability

---

## Overview and Architecture

This folder contains the Helm-based monitoring stack for the 312school Ubuntu cohort EKS cluster. It deploys the `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager) via a single Helm chart, scrapes metrics from cluster components and application workloads, and surfaces SLO compliance dashboards in Grafana.

### What is deployed

```
eks-monitoring/
├── chart/
│   ├── Chart.yaml
│   ├── values.yaml               # shared defaults
│   ├── values-dev.yaml
│   ├── values-staging.yaml
│   ├── values-prod.yaml
│   └── templates/
│       ├── prometheus/
│       ├── grafana/
│       ├── alertmanager/
│       └── ingress.yaml
├── dashboards/
│   ├── cluster-overview.json
│   └── slo-panel.json
└── README.md
```

### Architecture diagram

```
Cluster nodes / kubelet
kube-state-metrics            ──→  Prometheus  ──→  Grafana (dashboards + SLO panels)
ServiceMonitors (app scrapes)           │
                                        └──→  Alertmanager  ──→  (story 2.3 owns routing)
                                        │
                                        └──→  CloudWatch data source (AWS-managed resources)
```

Prometheus scrapes every 30 seconds. Grafana reads both Prometheus and CloudWatch so that AWS-managed resources (ALB, DocumentDB) appear in the same dashboards as cluster metrics.

---

## SLO Definitions

### Why these apps were chosen

Two application teams were selected as SLO targets: **Proshop** (teammate2, MRP25CUBUN-11) and **Versus** (teammate10, MRP25CUBUN-9). The weather backend (teammate11, MRP25CUBUN-13) was considered but excluded from primary SLO ownership because it proxies two external APIs (Google Geocoding + OpenWeatherMap). Latency and freshness for that app are partially outside the team's control, making it hard to set a defensible target.

---

### SLO 1 — Proshop order success rate

| Field | Value |
|---|---|
| **App** | Proshop (`312school/proshop-25c-ubuntu`) |
| **User journey** | User completes a checkout — adds to cart, logs in, places an order |
| **Key endpoint** | `POST /api/orders` |
| **SLI type** | Availability |
| **SLI definition** | Proportion of `POST /api/orders` requests that return HTTP 2xx over all requests to that endpoint |
| **SLO target** | **99.5%** of requests must succeed over a rolling 30-day window |
| **Measurement window** | 30-day rolling |
| **Error budget** | 0.5% of requests — roughly 3.6 hours of total downtime per month |

**Why 99.5% and not higher:**
The order endpoint is the highest-value user journey in the project — a failed order is a direct loss. 99.5% was chosen over 99.9% deliberately: 99.9% (~43 min/month budget) sounds safer but is harder to maintain for a student-operated cluster without a runbook, on-call rotation, or SLA from the underlying cloud services. 99.5% gives a realistic error budget for a team learning the stack while still representing a meaningful commitment to users.

**PromQL — SLI calculation:**
```promql
sum(rate(http_requests_total{route="/api/orders", method="POST", status_code=~"2.."}[30d]))
/
sum(rate(http_requests_total{route="/api/orders", method="POST"}[30d]))
```

**PromQL — error budget remaining:**
```promql
1 - (
  sum(rate(http_requests_total{route="/api/orders", status_code!~"2.."}[30d]))
  /
  sum(rate(http_requests_total{route="/api/orders"}[30d]))
) / 0.005
```

**Response rules:**
- Budget > 50% remaining → no action required
- Budget at 50% burned → investigate and post update in team channel
- Budget at 100% burned → freeze non-critical deployments to Proshop, open incident, notify story 2.3 owner to configure alert

---

### SLO 2 — Versus category listing latency

| Field | Value |
|---|---|
| **App** | Versus (`312school/versus-25c-ubuntu`) |
| **User journey** | User opens the app and sees the list of comparison categories |
| **Key endpoint** | `GET /api/v1/categories/` |
| **SLI type** | Latency |
| **SLI definition** | Proportion of `GET /api/v1/categories/` requests that complete within 800ms (p99) |
| **SLO target** | **99%** of requests must respond within 800ms over a rolling 30-day window |
| **Measurement window** | 30-day rolling |
| **Error budget** | 1% of requests may exceed 800ms |

**Why 99% and not 99.5%:**
This is a read-only listing endpoint — the user is browsing, not completing a transaction. The business consequence of a slow category list is lower than a failed order. The different target (99% vs 99.5%) reflects a deliberate calibration: not every endpoint deserves the same SLO. If both were 99.9%, it would suggest the targets were chosen without thinking about business impact.

**Why 800ms:**
800ms is based on Google's RAIL model, which defines 1 second as the boundary beyond which users notice lag. 800ms gives a buffer below that threshold. This is an initial hypothesis — once teammate10's `/metrics` endpoint is live and Prometheus is scraping real traffic, the actual p99 will be measured and this target will be adjusted if needed.

**PromQL — SLI calculation:**
```promql
histogram_quantile(0.99,
  sum by (le) (
    rate(django_http_requests_latency_seconds_by_view_method_bucket{
      view="CategoryListViewSet",
      method="GET"
    }[30d])
  )
)
```

**PromQL — SLO compliance (% of time p99 is under 800ms):**
```promql
sum(rate(django_http_requests_latency_seconds_by_view_method_bucket{
  view="CategoryListViewSet",
  le="0.8"
}[30d]))
/
sum(rate(django_http_requests_latency_seconds_by_view_method_bucket{
  view="CategoryListViewSet",
  le="+Inf"
}[30d]))
```

**Response rules:**
- p99 < 800ms → healthy, no action
- p99 between 800ms–1.2s → investigate — likely database query or serializer performance
- p99 > 1.2s → open issue on teammate10's repo, check MySQL query plans and Django ORM calls

---

### Cluster-level metrics (always scraped, no SLO)

The following are scraped by default via `kube-state-metrics` and Prometheus node exporter. No SLO is defined for these — they feed the cluster overview dashboard and inform alerting rules owned by story 2.3:

- Node CPU and memory utilization
- Pod restart counts
- Persistent volume usage
- Kubelet health
- API server request latency

---

## Why Prometheus and not Datadog

This question comes up in demos. The short answer:

| Concern | Prometheus + Grafana | Datadog |
|---|---|---|
| Cost | Free, open-source | Paid SaaS — $15–$23/host/month |
| Data residency | Runs inside the cluster, no data leaves | Ships all metrics to Datadog's cloud |
| Kubernetes native | kube-prometheus-stack is the industry standard for EKS | Agent-based, requires DaemonSet + API key |
| Customisation | Full control over scrape config, alert rules, dashboards | Controlled by Datadog's product |
| Appropriate for this project | Yes | No — not in budget, not in scope |

The longer answer: Prometheus was designed for dynamic container environments. Its pull-based scrape model, label system, and PromQL query language map directly onto how Kubernetes exposes metrics. The `kube-prometheus-stack` Helm chart is maintained by the Prometheus community and is the de facto standard for Kubernetes observability. Grafana's provisioned dashboards and Alertmanager's routing rules are stored as code in this repo — everything is reproducible, version-controlled, and reviewable. Datadog is a legitimate production tool but it is a paid managed service that would not be appropriate here.

---

## How to Run/Execute

> Prerequisites: EKS cluster running (story 1.1), kubeconfig configured, Helm 3.x installed.

```bash
# Add the kube-prometheus-stack Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Deploy to dev
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f eks-monitoring/chart/values.yaml \
  -f eks-monitoring/chart/values-dev.yaml

# Verify pods are running
kubectl get pods -n monitoring

# Access Grafana (local port-forward for dev)
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
# Then open http://localhost:3000
# Credentials: from AWS Secrets Manager secret monitoring/grafana-admin
```

Grafana is also exposed externally at `grafana-<TEAM>-dev.<TEAM_DOMAIN>` via the ingress configured in `templates/ingress.yaml` (depends on story 1.3 ingress-nginx being deployed first).

---

## Cross-team Dependencies

| Dependency | Owner | Status | Notes |
|---|---|---|---|
| EKS cluster | Andrii P. (1.1) | In progress | Need cluster name + kubeconfig |
| IAM role for GitHub Actions OIDC | teammate1 (1.2) | To do | Using ad-hoc role on dev branch for now |
| Ingress (external Grafana URL) | Andrii S. (1.3) | In progress | Port-forward works locally without this |
| App `/metrics` endpoint — Proshop | teammate2 (2.1 → 2.2) | Requested | Instructions sent — prom-client setup |
| App `/metrics` endpoint — Versus | teammate10 (2.1 → 2.2) | Requested | Instructions sent — django-prometheus setup |
| Alertmanager routing rules | 2.3 owner | Unassigned | Alertmanager is deployed here; routing config TBD |
| Secrets Manager secret for Grafana | teammate6 (this ticket) | To do | Create manually in dev |

---

## Issues

> This section will be updated as challenges are encountered during implementation.

- Alertmanager config ownership not yet agreed — story 2.3 is unassigned. Deploying Alertmanager with placeholder config for now.
- Grafana CloudWatch data source requires IAM role — minting ad-hoc role on dev branch pending story 1.2.
- Latency SLO target of 800ms for Versus is an initial hypothesis. Will validate against real p99 data once scraping is live and adjust if needed.

---

## Resources

- [kube-prometheus-stack Helm chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator docs](https://prometheus-operator.dev/)
- [Google RAIL model (latency thresholds)](https://web.dev/rail/)
- [SLO fundamentals — Google SRE Workbook, Chapter 2](https://sre.google/workbook/implementing-slos/)
- [PromQL cheat sheet](https://promlabs.com/promql-cheat-sheet/)
- [django-prometheus](https://github.com/korfuri/django-prometheus)
- [prom-client (Node.js)](https://github.com/siimon/prom-client)

---

## Additional Information

The SLO targets in this document are starting points, not fixed commitments. Standard SLO practice is to set an initial target, observe real traffic, and tighten or relax the target based on what is actually achievable and what users actually experience. Both targets (99.5% order success, 99% category p99 < 800ms) will be reviewed once Prometheus has at least one week of live traffic data.

The Alertmanager deployment in this stack is a shared seam with story 2.3 (alerting & on-call). This ticket deploys Alertmanager with a minimal placeholder config. Story 2.3 owns the alert rules and Slack routing configuration that will be layered on top.
