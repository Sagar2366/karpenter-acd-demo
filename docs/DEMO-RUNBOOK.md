# 🎬 Demo Runbook — Karpenter on real EKS (ACD Delhi)

**Talk:** I Broke Karpenter 4 Times Before It Worked in Production (45 min)
**Demo:** real EKS + Karpenter v1.13.0, live EC2 provisioning (~10 min on stage)

> 💰 **This demo costs real money.** Control plane $0.10/hr + 2× t3.medium
> + whatever Karpenter launches (~20 vCPU for a few minutes). Create the
> cluster the MORNING of the talk; run `./teardown-eks-demo.sh` the moment
> you're off stage. Full day ≈ $5–10.

## Timeline (talk = Friday 11 July 2026)

| When | What |
|------|------|
| ASAP | `aws sso login` — then full dry-run: setup → all demo steps incl. b3/b4 → TEARDOWN. Record it as the fallback video. |
| T-1 day (Jul 10) | One more rehearsal cycle, timed; test kubectl over phone hotspot; run `make record-cases` for the four-tab offline fallback |
| Talk-day morning (~25 min) | `make up` if the cluster is not already up → `./demo.sh d` → `./demo.sh r` |
| On stage | `make flow` — one guided path with pauses: safety check → happy path → all 4 breaks → cleanup |
| Immediately after | `./teardown-eks-demo.sh` + eyeball EC2 console |

## The one on-stage command

Run this on stage:

```bash
make flow
```

The flow pauses between beats. Read the output, tell the story, press Enter.
Individual `b1/f1` through `b4/f4` commands are rehearsal and recovery controls,
not the main talk path.

## Four-tab WiFi fallback

Before the venue, while internet is stable:

```bash
make record-cases
```

At the venue, open four terminal tabs and leave these outputs ready:

```bash
make replay-b1
make replay-b2
make replay-b3
make replay-b4
```

Those replay commands read local files from `artifacts/case-recordings/`; they
do not call AWS or Kubernetes. If WiFi dies, switch tabs and narrate the recorded
break/fix evidence.

## Manual flow reference (only if you need to drive by hand)

| Step | Beat | Talk track anchor |
|------|------|-------------------|
| 0 | Pre-flight: Karpenter pods, NodePool, 2 system nodes | "the machine that survived me" |
| 1 | BEFORE: 0 replicas | |
| 2 | Scale to 20 → EC2 being born | **start a timer on screen** |
| 3 | Re-run repeatedly: nodeclaims + nodes appear | narrate instance type + spot/od choice |
| 4 | Karpenter logs: its own launch reasoning | "in its own words" |
| 5 | Scale to 5 → consolidation | Break #2 flashback |
| 6 | Fleet shrinks, bounded by 20% budget | "chainsaw, bounded" |
| 7 | `do-not-disrupt` annotation live | "the guard installed" |
| 8 | Scale to 0 → fleet vanishes | "the meter stops" |

**Timebox: 10 min hard stop.** Steps 2→3 (~90 s of waiting) is where you
narrate — never stall silently; if nodes are slow, show step 4 logs.

## Dry-run results (2026-07-06 — everything verified ✅)

- Scale 0→20: **5 seconds** to 3 spot NodeClaims (c4.2xlarge, c7i-flex.2xlarge,
  m8i-flex.2xlarge) across all 3 AZs; pods Running in ~4 min total
- Karpenter logs show it considered **"c4.2xlarge, c5.2xlarge … and 35
  other(s)"** — read that line on stage
- Consolidation 20→5 pods: 3 nodes → 2 within ~2 min
- `b4`: pods Pending with TWO quotable events — the scheduler's
  `untolerated taint {dedicated: workspaces}` AND Karpenter's
  `incompatible requirements, label "dedicated-pool" does not have known values`
- `b3`: `SubnetsReady=False — "SubnetSelector did not match any Subnets"`
  within ~60s of tag removal; `b3fix` recovers within ~2 min (nodeclass reconcile interval) — narrate the lesson while it heals, don't stare
- Scale to zero: fleet drained in ~1 min

⚠ **Fix discovered in dry-run (already patched into setup-eks-demo.sh):**
the Karpenter node role needs an EKS **access entry** or instances launch
but never join (NodeClaims stuck Unknown, deleted at 15-min TTL). If you
ever see that symptom:
`aws eks create-access-entry --cluster-name acd-karpenter-demo --region ap-south-1 --principal-arn arn:aws:iam::<acct>:role/KarpenterNodeRole-acd-karpenter-demo --type EC2_LINUX`

## Failure modes & fallbacks

1. **Venue WiFi dies mid-demo** — the cluster is in ap-south-1, kubectl
   needs network. Fallback A: phone hotspot (test in rehearsal!).
   Fallback B: the recording you made during rehearsal. NEVER debug
   connectivity on stage.
2. **Spot capacity unavailable** (rare with c/m/r diversity) — NodePool
   falls back to on-demand automatically; narrate it as a Break-#3 win.
3. **Pods pending, no nodeclaims** — 99% an IAM/discovery-tag problem;
   that's literally Break #1. `kubectl logs -n kube-system -l
   app.kubernetes.io/name=karpenter | tail` and read the error aloud —
   worst case it's a live demonstration of the talk's thesis. 😉
4. **AWS creds expired on stage** — `aws sso login` before walking up;
   session should outlive the slot.

## Rehearsal checklist

- [ ] Full setup → demo → teardown cycle once, timed
- [ ] Record the whole demo (QuickTime) as the fallback video
- [ ] Test kubectl over phone hotspot
- [ ] Verify teardown leaves zero EC2 instances (console check)
- [ ] Fill real numbers into WAR-STORIES.md + deck "redemption" slide

## Cost guards baked into the demo

- NodePool `limits: cpu: 100` — Karpenter can never launch more than
  100 vCPU no matter what you scale to
- `inflate` uses pause containers (no real load)
- Consolidation reclaims empty nodes in ~1 min
- Teardown script terminates stragglers by tag and deletes the CFN stack
