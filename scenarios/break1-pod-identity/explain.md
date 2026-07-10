# Break #1 — Pod Identity, meet private subnets

**The real production story:** fully private VPC. Pod Identity agent must
exchange tokens with the **EKS Auth API** — which needs the
`com.amazonaws.<region>.eks-auth` VPC endpoint. We had endpoints for EC2,
ECR, S3, STS… built over years. `eks-auth`? Nobody had ever needed it.
The feature was newer than the VPC.

**The symptom:** Karpenter pods **Running 2/2** — but every AWS call:
`dial tcp … i/o timeout`. Running ≠ working. Kubernetes checks whether the
process is alive, not whether it can do its job.

**Timeout vs Denied:** `AccessDenied` = IAM said no → argue with a policy.
`i/o timeout` = nobody picked up the phone → it's the NETWORK.

**This reenactment** deletes the pod-identity *association* instead
(same effect on a demo cluster with internet): Karpenter can't get
credentials, and does nothing — silently.

**The fix:** in production, one VPC endpoint (5 lines of Terraform, after
2 days of debugging). Here, `./fix.sh` or `terraform apply`.

**Lesson 1:** identity features still ride on network paths. Inventory
your VPC endpoints BEFORE the migration — 20 minutes, saves 2 days.
