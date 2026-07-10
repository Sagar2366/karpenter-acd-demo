#!/bin/bash
# BREAK #1 — Pod Identity, meet private subnets.
# Real story: the eks-auth VPC endpoint didn't exist, so the Pod
# Identity agent could never exchange tokens. Reenactment here:
# delete the pod-identity ASSOCIATION out-of-band — same effect,
# Karpenter cannot get AWS credentials.
source "$(dirname "$0")/../common.sh"

say "BREAK #1: deleting Karpenter's pod-identity association (out-of-band, like a helpful colleague)"
ASSOC_ID=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --namespace kube-system --service-account karpenter \
  --query "associations[0].associationId" --output text)
[ "$ASSOC_ID" = "None" ] && { note "No association found — already broken?"; exit 0; }
aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --association-id "$ASSOC_ID"
boom "Association $ASSOC_ID deleted."

say "Restarting Karpenter so it must fetch fresh credentials"
kubectl -n kube-system rollout restart deploy/karpenter
sleep 20

say "The symptom — watch the credentials fail:"
kubectl -n kube-system logs deploy/karpenter --tail=20 2>/dev/null | grep -iE "credential|unauthorized|denied|error" | tail -5 || true
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
note ""
note "The pods may still show Running — remember: Running is not working."
note "Try scaling:  kubectl scale deploy/inflate --replicas=5   → nothing will happen."
note "Fix with:     ./fix.sh   (or: cd terraform && terraform apply — IaC heals)"
