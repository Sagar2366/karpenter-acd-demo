# I Broke Karpenter 4 Times Before It Worked in Production

Demo kit for the talk at **AWS Community Day Delhi 2026** by [Sagar Utekar](https://github.com/Sagar2366).

Real EKS. Real EC2. Real money — `make down` when you're done. 💸

## Scenarios

The talk-day path is **one command**:

```bash
make flow
```

It runs the safety checks, happy path, all four breaks, each fix, and a final cleanup check. It pauses between beats so you can talk, read the output, and press Enter for the next scene.

| # | Break | Fix | What you'll see |
|---|-------|-----|-----------------|
| 1 | `make b1` | `make f1` | Pod Identity deleted → pods Running but not working |
| 2 | `make b2` | `make f2` | `AccessDenied: iam:CreateInstanceProfile` (simulated SCP) |
| 3 | `make b3` | `make f3` | `SubnetsReady=False` — discovery tags stripped |
| 4 | `make b4` | `make f4` | `untolerated taint {dedicated: workspaces}` — the 118-min typo |

Each scenario has an `explain.md` with the full production story.

## Run it

```bash
# prereqs: terraform >= 1.5, aws cli, kubectl, envsubst, jq

make up       # VPC + EKS + Karpenter (~20 min)
make flow     # the single on-stage flow
make down     # destroy everything — don't skip this
```

For rehearsal or emergency recovery only:

```bash
make demo     # interactive menu
make b1 f1    # run one break/fix pair manually
make b2 f2
make b3 f3
make b4 f4
```

## Venue WiFi Fallback

Before you leave for the venue, record the four break/fix stories while internet is good:

```bash
make record-cases
```

At the venue, keep four terminal tabs open. These commands read local recordings only; they do not call AWS or Kubernetes:

```bash
make replay-b1
make replay-b2
make replay-b3
make replay-b4
```

If WiFi dies, switch to the relevant tab and narrate from the recorded output.

## Flow

`make flow` is the canonical order:

1. Doctor + guarded cleanup
2. Pre-flight and before-state
3. Happy path: scale up, watch NodeClaims, show Karpenter logs
4. Consolidation: scale down, show bounded disruption, scale to zero
5. Break #1 + fix: Pod Identity
6. Break #2 + fix: instance profile / IAM explicit deny
7. Break #3 + fix: discovery tags
8. Break #4 + fix: toleration typo
9. Reset + doctor so the cluster is boring again

## Debug order for Pending pods

1. `kubectl describe pod` — scheduler tells you the truth
2. `kubectl get nodeclaims` — did Karpenter try?
3. Karpenter logs — why it couldn't
4. `kubectl get ec2nodeclass -o yaml` — what discovery resolved
5. CloudTrail — last resort, not first

## Links

- [Karpenter docs](https://karpenter.sh)
- [Demo runbook](docs/DEMO-RUNBOOK.md)
