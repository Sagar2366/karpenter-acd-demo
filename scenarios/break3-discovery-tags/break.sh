#!/bin/bash
# BREAK #3 — the discovery tags that "looked correct".
# Delete the karpenter.sh/discovery tags out-of-band (the shared-module
# story in reverse) and watch discovery come up empty.
source "$(dirname "$0")/../common.sh"

say "BREAK #3: stripping karpenter.sh/discovery tags from all subnets (out-of-band)"
SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" \
  --query "Subnets[].SubnetId" --output text)
[ -z "$SUBNETS" ] && { note "No tagged subnets found — already broken?"; exit 0; }
echo "  victims: $SUBNETS"
aws ec2 delete-tags --resources $SUBNETS --tags "Key=karpenter.sh/discovery" --region "$AWS_REGION"
boom "Tags gone. Nothing crashed. Everything is still green. (That's the scary part.)"

kubectl scale deploy/inflate --replicas=10 >/dev/null
note "Scaled inflate to 10 — new capacity is needed, and discovery will fail (~30-60s)…"
for i in $(seq 1 12); do
  ST=$(kubectl get ec2nodeclass default -o jsonpath='{.status.conditions[?(@.type=="SubnetsReady")].status}' 2>/dev/null || true)
  [ "$ST" = "False" ] && break
  sleep 5
done

say "The symptom — read the STATUS, not vibes:"
echo "SubnetsReady = ${ST:-unknown}"
kubectl get ec2nodeclass default -o jsonpath='{.status.conditions[?(@.type=="SubnetsReady")].message}' 2>/dev/null; echo
note ""
note "Karpenter TELLS you what it resolved: kubectl get ec2nodeclass default -o yaml | grep -A10 'status:'"
note "Fix with: ./fix.sh   (or: cd terraform && terraform apply — the tags live in main.tf)"
