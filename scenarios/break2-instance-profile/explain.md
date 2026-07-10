# Break #2 — the invisible IAM write

**Little-known EC2 fact:** instances don't attach IAM *roles* — they attach
instance **profiles** (a wrapper). Consoles create them silently, so most
people never learn profiles exist.

So when your `EC2NodeClass` says `spec.role`, Karpenter quietly calls
`iam:CreateInstanceProfile` at runtime to wrap it. In a sandbox: invisible
convenience. In an enterprise: **a workload writing IAM at runtime** —
exactly what Service Control Policies exist to stop.

**The error, verbatim:**
```
AccessDenied: … not authorized to perform: iam:CreateInstanceProfile
… with an explicit deny in a service control policy
```
An explicit deny beats every allow. Even root. There is no appeal court —
it's the Supreme Court of your AWS org.

**The reenactment:** `break.sh` attaches an explicit-deny inline policy to
the controller role (our fake SCP) and flips the EC2NodeClass to
`spec.role`. NodeClaims hit the wall within a minute.

**The fix:** `spec.instanceProfile` pointing at the profile **Terraform
pre-created**. One field. The runtime IAM write disappears — and the
controller can drop all `iam:*` write permissions.

**Lesson 2:** IaC owns IAM. Runtime tools consume identity — never create it.
