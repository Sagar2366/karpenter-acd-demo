# Break #4 — the two-hour typo (118 minutes of Pending)

**The setup:** onboarding morning, 20 developers at 9 AM. Node
provisioning takes ~40s — too slow for a first click. So: a **warm
pool** — pre-provisioned nodes with a taint (`dedicated=workspaces`)
so nothing else lands there. Workspace pods carry the matching
toleration.

**The typo:** the template said `workspace`. The taint said `workspaces`.
A taint and a toleration must match EXACTLY. The scheduler is polite.
It refused. Forever. **118 minutes of Pending** — on onboarding morning.

**Why nothing alerted:** every component worked as designed. No crash,
no error rate, dashboards green. Pending is a *waiting* state — nobody
pages on waiting. (That's exactly why you must: alert on Pending > 5 min.)

**Why it took 2 hours:** incident PTSD. After three infra breaks, we
checked endpoints, CloudTrail, and tags first — everything except our
own YAML. The answer was in line ONE of `kubectl describe pod` the
whole time: `untolerated taint {dedicated: workspaces}`.

**The real fixes:**
1. **CI lint** — every toleration must match an existing NodePool taint
2. **Alert on Pending > 5 min** — scheduling silence is a failure mode
3. **Team rule** — read the scheduler's words FIRST, infra second

**Lesson 4:** the cluster never lies. Read the events first.
(And YAML ain't compiled, ain't type-checked, ain't sorry.)
