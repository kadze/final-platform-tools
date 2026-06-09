# Working with AI — MRP25CUBUN-6 Story 2.1 — Metrics & SLOs

*Author: teammate6. Story assigned: 2026-06-05. Story completed: [date]. Cluster / repo: [link to platform-tools-25c-ubuntu]*

---

## 1. My role vs. Claude's role

**I directed:**
- Which apps to write SLOs for (Proshop and Versus) and why — Claude presented the options and trade-offs, the decision was mine
- The SLO targets themselves (99.5% for Proshop orders, 99% p99 < 800ms for Versus) — Claude explicitly did not pick these for me
- The decision to defer teammate11's weather app from the primary SLO because of external API dependency — my call after understanding the trade-off
- Catching that the branch name `feature/teammate6-eks-monitoring-slo-readme` didn't follow the team naming convention (`feature/STORY-X.X-description`) — I spotted this, Claude had not flagged it
- Deciding NOT to open a PR until the cluster is up and CI can actually pass — Claude suggested it, I made the judgment call

**Claude generated:**
- The full Helm chart scaffold (Chart.yaml, values.yaml, values-dev/staging/prod.yaml, all templates)
- The ServiceMonitor YAML for Proshop and Versus
- The PrometheusRule with SLO recording rules and burn-rate alerts
- The Grafana dashboards-as-code ConfigMap
- The README with SLO documentation and PromQL queries
- The exact instrumentation instructions sent to teammate2 (prom-client) and teammate10 (django-prometheus)
- The deploy step wired into deploy-platform-tools.yaml — I typed it myself into VS Code after Claude explained every line

---

## 2. Decisions I made

**Decision 1 — Which app to anchor the primary SLO on**
Options: Proshop (POST /api/orders), Versus (GET /api/v1/categories/), Weather (GET /weather).
I chose Proshop as the primary SLO anchor because a failed order is the highest business-impact user journey — it's directly tied to revenue. Weather was excluded because its latency depends on external APIs outside the team's control, making the SLO hard to own and defend. Versus was kept as a secondary SLO.
Trade-off accepted: Proshop wasn't deployed yet on day one, so the SLO is initially measured against synthetic traffic.

**Decision 2 — 99.5% target for Proshop, not 99.9%**
Claude presented both options with the math. 99.9% gives ~43 minutes error budget per month — too tight for a student-operated cluster without a proper on-call rotation. 99.5% gives ~3.6 hours — realistic for the team while still being a meaningful commitment.
Trade-off accepted: lower target = less pressure, but also less impressive. Chose defensibility over appearance.

**Decision 3 — Scrape all three apps, not just one**
The ticket required "at least one" app. I decided to coordinate with all three teams (teammate2, teammate10, teammate11) on day one so instrumentation is in place when their apps deploy, rather than scrambling later.
Trade-off accepted: more cross-team coordination overhead upfront, but no last-minute blocking later.

**Decision 4 — Keep the PR in draft until CI can pass**
When the PR was showing a failed deployment check, Claude suggested converting to draft. I agreed — opening a PR that can't merge is noise for reviewers. Better to wait until the cluster is up and the workflow actually runs.

**Decision 5 — Not committing a hard-coded IP for the long term**
After adding my home IP to values-dev.yaml, I raised the question of dynamic IPs. Claude hadn't flagged this. We documented it in the values file with a comment explaining the limitation. For the demo this is fine; for a real team this would need a VPN or fixed exit IP.

---

## 3. What Claude got wrong

*[Fill in with specifics as the project progresses — include commit SHAs, error messages, PR comments as evidence]*

**Incident 1 — Branch naming convention not flagged**
Claude created the initial branch as `feature/teammate6-eks-monitoring-slo-readme`. The team convention (visible in other repos) is `feature/STORY-X.X-short-description`. Claude did not check the existing branches before naming ours. I caught it by asking Claude to check the other repos. Had to rename the branch, re-push, delete the old branch, and the original PR was closed as a result.
Evidence: git history shows branch rename commit on 2026-06-05.

**Incident 2 — Dynamic IP problem not raised proactively**
Claude suggested adding a home public IP to `values-dev.yaml` without mentioning that home IPs are typically dynamic (change on router restart) and location-dependent (different IP at coffee shop vs. home). I raised this myself. Claude then explained VPN, CIDR range, and AWS security group approaches — but should have flagged this upfront.

**Incident 3 — Team domain placeholder unverified**
Claude used `312ubuntu.com` as the Grafana hostname domain without confirming this is the actual team domain. This is a placeholder that needs to be verified with the PM. All ingress hostnames in values-dev/staging/prod.yaml may need updating.
*[Update this once confirmed in PM meeting]*

**Incident 4 — ServiceMonitor release label not included**
Claude wrote the ServiceMonitor without the `release: monitoring` label. 
Prometheus Operator is configured with `serviceMonitorSelector: matchLabels: release: monitoring` 
— any ServiceMonitor without this label is silently ignored. Claude did not check the 
Prometheus selector configuration before writing the ServiceMonitor. Caught during debugging 
when the target wasn't appearing.

**Incident 5 — Port named "http" instead of "metrics"**
Claude assumed teammate2's Service port would be named "http". It had no name at all, 
and the correct name to use was "metrics" to match the /metrics endpoint convention. 
Required patching both the Service (to add the name) and the ServiceMonitor (to use 
the correct name).

**Incident 6 — RBAC not considered for cross-namespace scraping**
Claude did not mention that Prometheus needs a RoleBinding in each target namespace 
to discover Services. The proshop namespace had no RoleBinding so Prometheus couldn't 
see the Service at all. Fixed by creating a RoleBinding manually — this should be 
added to the Helm chart as a template.

**Incident 7 — Wrong label name in SLO queries: status_code vs status**
Claude wrote SLO PromQL queries using `status_code` as the label name. teammate2's 
prom-client implementation uses `status` instead. Claude did not check the actual 
metric labels before writing the queries — discovered by querying Prometheus directly 
and reading the real label names. All four SLO recording rules had to be updated.

**Incident 8 — method label assumed but not present**
Claude wrote SLO queries filtering by `method="POST"` for the orders endpoint. 
teammate2's prom-client setup does not emit a method label at all. Claude assumed a 
standard prom-client setup without verifying what labels teammate2 actually exposed. 
Removed the method filter from all four recording rules.

*[Add more incidents here as the project progresses]*

---

## 4. What I verified, and how

*[Fill in as the project progresses — green CI is not verification]*

**Verified on day one (before cluster):**
- Read every line of the deploy step in deploy-platform-tools.yaml myself before committing — understood what each command does and why
- Checked teammate2's and teammate10's repos directly to confirm neither had added instrumentation yet — rather than assuming they had acted on my message
- Ran `git diff` before committing the workflow change to confirm only the expected lines were added
- Ran `git status` at each step of the commit/push flow rather than trusting the previous step worked

**To verify when cluster is up:**
- [ ] Query Prometheus directly (`kubectl port-forward`) to confirm scrape targets show as UP
- [ ] Open Grafana and confirm both Prometheus and CloudWatch data sources return data
- [ ] Confirm SLO gauge panel shows a number (even from synthetic traffic)
- [ ] Hit Grafana URL from phone (different IP) and confirm access is blocked
- [ ] Confirm Grafana login requires credentials (not open)
- [ ] Check that dashboards loaded from ConfigMap, not hand-clicked

---

## 5. What I'd do differently next time

*[Fill in honestly at the end of the project]*

**Notes so far (day one):**
- Check existing branch names in all repos before creating a new branch — took 2 minutes to fix but caused a PR to be closed unnecessarily
- Verify placeholders (domain names, IPs, namespace names) with the PM before writing them into config files — easier to confirm upfront than to find and replace later
- Ask cross-team dependencies (teammate2, teammate10, teammate11) for confirmation that they've actually done the instrumentation, not just that they've read the message

*[Add more reflections as the project progresses]*

---

## How to use this document before an interview

Pick one incident from §3 or §4 and rehearse it in STAR format — Situation, Task, Action, Result. ~90 seconds out loud.

Example using Incident 1:
- **Situation:** Working on a team project with branch protection rules and PR review requirements
- **Task:** Get my monitoring stack code into the repo following team conventions
- **Action:** Noticed the branch name didn't match the convention used in other repos, renamed it, re-pushed, and closed the incorrect PR before anyone reviewed it
- **Result:** Branch correctly named, no confusion for reviewers, learned to check team conventions before creating branches

---

*Last updated: 2026-06-05. Continue updating as the project progresses.*
