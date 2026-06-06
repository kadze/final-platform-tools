# `WORKING-WITH-AI.md` — template

This is the template for the memoir deliverable on a Final Project story.
Copy it into your story folder as `WORKING-WITH-AI.md`, fill it in as you
work (not at the end — you will forget the specifics), and commit it
alongside your README.

- **Required** for your primary story (the one you took on in the
  initial planning meeting).
- **Optional but encouraged** for any additional stories you pick up
  after your primary is done. (Additional stories are
  Claude-PR-reviewed and not graded — but if you want one to count
  as interview material, a short memoir is what gives it durability.)
- Target length: **2–4 pages.** Longer is fine if you have the substance;
  shorter usually means you skipped the hard parts.

This is **not** a status report and **not** a generic "I used AI on this"
essay. It is a memoir written for one specific reader: **you, several
months from now, the night before an interview.**

---

# Working with AI — `<ticket-key>` `<Story title>`

*Author: `<your name>`. Story assigned: `<date>`. Story completed:
`<date>`. Cluster / repo: `<links>`.*

> The `<ticket-key>` placeholder is your **per-team** Jira key (e.g.
> `MRP23CCENT-14`).

## 1. My role vs. Claude's role

What did you direct? What did Claude generate? Be specific.

> ✅ *"I designed the network topology and chose the 20/80 on-demand-to-spot
> mix; Claude wrote the Terraform for the node groups and the
> aws-auth ConfigMap."*
>
> ❌ *"I worked with Claude on this story."*

If a section of the code came from Claude, say so. If a design choice was
yours, say so. Future-you will need to know which parts you *own* before
the interview.

## 2. Decisions I made

The moments where you chose between Claude's options or overrode it.
For each decision:

- What were the options on the table?
- Why did you pick this one?
- What was the trade-off you accepted?

Two to five concrete decisions is the right amount. Examples that count:
choosing between Terraform `for_each` vs. `count`; choosing on-demand
vs. spot for a specific node group; choosing whether to put a workload
in a public or private subnet; choosing to write your own bash instead
of accepting Claude's 200-line script.

## 3. What Claude got wrong

This is the section interviewers care about most. **Be specific. Include
evidence.** A commit SHA, a console error, a PR comment, a screenshot, a
test failure.

> *"Claude generated a security group rule allowing `0.0.0.0/0` on port
> 22 for 'easier debugging.' Caught in CI by `tflint` (see PR #14, line
> 47). Replaced with a rule scoped to the GitHub Actions runner CIDR
> block."*

Aim for **2–4 concrete incidents**, not generalities like *"Claude
sometimes hallucinated resource names."* Without the specifics, this
section is worth nothing in an interview.

If Claude got nothing wrong on your story, you either (a) did not
verify, or (b) gave it work that was too easy. Either way, write that
honestly here.

## 4. What I verified, and how

Independent checks you ran beyond *"the workflow turned green."*

- Did you read the `terraform plan` output yourself before approving?
- Did you sanity-check the IAM trust policy's `sub` condition?
- Did you actually open Kibana and confirm logs reached Elasticsearch?
- Did you query Prometheus to confirm scrape targets were healthy?
- Did you `kubectl describe` the pod, or just trust that `Running`
  meant working?

A green workflow is not verification. Write down what *you* checked
yourself.

## 5. What I'd do differently next time

What you learned. Be honest:

- Where did you over-trust Claude and pay for it?
- Where did you waste time arguing with it instead of writing the code
  yourself?
- What `CLAUDE.md` or skill would you build *before* starting fresh on a
  similar story?
- What's a habit you adopted on this story that you'll keep?

This is the section that makes the memoir useful as a learning artifact
for *the next* project, not just an interview prop for this one.

---

## How to use this document later

Several months from now, an interviewer will ask one of:

- *Tell me about a time you debugged something hard.*
- *Tell me about a time you disagreed with a teammate.* (Claude counts.)
- *Walk me through a project you're proud of.*
- *What's something you learned the hard way?*

This memoir is your raw material. The night before the interview, read
it. Pick **one** incident from §3 or §4 and rehearse it in **STAR**
format — Situation, Task, Action, Result. ~90 seconds out loud.

You will sound prepared because you *are* prepared.
