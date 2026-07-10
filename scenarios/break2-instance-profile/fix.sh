#!/bin/bash
# FIX #2 — don't fight the guardrail, route around it:
# pre-created instance profile (Terraform made it) + spec.instanceProfile.
# One field changes. The runtime IAM write disappears.
source "$(dirname "$0")/../common.sh"

say "FIX #2 (1/2): back to the pre-created instance profile (spec.instanceProfile)"
envsubst < "$ROOT/k8s/base/karpenter-resources.yaml" | kubectl apply -f -

say "FIX #2 (2/2): removing the 'SCP' simulation deny"
aws iam delete-role-policy --role-name "$CONTROLLER_ROLE" --policy-name scp-simulation-deny 2>/dev/null || true
kubectl scale deploy/inflate --replicas=0 >/dev/null

heal "IaC owns IAM. Karpenter consumes it — never writes it."
note "Security team's reaction: 'Suspicious at first, then absolutely delighted.'"
