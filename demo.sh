#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  ACD Bangalore — Karpenter LIVE DEMO DRIVER (real EKS!)
#  Usage: ./demo.sh          (interactive menu)
#         ./demo.sh 2        (run one step and exit)
#
#  Each step prints WHAT we're doing, the COMMAND, then the OUTPUT.
#  Prereq: ./setup-eks-demo.sh done, kubectl context on the EKS cluster.
# ══════════════════════════════════════════════════════════════════
BOLD=$(tput bold 2>/dev/null); DIM=$(tput dim 2>/dev/null)
GREEN=$(tput setaf 2 2>/dev/null); CYAN=$(tput setaf 6 2>/dev/null)
YELLOW=$(tput setaf 3 2>/dev/null); RESET=$(tput sgr0 2>/dev/null)
say() { echo; echo "${BOLD}${CYAN}▶ $1${RESET}"; }
cmd() { echo "${DIM}\$ $1${RESET}"; }

step_0() {
  say "Pre-flight: Karpenter is alive, NodePool is ready, no demo nodes yet"
  cmd "kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter"
  kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
  cmd "kubectl get nodepools"
  kubectl get nodepools
  cmd "kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type"
  kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
}

step_1() {
  say "The 'BEFORE': 0 replicas of our workload, only the 2 system nodes"
  cmd "kubectl get deploy inflate; kubectl get pods -l app=inflate"
  kubectl get deploy inflate
  kubectl get pods -l app=inflate 2>/dev/null || true
}

step_2() {
  say "🚀 Scale to 20 pods — watch Karpenter buy REAL EC2 in real time"
  cmd "kubectl scale deploy/inflate --replicas=20"
  kubectl scale deploy/inflate --replicas=20
  echo "${YELLOW}(pods go Pending → Karpenter computes cheapest fit → EC2 launches ~40-60s)${RESET}"
}

step_3() {
  say "Watch it happen: pending pods + nodeclaims + fresh nodes"
  cmd "kubectl get pods -l app=inflate | head -8"
  kubectl get pods -l app=inflate | head -8
  cmd "kubectl get nodeclaims"
  kubectl get nodeclaims
  cmd "kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type"
  kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type
  echo "${DIM}(re-run this step every ~15s and narrate — instance type & spot/od chosen live)${RESET}"
}

step_4() {
  say "WHY did it pick that? Karpenter's decision, in its own words"
  cmd "kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=200 | grep -E 'launched|created' | tail -5"
  kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=200 2>/dev/null | grep -E "launched|created nodeclaim" | tail -5
}

step_5() {
  say "Break-#2 flashback (SAFE): scale down to 5 — consolidation kicks in"
  cmd "kubectl scale deploy/inflate --replicas=5"
  kubectl scale deploy/inflate --replicas=5
  echo "${YELLOW}(within ~1-2 min Karpenter disrupts underutilized nodes — bounded by our 20% budget)${RESET}"
}

step_6() {
  say "Watch consolidation: nodes draining and disappearing"
  cmd "kubectl get nodeclaims; kubectl get nodes -L karpenter.sh/capacity-type"
  kubectl get nodeclaims
  kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type
  cmd "kubectl get events --field-selector reason=DisruptionBlocked,reason=Unconsolidatable -A | tail -4"
  kubectl get events -A --field-selector source=karpenter 2>/dev/null | tail -6
}

step_7() {
  say "Break-#2 lesson LIVE: annotate a pod do-not-disrupt — consolidation must respect it"
  POD=$(kubectl get pods -l app=inflate -o name | head -1)
  cmd "kubectl annotate $POD karpenter.sh/do-not-disrupt=true"
  kubectl annotate "$POD" karpenter.sh/do-not-disrupt=true --overwrite
  echo "${GREEN}That pod's node is now untouchable — chainsaw guard installed.${RESET}"
}

step_8() {
  say "The 'AFTER': scale to 0 — Karpenter returns every node, bill stops"
  cmd "kubectl scale deploy/inflate --replicas=0"
  kubectl scale deploy/inflate --replicas=0
  echo "${YELLOW}(empty nodes reclaimed in ~1 min — re-run step 3 to show them vanish)${RESET}"
}

step_b3() {
  say "BREAK #3 REENACTMENT: remove the discovery tag — watch discovery fail"
  CLUSTER="${CLUSTER_NAME:-karpenter-acd-demo}"; REGION="${AWS_REGION:-ap-south-1}"
  SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER" \
    --query "Subnets[].SubnetId" --output text)
  echo "  tagged subnets: $SUBNETS"
  cmd "aws ec2 delete-tags (karpenter.sh/discovery) on all demo subnets"
  aws ec2 delete-tags --resources $SUBNETS --tags "Key=karpenter.sh/discovery" --region "$REGION"
  kubectl scale deploy/inflate --replicas=25
  echo "${YELLOW}Now watch it fail exactly like production did (takes ~30-60s to reconcile):${RESET}"
  cmd "kubectl get ec2nodeclass default → SubnetsReady condition"
  for i in $(seq 1 12); do
    ST=$(kubectl get ec2nodeclass default -o jsonpath='{.status.conditions[?(@.type=="SubnetsReady")].status}' 2>/dev/null)
    [ "$ST" = "False" ] && break
    sleep 5
  done
  echo "SubnetsReady = ${ST:-unknown}"
  kubectl get ec2nodeclass default -o jsonpath='{.status.conditions[?(@.type=="SubnetsReady")].message}' 2>/dev/null; echo
  cmd "karpenter events mentioning subnets"
  kubectl get events -A --field-selector source=karpenter 2>/dev/null | grep -i subnet | tail -2
  echo
  echo "${YELLOW}To RESTORE (do this on stage!): ./demo.sh b3fix${RESET}"
}

step_b3fix() {
  say "RESTORE the discovery tags — recovery, live"
  CLUSTER="${CLUSTER_NAME:-karpenter-acd-demo}"; REGION="${AWS_REGION:-ap-south-1}"
  VPC=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query "cluster.resourcesVpcConfig.vpcId" --output text)
  SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" "Name=tag:aws:cloudformation:logical-id,Values=*Private*" \
    --query "Subnets[].SubnetId" --output text)
  [ -z "$SUBNETS" ] && SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC" "Name=map-public-ip-on-launch,Values=false" \
    --query "Subnets[].SubnetId" --output text)
  echo "  re-tagging: $SUBNETS"
  aws ec2 create-tags --resources $SUBNETS --tags "Key=karpenter.sh/discovery,Value=$CLUSTER" --region "$REGION"
  echo "${GREEN}Tags restored — nodes will launch within ~60s. Re-run step 3 to show recovery.${RESET}"
}

step_b4() {
  say "BREAK #4 REENACTMENT: the one-character toleration typo, live"
  cmd "apply tainted NodePool + workload with typo'd toleration (workspace vs workspaces)"
  kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workspace-typo
spec:
  replicas: 3
  selector: { matchLabels: { app: workspace-typo } }
  template:
    metadata: { labels: { app: workspace-typo } }
    spec:
      tolerations:
        - key: dedicated
          operator: Equal
          value: workspace        # ← THE TYPO (pool taint says 'workspaces')
          effect: NoSchedule
      nodeSelector: { dedicated-pool: "true" }
      containers:
        - name: pause
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources: { requests: { cpu: 500m } }
YAML
  sleep 8
  cmd "kubectl describe pod -l app=workspace-typo | grep -A3 Events"
  kubectl get pods -l app=workspace-typo
  kubectl describe pod -l app=workspace-typo 2>/dev/null | grep -A4 "Events:" | tail -4
  echo "${YELLOW}Read the event out loud — the cluster is TELLING you the answer.${RESET}"
  echo "${YELLOW}Fix live: kubectl patch ... value: workspaces  (or ./demo.sh b4fix to clean up)${RESET}"
}

step_b4fix() {
  say "Clean up the typo demo"
  kubectl delete deploy workspace-typo --ignore-not-found
}

step_r() {
  say "RESET between rehearsals: scale to 0, wait for nodes to drain"
  kubectl scale deploy/inflate --replicas=0
  kubectl delete deploy workspace-typo --ignore-not-found 2>/dev/null
  kubectl get pods -l app=inflate --no-headers 2>/dev/null | wc -l | xargs echo "  inflate pods remaining:"
  kubectl get nodeclaims
}

menu() {
  echo
  echo "${BOLD}══ Karpenter Live Demo (REAL EC2 — mind the meter 💰) ══${RESET}"
  echo "  0) Pre-flight: Karpenter, NodePool, current nodes"
  echo "  1) BEFORE: 0 replicas, system nodes only"
  echo "  2) 🚀 Scale to 20 — Karpenter buys EC2 live"
  echo "  3) Watch: pods / nodeclaims / new nodes    ${DIM}(re-run repeatedly)${RESET}"
  echo "  4) Show Karpenter's launch decisions (logs)"
  echo "  5) Scale to 5 — consolidation begins"
  echo "  6) Watch consolidation shrink the fleet"
  echo "  7) do-not-disrupt annotation (Break-#2 lesson, live)"
  echo "  8) AFTER: scale to 0 — nodes vanish, meter stops"
  echo "  b3) 💥 Reenact Break #3: kill discovery tags   b3fix) restore"
  echo "  b4) 💥 Reenact Break #4: the toleration typo   b4fix) cleanup"
  echo "  r) Reset between rehearsals"
  echo "  q) Quit"
  echo
}

run_step() {
  case "$1" in
    0|1|2|3|4|5|6|7|8) "step_$1" ;;
    b3) step_b3 ;; b3fix) step_b3fix ;;
    b4) step_b4 ;; b4fix) step_b4fix ;;
    r|R) step_r ;;
    q|Q) exit 0 ;;
    *) echo "Unknown option: $1" ;;
  esac
}

if [ $# -ge 1 ]; then run_step "$1"; exit 0; fi
while true; do
  menu; printf "${BOLD}Step> ${RESET}"; read -r choice; run_step "$choice"
  echo; printf "${DIM}(Enter for menu)${RESET}"; read -r _
done
