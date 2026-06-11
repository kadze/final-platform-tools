# eks-logging — EFK Stack

EFK (Elasticsearch + Fluentd + Kibana) logging stack for the team's EKS cluster. Replaces managed logging services to eliminate per-GB ingestion costs and keep log data inside our own AWS account.

**What you gain:** no ingestion billing, full control over retention and schema, logs never leave our account.  
**What you give up:** you own upgrades, storage management, and backup verification. No built-in alerting. No auto-scaling. If Elasticsearch's PVC is lost, the ES data is gone — mitigated by dual output to S3 (see [S3 backup](#s3-backup)).

---

## Architecture

```
EKS Nodes
  └── Fluentd DaemonSet (one pod per node)
        ├── tails /var/log/containers/*.log
        ├── parses with @type cri (containerd format)
        ├── enriches with Kubernetes metadata
        ├──► Elasticsearch StatefulSet (port 9200)
        │       └── Kibana Deployment → ingress-nginx → kibana-ubuntu-dev.312ubuntu.com
        └──► S3 bucket: 383585068161-state-bucket-dev/logs/ (redundant backup)
```

Fluentd runs as a DaemonSet — one pod per node — so every node's container logs are collected. It uses `@type cri` to parse containerd log format (EKS default). Both outputs run simultaneously via `@type copy`: Elasticsearch for live querying, S3 for durability.

---

## Repo structure

```
eks-logging/
├── helm-elasticsearch/
│   ├── Chart.yaml
│   ├── namespace.yaml
│   ├── values.yaml
│   ├── templates/
│   │   ├── elasticsearch-statefulset.yaml
│   │   └── elasticsearch-service.yaml
│   └── values/
│       ├── dev-values.yaml
│       ├── staging-values.yaml
│       └── prod-values.yaml
├── helm-fluentd/
│   ├── Chart.yaml
│   ├── namespace.yaml
│   ├── values.yaml
│   ├── templates/
│   │   ├── fluentd-daemonset.yaml
│   │   ├── fluentd-configmap.yaml
│   │   ├── fluentd-serviceaccount.yaml
│   │   ├── fluentd-clusterrole.yaml
│   │   └── fluentd-clusterrolebinding.yaml
│   └── values/
│       ├── dev-values.yaml
│       ├── staging-values.yaml
│       └── prod-values.yaml
├── helm-kibana/
│   ├── Chart.yaml
│   ├── namespace.yaml
│   ├── values.yaml
│   ├── templates/
│   │   ├── kibana-deployment.yaml
│   │   ├── kibana-service.yaml
│   │   └── kibana-ingress.yaml
│   └── values/
│       ├── dev-values.yaml
│       ├── staging-values.yaml
│       └── prod-values.yaml
├── fluentd/
│   └── Dockerfile       — custom image with both ES + S3 plugins
├── iam/
│   ├── fluentd-s3-role.tf
│   └── providers.tf
└── demo/
    ├── scenario-1-crashloop.yaml
    └── scenario-2-error-spike.yaml
```

Each chart is independent and deployed separately. Per-environment overrides live inside each chart under `values/` (e.g. `helm-elasticsearch/values/dev-values.yaml`).

---

## Deploy

**Prerequisites:**
- `kubectl` connected to `ubuntu-dev-cluster`
- AWS credentials with ECR read + S3 write access
- Helm 3

**Before first deploy**, create the credentials secret manually (Story 1.5 will replace this with Secrets Manager CSI):

```bash
kubectl create namespace logging
kubectl create secret generic elasticsearch-credentials \
  --from-literal=password=<password> \
  -n logging
kubectl create secret generic kibana-credentials \
  --from-literal=password=<kibana-system-password> \
  -n logging
```

Then set the `kibana_system` password in Elasticsearch:

```bash
kubectl port-forward -n logging svc/elasticsearch 9200:9200 &
curl -u elastic:<password> -X POST http://localhost:9200/_security/user/kibana_system/_password \
  -H 'Content-Type: application/json' \
  -d '{"password":"<kibana-system-password>"}'
```

**Deploy all three charts:**

```bash
for chart in elasticsearch fluentd kibana; do
  helm upgrade --install $chart ./eks-logging/helm-${chart} \
    --namespace logging --create-namespace \
    --values ./eks-logging/helm-${chart}/values/dev-values.yaml
done
```

**CI/CD:** the `deploy-platform-tools.yaml` GitHub Actions workflow runs this automatically on push to `feature/**` and `main`.

---

## How to reach Kibana

- **URL:** `http://kibana-ubuntu-dev.312ubuntu.com`
- **Login:** use the `elastic` superuser credentials from AWS Secrets Manager (`elasticsearch-credentials`)
- **Access restriction:** ingress-nginx allowlists by source IP — set `kibana.allowedSourceIP` in `values/dev.yaml`
- **Note:** Kibana ingress is currently managed by ingress-nginx. Story 1.3 (Gateway API) will take this over.

---

## S3 backup

Fluentd ships to both Elasticsearch and S3 simultaneously. This is the primary durability mechanism — Elasticsearch runs on a single PVC, so if that storage is lost, S3 is the only surviving copy.

- **Bucket:** `s3://383585068161-state-bucket-dev/logs/`
- **Write cadence:** files are written hourly (1hr buffer window + 10min flush wait). Allow up to 70 minutes after first deploy for the first object to appear.

Verify the backup is working:

```bash
aws s3 ls s3://383585068161-state-bucket-dev/logs/ --recursive
aws s3 cp s3://383585068161-state-bucket-dev/logs/<file> /tmp/sample.log
cat /tmp/sample.log
```

---

## IAM / Security

Fluentd authenticates to S3 using IRSA (IAM Roles for Service Accounts) — no static credentials anywhere.

- **IAM role:** `arn:aws:iam::383585068161:role/fluentd-s3-role-25c-ubuntu`
- **Trust policy:** scoped to `system:serviceaccount:logging:fluentd` via the cluster's OIDC provider — no other pod can assume this role
- **Policy grants:** `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` on `383585068161-state-bucket-dev` only
- **Elasticsearch credentials:** stored in both a Kubernetes secret (`elasticsearch-credentials`) and AWS Secrets Manager under the same name — ready for Story 1.5's CSI driver
- **Kibana uses `kibana_system`:** Elasticsearch 8.x forbids the `elastic` superuser for Kibana connections. Kibana authenticates as `kibana_system`, a built-in service account with scoped permissions

---

## Diagnostic skill

**Location:** `.claude/skills/log-diagnostic.md`

A Claude Code runbook that investigates log anomalies on demand. Give it a service name and time range; it fetches logs from Elasticsearch or `kubectl`, identifies patterns, and proposes a root-cause hypothesis.

**Constraints:**
- Read-only — it will not delete, restart, or patch any resource
- Operator must confirm the hypothesis before taking any remediation action

**Demo scenarios** (live on the cluster in the `demo` namespace):

| File | Service | Scenario |
|---|---|---|
| `demo/scenario-1-crashloop.yaml` | `payment-service` | CrashLoopBackOff — exits on startup due to missing `DATABASE_URL` |
| `demo/scenario-2-error-spike.yaml` | `auth-service` | Error rate spike — continuous HTTP 500s due to missing `JWT_SECRET` config |

Run a diagnostic:

```bash
# Scenario 1
kubectl get pods -n demo -l app=payment-service
kubectl logs broken-payment-service -n demo --previous

# Scenario 2
kubectl logs broken-auth-service -n demo --since=30m | grep ERROR | wc -l
kubectl logs broken-auth-service -n demo --since=30m | tail -20
```

---

## Why EFK over a managed product

We evaluated CloudWatch Logs, Datadog, and managed OpenSearch before choosing self-hosted EFK.

| Factor | EFK (self-hosted) | Managed alternative |
|---|---|---|
| Cost | Fixed EC2 + EBS cost only | Per-GB ingestion billing — unpredictable at scale |
| Data residency | Stays in our AWS account | May leave our account depending on vendor |
| Retention control | Full control, set per index | Vendor-defined tiers |
| Schema | Free-form, custom fields | Often opinionated |
| Ops burden | We own upgrades and storage | Vendor handles it |
| Alerting | Requires Elastalert or similar | Usually built-in |
| Auto-scaling | Manual | Built-in |

The main risk with self-hosted is losing logs if Elasticsearch storage fails. We mitigate this with dual output to S3 — Elasticsearch is a query layer, not the log store of record.

---

## Dependencies

| Story | Owner | Impact |
|---|---|---|
| 1.1 — Cluster | Andrii P. | Cluster this stack runs on |
| 1.3 — Gateway API | Andrii S. | Kibana external access — currently using ingress-nginx as workaround |
| 1.5 — cert-manager + Secrets CSI | teammate7.dan | HTTPS for Kibana + clean secret injection via Secrets Manager |
