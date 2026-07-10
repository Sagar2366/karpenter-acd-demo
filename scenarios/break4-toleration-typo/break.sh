#!/bin/bash
# BREAK #4 — the two-hour typo, live.
# Warm pool taint: dedicated=workspaces. Toleration: workspace.
# One character. The scheduler is polite. It refuses. Forever.
source "$(dirname "$0")/../common.sh"

say "BREAK #4: deploying the warm pool + the one-character toleration typo"
envsubst < "$ROOT/k8s/scenarios/break4-typo.yaml" | kubectl apply -f -
sleep 10

say "The symptom — pods Pending, and the cluster TELLS you why:"
kubectl get pods -l app=workspace-typo
echo
kubectl describe pod -l app=workspace-typo 2>/dev/null | grep -A4 "Events:" | tail -5 || true
echo
kubectl get events --field-selector reason=FailedScheduling \
  -o custom-columns=MSG:.message --no-headers 2>/dev/null | head -2 || true
note ""
note "Read the event out loud. 'untolerated taint {dedicated: workspaces}'."
note "In production this took 118 minutes. With the debug order: thirty seconds."
note "Fix with: ./fix.sh"
