# EKS Logging — EFK Stack

Centralised logging for the 25c-ubuntu EKS cluster using Elasticsearch, Fluentd, and Kibana.

## Architecture

```
EKS Nodes
  └── Fluentd DaemonSet (one pod per node)
        ├── tails /var/log/containers/*.log (CRI format)
        ├── enriches with Kubernetes metadata
        ├──► Elasticsearch (StatefulSet, port 9200)
        │       └── Kibana (Deployment, port 5601)
        │             └── ingress-nginx → kibana-ubuntu-dev.312ubuntu.com
        └──► S3 bucket (383585068161-state-bucket-dev/logs/)
```

**Why EFK over a managed service?** Full control over retention and parsing rules, no per-GB ingestion cost, and S3 backup is included at negligible cost. Trade-off: we own the ops burden.

## Chart structure

Three independent Helm charts, each owning one component:

| Chart | Kind | Purpose |
|---|---|---|
| `charts/elasticsearch` | StatefulSet | Stores and indexes log data |
| `charts/fluentd` | DaemonSet | Collects and ships logs from every node |
| `charts/kibana` | Deployment | Web UI for querying and visualising logs |

## Prerequisites

1. EKS cluster running (Story 1.1)
2. `logging` namespace:
   ```bash
   kubectl create namespace logging
   ```
3. Elasticsearch credentials secret (manual until Story 1.5):
   ```bash
   kubectl create secret generic elasticsearch-credentials \
     --from-literal=password=<your-password> \
     -n logging
   ```
4. ingress-nginx controller installed (Story 1.3 will migrate to Gateway API)

## Deployment

The GitHub Actions workflow (`deploy-platform-tools.yaml`) handles this automatically on push. To deploy manually:

```bash
ENVIRONMENT_STAGE=dev

for chart in elasticsearch fluentd kibana; do
  helm upgrade --install $chart ./charts/$chart \
    --namespace logging \
    --create-namespace \
    --values ./values/${ENVIRONMENT_STAGE}.yaml \
    --wait \
    --timeout 5m
done
```

## Key config decisions

### CRI log parser
EKS uses containerd, which writes logs in CRI format — not Docker's JSON format. Fluentd is configured with `@type cri` in `charts/fluentd/templates/configmap.yaml`. Using `@type json` here would silently fail to parse every log line.

### Dual output: Elasticsearch + S3
Fluentd ships to both destinations simultaneously via `@type copy`. Elasticsearch provides real-time search via Kibana. S3 provides long-term retention and audit trail — logs land in `s3://383585068161-state-bucket-dev/logs/` hourly.

### IRSA — no static AWS credentials
Fluentd authenticates to S3 using IAM Roles for Service Accounts (IRSA). The IAM role (`fluentd-s3-role-25c-ubuntu`) trusts only the `system:serviceaccount:logging:fluentd` service account via the cluster's OIDC provider. No AWS access keys are stored anywhere. The IAM role is managed in `iam/fluentd-s3-role.tf`.

### Kibana access control
Kibana is restricted to a single source IP via ingress-nginx `whitelist-source-range`. Set `kibana.allowedSourceIP` in the environment values file.

## Verifying the S3 backup

After deployment, confirm logs are reaching S3:

```bash
aws s3 ls s3://383585068161-state-bucket-dev/logs/
aws s3 cp s3://383585068161-state-bucket-dev/logs/<file> /tmp/sample.log
cat /tmp/sample.log
```

Fluentd buffers by hour (`timekey 3600`) with a 10-minute wait before flushing, so allow up to 70 minutes after first deploy for the first S3 object to appear.

## Diagnostic skill

A Claude Code skill for investigating log anomalies lives at `.claude/skills/log-diagnostic.md`. Invoke it with a service name and time range to get a structured hypothesis.

```
/log-diagnostic service=payments-api time="last 30 minutes"
```

The skill is **read-only** — it will not restart or delete any resource.

## Known limitations and future work

| Limitation | Resolution |
|---|---|
| Kibana uses ingress-nginx | Switch to Gateway API once Story 1.3 publishes HTTPRoute conventions |
| Elasticsearch credentials injected manually | Story 1.5 (Secrets Manager CSI) will handle injection |
| No TLS on Kibana in dev | Story 1.5 (cert-manager) will add HTTPS |
| Single Elasticsearch replica in dev | Production values use 2 replicas |
| OIDC URL hardcoded in Terraform | Dynamic lookup works once the cluster is accessible |
