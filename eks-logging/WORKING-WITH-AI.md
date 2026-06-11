# Working with Claude Code — Story 2.2 Retrospective

This is an honest account of how I used Claude Code throughout Story 2.2. What helped, what broke, what I had to catch myself.

---

## 1. How I used Claude Code

I used the Claude Code VS Code extension and the claude.ai chat interface throughout the story. The split was roughly: VS Code extension for file edits and kubectl/helm commands, chat for longer planning and explanation.

Claude helped with most of the scaffolding: Helm chart structure, the Terraform IAM role, Fluentd configuration, Kibana ingress setup, the diagnostic skill markdown, the README, and the demo scenarios. The workflow was consistent throughout — I described what I needed, Claude generated the code, I read it in VS Code before applying anything, then tested on the cluster. When something broke, I pasted the error back and iterated.

I never applied anything to the cluster without reading it first. That turned out to matter.

---

## 2. What Claude got wrong — bugs I caught and fixed

### 1. Wrong log parser

Claude initially configured Fluentd with `@type json`. EKS uses containerd as the container runtime, not Docker. Containerd writes logs in CRI format, which is structurally different from Docker's JSON format. `@type json` would have silently failed to parse every log line — logs would have shipped as raw unparsed strings, useless for querying in Kibana. The correct parser is `@type cri`. I caught this by knowing the EKS runtime and checking the parser type before deploying.

### 2. Kibana using the elastic superuser

Claude connected Kibana to Elasticsearch using the `elastic` superuser account. Elasticsearch 8.x explicitly forbids this — Kibana will refuse to start and logs a fatal error. The correct account is `kibana_system`, a built-in service account with scoped permissions. This required creating a separate Kubernetes secret for the Kibana credentials and calling the Elasticsearch API to set the `kibana_system` password before Kibana could start.

### 3. Missing storageClassName on the StatefulSet

The Elasticsearch StatefulSet PVC was stuck in `Pending` because `storageClassName: gp2` was missing from the `volumeClaimTemplates`. Claude assumed a default storage class would exist. EKS doesn't configure a default the way local clusters do — you have to be explicit. Once `gp2` was added, the PVC bound immediately.

### 4. EBS volume permissions

After the PVC issue was fixed, Elasticsearch crashed on startup with a lock error: the EBS volume was owned by root, but Elasticsearch runs as uid 1000 and couldn't write to its data directory. Fixed by adding an `initContainer` that runs `chown -R 1000:1000 /usr/share/elasticsearch/data` before the main container starts. This is a known requirement for Elasticsearch on EKS that Claude missed.

### 5. Fluentd missing the S3 plugin

The base `fluent/fluentd-kubernetes-daemonset:v1.16-debian-elasticsearch8-1` image only bundles the Elasticsearch output plugin. The S3 output block was in the config and Fluentd accepted it as valid syntax — but at runtime it would throw `Unknown output plugin 's3'` and crash. The fix was to build a custom Docker image based on the ES image with `gem install fluent-plugin-s3` added, push it to ECR, and update the DaemonSet to use it. This was the last thing resolved before S3 backup could be verified.

### 6. Kibana DNS failure

Claude used the full FQDN `elasticsearch.logging.svc.cluster.local` as the Elasticsearch host in Kibana's config. Node.js has a known issue with `ndots:5` DNS resolution in Kubernetes — when a FQDN with fewer than 5 dots is used, the resolver appends search domains before trying the name as absolute, which causes resolution to fail. The fix was to use the short service name `elasticsearch` instead. With the pod's search domains configured as `logging.svc.cluster.local`, the short name resolves correctly. The FQDN was the wrong choice here.

### 7. IPv6-only cluster

`ubuntu-dev-cluster` is IPv6-only. Claude's default ingress-nginx setup creates a Classic ELB, which uses IPv4 to health-check the backend nodes. On an IPv6-only cluster this fails completely — all instances show `OutOfService`. Had to reinstall ingress-nginx with an NLB (`aws-load-balancer-type: nlb`) and `ipFamilyPolicy: SingleStack` with `ipFamilies: [IPv6]`. Claude initially tried the Classic ELB path and didn't know the cluster was IPv6-only until I checked the node IPs.

### 8. IAM role ARN not reaching the ServiceAccount annotation

`dev.yaml` had the ARN nested under `fluentd.serviceAccount.iamRoleArn`, but the Helm template reads `.Values.serviceAccount.iamRoleArn` — one level up. The annotation was always rendered as an empty string, so IRSA never kicked in. Fluentd was silently using the node's EC2 role instead of the dedicated S3 role. Only caught by reading `kubectl get serviceaccount fluentd -n logging -o yaml` and seeing the annotation was blank.

### 9. IRSA trust policy pointed at the wrong cluster

The IAM role was created when we were using `eks-dev`. When we switched to `ubuntu-dev-cluster`, the trust policy still had eks-dev's OIDC ID (`C518D5CB...`). AWS rejected every token with `AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity`. Fixed by getting ubuntu-dev-cluster's OIDC ID and updating both the trust policy and `fluentd-s3-role.tf` to match (`287337B7769634D2DD2BA62AD053165D`).

### 10. Fluentd permission denied on position file

Fluentd tracks which log lines it has already read using a position file at `/var/log/fluentd-containers.log.pos` on the host filesystem. The host `/var/log` is owned by root. Fluentd was running as a non-root user and got `Errno::EACCES - Permission denied`. Fixed by adding `securityContext: runAsUser: 0` to the DaemonSet pod spec — necessary for any DaemonSet that reads from or writes to the host filesystem.

---

## 3. What I verified myself

- Every `kubectl get pods`, `kubectl logs`, and `kubectl describe` output — I read every line. "Deployed successfully" from Helm doesn't mean the pods are healthy.
- Confirmed `@type cri` was correct by knowing the EKS node runtime before deploying.
- Verified the IAM role trust policy was scoped to `system:serviceaccount:logging:fluentd` and not broader than that.
- Checked that Elasticsearch credentials were not committed anywhere in the repo — the secret is created by hand, never in source.
- Verified Fluentd pods were running on the correct nodes and not stuck on nodes at the pod limit.
- Tested the diagnostic skill manually against both demo scenarios and checked that the output was accurate before calling it done.
- Confirmed the S3 bucket path and IAM policy resource ARNs matched exactly — a mismatch there would have produced silent permission failures.

---

## 4. What I learned

**Containerd vs Docker matters.** EKS moved away from Docker and the log format changed. `@type cri` is the correct parser for any modern EKS cluster. This isn't documented prominently anywhere — you have to know to look.

**StatefulSets on EKS need explicit storageClassName.** Don't assume a default exists. Always check `kubectl get storageclass` before writing a PVC and specify the class explicitly.

**IRSA is the right way to give pods AWS access.** No static keys, short-lived tokens scoped to one specific ServiceAccount in one specific namespace. If the pod is compromised, the blast radius is limited to what that IAM role allows.

**A single log store is a single point of failure.** The S3 dual output isn't a nice-to-have. If Elasticsearch's PVC is lost, the ES data is gone. S3 is the backup that makes EFK viable as a production logging solution rather than a fragile experiment.

**The diagnostic skill's most important constraint is what it can't do.** Read-only is a deliberate design decision, not a limitation. The skill's job is to surface evidence and propose a hypothesis. A human confirms before acting. Automated remediation without confirmation — deleting pods, rolling back deployments — is dangerous and belongs in a different category of tooling with much more safeguarding.

**Claude is fast at structure and boilerplate, but it doesn't know your cluster.** It doesn't know what runtime your nodes use, whether your cluster is IPv4 or IPv6, what storage classes are available, or what version of Elasticsearch you're connecting to. Every generated output is a starting point. Deploying without reading it first is how things break silently.

**Switching clusters resets your assumptions.** IAM trust policies, OIDC IDs, and security contexts that worked on one cluster may silently fail on another. Always verify the ServiceAccount annotation and check `kubectl logs` immediately after switching.

---

## 5. What I would do differently

**Start with a minimal working stack, then add S3.** Fluentd shipping to Elasticsearch only — confirm that works end-to-end, Kibana shows logs, then add S3. The missing S3 plugin was the last thing discovered when it could have been caught in the first hour by testing S3 output in isolation.

**Test on the real cluster sooner.** I waited on Story 1.1 (cluster migration) longer than necessary. `eks-dev` was available the whole time and was a usable workaround. The cluster-specific issues — IPv6, pod limits, node taints — only became visible when I actually deployed. Earlier cluster testing would have surfaced all of them earlier.

**Build the custom Fluentd image at the start, not the end.** The ECR image with both ES and S3 plugins should have been the first artifact, before any chart work. Instead it was the last fix. If I'd built the image on day one, S3 backup would have been verified much earlier and there would have been no gem install failures, no startup command hacks, no half-working configs in between.
