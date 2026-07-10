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
note() { echo "${YELLOW}$1${RESET}"; }
ok() { echo "${GREEN}$1${RESET}"; }

tf_out() { terraform -chdir=terraform output -raw "$1" 2>/dev/null; }

cluster_name() {
  if [ -n "${CLUSTER_NAME:-}" ]; then echo "$CLUSTER_NAME"; return; fi
  local v; v=$(tf_out cluster_name || true)
  echo "${v:-karpenter-acd-demo}"
}

region_name() {
  if [ -n "${AWS_REGION:-}" ]; then echo "$AWS_REGION"; return; fi
  local v; v=$(tf_out region || true)
  echo "${v:-ap-south-1}"
}

cluster_vpc() {
  aws eks describe-cluster --name "$1" --region "$2" \
    --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null
}

tf_nodegroup_name() {
  if ! command -v jq >/dev/null 2>&1; then return 0; fi
  jq -r '
    .resources[]
    | select(.type == "aws_eks_node_group")
    | .instances[].attributes.node_group_name
    | select(. != null)
  ' terraform/terraform.tfstate 2>/dev/null | head -1
}

has_words() {
  [ -n "$(echo "$*" | tr -d '[:space:]')" ]
}

confirm() {
  printf "%s [y/N] " "$1"
  read -r ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

live_nodegroups() {
  aws eks list-nodegroups --cluster-name "$1" --region "$2" \
    --query "nodegroups[]" --output text 2>/dev/null
}

orphan_nodegroups() {
  local CLUSTER="$1" REGION="$2" TF_NG="$3" ng out=""
  [ -z "$TF_NG" ] && return 0
  for ng in $(live_nodegroups "$CLUSTER" "$REGION"); do
    [ "$ng" != "$TF_NG" ] && out="$out $ng"
  done
  echo "$out"
}

stale_discovery_resources() {
  local CLUSTER="$1" REGION="$2" VPC="$3" SUBNETS SGS
  [ -z "$VPC" ] && return 0
  SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER" \
    --query "Subnets[?VpcId!='${VPC}'].SubnetId" --output text 2>/dev/null)
  SGS=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER" \
    --query "SecurityGroups[?VpcId!='${VPC}'].GroupId" --output text 2>/dev/null)
  echo "$SUBNETS $SGS"
}

karpenter_instance_ids() {
  aws ec2 describe-instances --region "$1" \
    --filters "Name=tag:karpenter.sh/nodepool,Values=*" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null
}

force_karpenter_reconcile() {
  cmd "kubectl annotate ec2nodeclass default demo-cleanup=$(date +%Y%m%d%H%M%S) --overwrite"
  kubectl annotate ec2nodeclass default "demo-cleanup=$(date +%Y%m%d%H%M%S)" --overwrite >/dev/null 2>&1 || true
  cmd "kubectl rollout restart deploy/karpenter -n kube-system"
  kubectl rollout restart deploy/karpenter -n kube-system >/dev/null 2>&1 || true
  kubectl rollout status deploy/karpenter -n kube-system --timeout=180s || true
}

step_0() {
  say "Pre-flight: Karpenter is alive, NodePool is ready, no demo nodes yet"
  cmd "kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter"
  kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
  cmd "kubectl get nodepools"
  kubectl get nodepools
  cmd "kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type"
  kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
  SYSTEM_NODES=$(kubectl get nodes -l '!karpenter.sh/nodepool' --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${SYSTEM_NODES:-0}" != "2" ]; then
    note "Expected 2 baseline system nodes, found ${SYSTEM_NODES:-unknown}. Run option d, then c if it reports a duplicate managed nodegroup."
  fi
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

step_d() {
  say "DOCTOR: check the stale states that broke rehearsal"
  local CLUSTER REGION VPC TF_NG LIVE_NGS ORPHANS STALE_RESOURCES STRAY_EC2 NODECLASS_DELETING NODECLAIMS
  CLUSTER=$(cluster_name); REGION=$(region_name); VPC=$(cluster_vpc "$CLUSTER" "$REGION")

  echo "cluster: $CLUSTER"
  echo "region:  $REGION"
  echo "vpc:     ${VPC:-unknown}"

  cmd "kubectl current-context"
  kubectl config current-context
  cmd "kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter"
  kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
  cmd "kubectl get nodepool default; kubectl get ec2nodeclass default"
  kubectl get nodepool default 2>/dev/null || true
  kubectl get ec2nodeclass default 2>/dev/null || true

  TF_NG=$(tf_nodegroup_name)
  LIVE_NGS=$(live_nodegroups "$CLUSTER" "$REGION")
  ORPHANS=$(orphan_nodegroups "$CLUSTER" "$REGION" "$TF_NG")
  echo "terraform nodegroup: ${TF_NG:-unknown - install jq or inspect terraform state}"
  echo "live nodegroups:     ${LIVE_NGS:-none}"
  if has_words "$ORPHANS"; then
    note "finding: extra managed nodegroup(s):$ORPHANS"
  else
    ok "nodegroups: no extra managed nodegroup found"
  fi

  STALE_RESOURCES=$(stale_discovery_resources "$CLUSTER" "$REGION" "$VPC")
  if has_words "$STALE_RESOURCES"; then
    note "finding: stale karpenter.sh/discovery tags outside cluster VPC:$STALE_RESOURCES"
  else
    ok "discovery tags: only current VPC resources matched"
  fi

  NODECLASS_DELETING=$(kubectl get ec2nodeclass default -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
  if [ -n "$NODECLASS_DELETING" ]; then
    note "finding: EC2NodeClass/default is stuck deleting at $NODECLASS_DELETING"
  else
    ok "ec2nodeclass: not stuck deleting"
  fi

  NODECLAIMS=$(kubectl get nodeclaims --no-headers 2>/dev/null)
  if has_words "$NODECLAIMS"; then
    note "nodeclaims still present:"
    kubectl get nodeclaims
  else
    ok "nodeclaims: none"
  fi

  STRAY_EC2=$(karpenter_instance_ids "$REGION")
  if has_words "$STRAY_EC2"; then
    note "finding: Karpenter-tagged EC2 instances still exist:$STRAY_EC2"
  else
    ok "karpenter EC2: no pending/running/stopped leftovers"
  fi

  echo
  note "If doctor reports stale state, run option c. Then run 0 and 1 before the live demo."
}

step_c() {
  say "CLEAN: guarded cleanup of known stale demo state"
  local CLUSTER REGION VPC TF_NG ORPHANS STALE_RESOURCES STRAY_EC2 NODECLASS_DELETING NODECLAIMS touched_discovery=""
  CLUSTER=$(cluster_name); REGION=$(region_name); VPC=$(cluster_vpc "$CLUSTER" "$REGION")

  cmd "kubectl scale deploy/inflate --replicas=0"
  kubectl scale deploy/inflate --replicas=0 || true
  cmd "kubectl delete deploy workspace-typo --ignore-not-found"
  kubectl delete deploy workspace-typo --ignore-not-found 2>/dev/null || true
  cmd "kubectl delete nodepool warm-pool --ignore-not-found"
  kubectl delete nodepool warm-pool --ignore-not-found 2>/dev/null || true

  TF_NG=$(tf_nodegroup_name)
  ORPHANS=$(orphan_nodegroups "$CLUSTER" "$REGION" "$TF_NG")
  if has_words "$ORPHANS"; then
    note "Terraform owns: ${TF_NG:-unknown}"
    note "Extra live nodegroup(s):$ORPHANS"
    if confirm "Delete the extra EKS managed nodegroup(s)?"; then
      for ng in $ORPHANS; do
        cmd "aws eks delete-nodegroup --nodegroup-name $ng"
        aws eks delete-nodegroup --cluster-name "$CLUSTER" --region "$REGION" --nodegroup-name "$ng" || true
        cmd "aws eks wait nodegroup-deleted --nodegroup-name $ng"
        aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --region "$REGION" --nodegroup-name "$ng" || true
      done
    fi
  else
    ok "No extra EKS managed nodegroup found."
  fi

  STALE_RESOURCES=$(stale_discovery_resources "$CLUSTER" "$REGION" "$VPC")
  if has_words "$STALE_RESOURCES"; then
    note "Stale discovery-tagged resources outside $VPC:$STALE_RESOURCES"
    if confirm "Remove only the karpenter.sh/discovery tag from those stale resources?"; then
      cmd "aws ec2 delete-tags --resources $STALE_RESOURCES --tags Key=karpenter.sh/discovery"
      aws ec2 delete-tags --region "$REGION" --resources $STALE_RESOURCES --tags "Key=karpenter.sh/discovery"
      touched_discovery="yes"
    fi
  else
    ok "No stale cross-VPC discovery tags found."
  fi

  NODECLAIMS=$(kubectl get nodeclaims --no-headers 2>/dev/null)
  NODECLASS_DELETING=$(kubectl get ec2nodeclass default -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
  if [ -n "$NODECLASS_DELETING" ] && ! has_words "$NODECLAIMS"; then
    note "EC2NodeClass/default is stuck deleting, and no NodeClaims exist."
    if confirm "Clear the stuck EC2NodeClass finalizer?"; then
      cmd "kubectl patch ec2nodeclass default --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'"
      kubectl patch ec2nodeclass default --type=merge -p '{"metadata":{"finalizers":[]}}' || true
    fi
  fi

  STRAY_EC2=$(karpenter_instance_ids "$REGION")
  NODECLAIMS=$(kubectl get nodeclaims --no-headers 2>/dev/null)
  if has_words "$STRAY_EC2" && ! has_words "$NODECLAIMS"; then
    note "Karpenter-tagged EC2 instances remain but no NodeClaims exist:$STRAY_EC2"
    if confirm "Terminate those stale Karpenter EC2 instances?"; then
      cmd "aws ec2 terminate-instances --instance-ids $STRAY_EC2"
      aws ec2 terminate-instances --region "$REGION" --instance-ids $STRAY_EC2 || true
    fi
  elif has_words "$STRAY_EC2"; then
    note "Karpenter EC2 instances exist, but NodeClaims also exist. Let Karpenter drain them; rerun c later."
  else
    ok "No stale Karpenter EC2 instances found."
  fi

  if [ "$touched_discovery" = "yes" ]; then
    force_karpenter_reconcile
  fi

  cmd "kubectl get nodeclaims"
  kubectl get nodeclaims
  ok "Cleanup pass finished. Run option d, then 0 and 1."
}

menu() {
  echo
  echo "${BOLD}══ Karpenter Live Demo (REAL EC2 — mind the meter 💰) ══${RESET}"
  echo "  d) Doctor: diagnose duplicate nodegroups / stale discovery / leftovers"
  echo "  c) Clean: guarded cleanup for those known stale states"
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
    d|D) step_d ;;
    c|C) step_c ;;
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
