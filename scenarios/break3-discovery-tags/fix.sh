#!/bin/bash
# FIX #3 — retag the private subnets. Terraform owns these tags
# (module.vpc private_subnet_tags), so `terraform apply` is the real
# fix; the CLI below is the stage-speed version of the same thing.
source "$(dirname "$0")/../common.sh"

say "FIX #3: restoring discovery tags on the private subnets"
SUBNETS=$(terraform -chdir="$TF" output -json private_subnet_ids 2>/dev/null | tr -d '[]" ' | tr ',' ' ')
[ -z "$SUBNETS" ] && SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=tag:project,Values=karpenter-acd-demo" "Name=map-public-ip-on-launch,Values=false" \
  --query "Subnets[].SubnetId" --output text)
echo "  re-tagging: $SUBNETS"
aws ec2 create-tags --resources $SUBNETS \
  --tags "Key=karpenter.sh/discovery,Value=$CLUSTER_NAME" --region "$AWS_REGION"

note "Waiting for SubnetsReady=True…"
for i in $(seq 1 12); do
  ST=$(kubectl get ec2nodeclass default -o jsonpath='{.status.conditions[?(@.type=="SubnetsReady")].status}' 2>/dev/null || true)
  [ "$ST" = "True" ] && break
  sleep 5
done
echo "SubnetsReady = ${ST:-unknown}"
heal "Discovery healed — pending pods will get nodes within ~60s."
note "Lesson 3: validate WHAT resolved, not THAT it resolved. Selectors are grep, not intent."
