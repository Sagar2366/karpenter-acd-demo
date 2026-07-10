#!/bin/bash
# FIX #4 — one character. Then the REAL fixes (see explain.md):
# CI lint, Pending-age alert, read-the-scheduler-first team rule.
source "$(dirname "$0")/../common.sh"

say "FIX #4: value: workspace → workspaces (the 's' that cost 118 minutes)"
envsubst < "$ROOT/k8s/scenarios/break4-fixed.yaml" | kubectl apply -f -
note "Watch them schedule (warm-pool node may take ~60s to launch):"
sleep 15
kubectl get pods -l app=workspace-typo
kubectl get nodeclaims 2>/dev/null || true
heal "Scheduled. One character. Ten seconds."
echo
note "Cleanup when done:  kubectl delete deploy workspace-typo; kubectl delete nodepool warm-pool"
