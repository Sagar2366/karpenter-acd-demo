#!/bin/bash
# FIX #1 — recreate the association. The proper way is `terraform apply`
# (IaC owns identity); we use the CLI here for stage speed, with the
# same role ARN Terraform created.
source "$(dirname "$0")/../common.sh"

say "FIX #1: recreating the pod-identity association (terraform apply would do the same)"
aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --namespace kube-system --service-account karpenter \
  --role-arn "$CONTROLLER_ROLE_ARN" >/dev/null
kubectl -n kube-system rollout restart deploy/karpenter
kubectl -n kube-system rollout status deploy/karpenter --timeout=120s
heal "Credentials flow again — Karpenter is WORKING (not just Running)."
note "Lesson 1: identity features still need paths (and associations). Inventory BEFORE migration."
note "Run 'cd terraform && terraform apply' later so state matches reality again."
