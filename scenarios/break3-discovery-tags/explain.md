# Break #3 — the discovery tags that "looked correct"

**The real production story:** a shared IaC module (another team's)
sprayed `karpenter.sh/discovery` on ALL its subnets — including two
isolated ones with no route to the EKS control plane, built for a
database that never shipped.

**The part nobody tells you:** when several subnets match, Karpenter
prefers the one with the most **free IPs**. Which subnet has the most
free IPs? The completely empty, isolated one. **Always.** The most
attractive subnet is the most useless one.

**The symptom chain:** tags matched ✓ → status resolved ✓ → EC2 instance
launched ✓ (AWS happily bills) → node **never joined** → NodeClaim
NotReady → deleted at the 15-minute registration TTL → retry roulette.

**Launched ≠ joined.** EC2's job ends at "instance running". Whether that
instance can reach your API server is your problem.

**This reenactment** strips the tags entirely (discovery finds *nothing* —
the same failure class, visible in seconds): `SubnetsReady=False —
"SubnetSelector did not match any Subnets"`.

**The fix:** the tags live in Terraform (`private_subnet_tags`), so
`terraform apply` heals them. Then: read the status after every deploy —
`kubectl get ec2nodeclass -o yaml` shows what discovery ACTUALLY resolved.

**Lesson 3:** validate WHAT resolved, not THAT it resolved.
