# I Broke Karpenter 4 Times Before It Worked in Production

Demo kit for the talk at **AWS Community Day Bengaluru 2026** by
[Sagar Utekar](https://github.com/Sagar2366) ([@me_sagar_utekar](https://x.com/me_sagar_utekar)).

Real EKS. Real EC2. Real money — **mind the meter.** 💰

> Every break in this repo was a real production incident. Break them here,
> in a demo cluster, on purpose — it's cheaper. **Your postmortems become
> conference talks. Apparently.**

## What you get

- **Terraform** base infra — VPC, EKS 1.33, Karpenter 1.13 via Pod Identity,
  **pre-created instance profile** (IaC owns IAM — that's Lesson 2, encoded)
- **The happy path** — scale 0→20, watch Karpenter buy EC2 in ~40s, consolidate,
  scale to zero (the entire business case)
- **All 4 production breaks** as runnable scenarios: break it → read the real
  error → fix it. Every fix returns reality to what Terraform declares.

| Scenario | What breaks | The error you'll see | Lesson |
|---|---|---|---|
| `make b1` | Pod Identity credentials (association deleted out-of-band) | credential fetch failures; pods **Running but not working** | Identity features still need network paths |
| `make b2` | Runtime `iam:CreateInstanceProfile` vs an **explicit deny** (simulated SCP) | `AccessDenied … with an explicit deny` | IaC owns IAM; Karpenter consumes it |
| `make b3` | `karpenter.sh/discovery` tags stripped out-of-band | `SubnetsReady=False — did not match any Subnets` | Validate WHAT resolved, not THAT it resolved |
| `make b4` | The one-character toleration typo (`workspace` vs `workspaces`) | `untolerated taint {dedicated: workspaces}` — **118 minutes of Pending**, in prod | The cluster never lies — read events first |

Each scenario folder has an `explain.md` with the full production story.

## Quickstart

```bash
# prereqs: terraform >= 1.5, aws cli (valid creds), kubectl, envsubst
make up        # VPC + EKS + Karpenter (~20 min) + NodePool + workload
make demo      # interactive happy-path driver (scale up / consolidate / zero)

make b3        # 💥 break discovery   →  make f3  ✅ fix
make b4        # 💥 break scheduling  →  make f4  ✅ fix
make b1 f1 b2 f2   # the other two

make down      # destroy EVERYTHING. Do not skip this. 💸
```

**Cost:** control plane ~$0.10/hr + 1 NAT gateway + 2× t3.medium + whatever
Karpenter launches (pause containers, `limits.cpu: 100` cap). A full demo
day ≈ **$5–10**. `make down` the moment you're done, then eyeball the EC2
console — trust, but verify.

## Debugging Pending pods — in this order

1. `kubectl describe pod` — the scheduler tells you the truth
2. `kubectl get nodeclaims` + events — did Karpenter even try?
3. Karpenter controller logs — why it couldn't / wouldn't
4. `kubectl get ec2nodeclass -o yaml` — what discovery ACTUALLY resolved
5. CloudTrail — what AWS denied (LAST, not first)

Most people run this backwards and drown in CloudTrail JSON for an hour.
My 118-minute typo was step ONE.

## The checklist I wish I had

**Before install:** inventory VPC endpoints for every API Karpenter touches
(`eks-auth`!) · pre-create node role AND instance profile in IaC · read your
SCPs before your controllers do.

**Before trust:** lint taints vs tolerations in CI · alert on Pending > 5 min ·
migrate one workload first, keep a managed node group as a lifeboat · break it
in staging — four times if needed. It's cheaper there.

## Links

- Karpenter: <https://karpenter.sh>
- EKS Pod Identity: <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>
- Runbook for presenting this demo: [docs/DEMO-RUNBOOK.md](docs/DEMO-RUNBOOK.md)

Break things. In staging. On purpose. 🙏

## Terraform notes (reviewed against [terraform-skill](https://github.com/antonbabenko/terraform-skill))

- **State is local, on purpose** — this is a throwaway solo demo. For anything
  shared, add an S3 backend (`use_lockfile = true` on Terraform 1.10+).
- **`.terraform.lock.hcl` is committed** — you run the exact providers that
  were validated.
- **`make down` shows the destroy plan and asks** before deleting anything;
  `make nuke` is the post-talk emergency exit (auto-approve — you were warned).
- **Break #3 has a Terraform-native detector**: a `check` block asserts the
  discovery tags exist, so `terraform plan` warns you when discovery is broken.
  "Validate WHAT resolved" — encoded in IaC.

Validate locally: `terraform fmt -check && terraform validate`
(optionally `trivy config .` / `checkov -d .`).
