#!/bin/bash
# BREAK #2 — Karpenter wants to write IAM. Production says no.
# We attach an EXPLICIT DENY for iam:CreateInstanceProfile to the
# controller role (our stand-in for the org's SCP), then switch the
# EC2NodeClass to role-mode so Karpenter must create a profile at
# runtime. Result: the exact AccessDenied from the talk.
source "$(dirname "$0")/../common.sh"

say "BREAK #2 (1/2): attaching the 'SCP' — explicit deny on iam:CreateInstanceProfile"
aws iam put-role-policy --role-name "$CONTROLLER_ROLE" --policy-name scp-simulation-deny \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Deny",
      "Action": ["iam:CreateInstanceProfile","iam:AddRoleToInstanceProfile","iam:TagInstanceProfile"],
      "Resource": "*"
    }]
  }'
boom "Explicit deny in place. (An explicit deny beats EVERY allow. No appeal.)"

say "BREAK #2 (2/2): switching EC2NodeClass to role-mode (runtime profile creation)"
envsubst < "$ROOT/k8s/scenarios/break2-nodeclass-role.yaml" | kubectl apply -f -
kubectl scale deploy/inflate --replicas=5 >/dev/null

note "Waiting for the NodeClaim to hit the wall (~30-60s)…"
for i in $(seq 1 12); do
  MSG=$(kubectl get nodeclaims -o jsonpath='{.items[0].status.conditions[?(@.type=="Launched")].message}' 2>/dev/null || true)
  echo "$MSG" | grep -qi "denied" && break
  sleep 5
done

say "The symptom:"
kubectl get nodeclaims 2>/dev/null || true
kubectl describe nodeclaim 2>/dev/null | grep -iE "denied|instance profile" | head -4 || \
  kubectl -n kube-system logs deploy/karpenter --tail=50 | grep -iE "denied|CreateInstanceProfile" | tail -3 || true
note ""
note "'Explicit deny in a service control policy' = AWS for: stop arguing, find a human."
note "Fix with: ./fix.sh"
