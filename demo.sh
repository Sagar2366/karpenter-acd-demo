#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  ACD Delhi — Karpenter LIVE DEMO DRIVER (real EKS!)
#  Usage: ./demo.sh          (interactive menu)
#         ./demo.sh 2        (run one step and exit)
#         ./demo.sh flow     (one talk-day flow)
#
#  Each step prints WHAT we're doing, the COMMAND, then the OUTPUT.
#  Prereq: ./setup-eks-demo.sh done, kubectl context on the EKS cluster.
# ══════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

pause_for_speaker() {
  [ "${DEMO_AUTO:-}" = "1" ] && return 0
  echo
  printf "${DIM}(Enter for next beat)${RESET}"
  read -r _
}

run_scenario_script() {
  local title="$1" rel="$2"
  say "$title"
  cmd "$rel"
  if ! bash "$SCRIPT_DIR/$rel"; then
    note "Step failed: $rel"
    return 1
  fi
}

wait_for_no_nodeclaims() {
  local tries="${1:-24}" claims i
  note "Waiting for demo NodeClaims to disappear..."
  for i in $(seq 1 "$tries"); do
    claims=$(kubectl get nodeclaims -o name 2>/dev/null || true)
    if ! has_words "$claims"; then
      ok "NodeClaims: none"
      return 0
    fi
    sleep 10
  done
  note "NodeClaims are still present; keep option 3 on screen and let Karpenter finish."
  kubectl get nodeclaims 2>/dev/null || true
}

flow_run() {
  "$@" || return $?
  pause_for_speaker
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
  run_scenario_script "BREAK #3: discovery tags vanish" "scenarios/break3-discovery-tags/break.sh"
}

step_b3fix() {
  run_scenario_script "FIX #3: restore discovery tags" "scenarios/break3-discovery-tags/fix.sh"
}

step_b1() {
  run_scenario_script "BREAK #1: Pod Identity association disappears" "scenarios/break1-pod-identity/break.sh"
}

step_f1() {
  run_scenario_script "FIX #1: recreate Pod Identity association" "scenarios/break1-pod-identity/fix.sh"
}

step_b2() {
  run_scenario_script "BREAK #2: explicit deny blocks runtime IAM writes" "scenarios/break2-instance-profile/break.sh"
}

step_f2() {
  run_scenario_script "FIX #2: use pre-created instance profile" "scenarios/break2-instance-profile/fix.sh"
}

step_b4() {
  run_scenario_script "BREAK #4: the one-character toleration typo" "scenarios/break4-toleration-typo/break.sh"
}

step_b4fix() {
  run_scenario_script "FIX #4: add the missing s" "scenarios/break4-toleration-typo/fix.sh"
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

flow_reset() {
  step_r
  wait_for_no_nodeclaims 18
}

step_flow() {
  say "ONE TALK FLOW: safety check → happy path → all 4 breaks → clean baseline"
  note "This is the only flow to remember on stage. Individual b/f options are for rehearsal or recovery."
  note "It pauses between beats so you can talk, read the output, and then press Enter."
  echo
  if [ "${DEMO_CONFIRM_FLOW:-}" != "yes" ] && ! confirm "Run the full live flow now?"; then
    note "Flow cancelled."
    return 0
  fi

  say "ACT 0: prove the cluster is healthy before we break it"
  flow_run step_d || return $?
  flow_run step_c || return $?
  flow_run flow_reset || return $?
  flow_run step_0 || return $?
  flow_run step_1 || return $?

  say "ACT 1: the happy path, because the audience needs to see why Karpenter is worth it"
  flow_run step_2 || return $?
  flow_run step_3 || return $?
  flow_run step_3 || return $?
  flow_run step_4 || return $?
  flow_run step_5 || return $?
  flow_run step_6 || return $?
  flow_run step_7 || return $?
  flow_run step_8 || return $?
  flow_run wait_for_no_nodeclaims 24 || return $?

  say "ACT 2: four production breaks, one by one"
  flow_run step_b1 || return $?
  flow_run step_f1 || return $?
  flow_run flow_reset || return $?

  flow_run step_b2 || return $?
  flow_run step_f2 || return $?
  flow_run flow_reset || return $?

  flow_run step_b3 || return $?
  flow_run step_b3fix || return $?
  flow_run flow_reset || return $?

  flow_run step_b4 || return $?
  flow_run step_b4fix || return $?
  flow_run flow_reset || return $?

  say "FINAL: leave the cluster boring"
  step_d
  ok "Flow complete. If this was the real talk, run make down after you step off stage."
}

menu() {
  echo
  echo "${BOLD}══ Karpenter Live Demo (REAL EC2 — mind the meter 💰) ══${RESET}"
  echo "  flow) ONE talk flow: happy path + all 4 breaks + cleanup"
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
  echo "  b1/f1) Pod Identity       b2/f2) Instance profile IAM"
  echo "  b3/f3) Discovery tags     b4/f4) Toleration typo"
  echo "  r) Reset between rehearsals"
  echo "  q) Quit"
  echo
}

run_step() {
  case "$1" in
    flow|all|story) step_flow ;;
    d|D) step_d ;;
    c|C) step_c ;;
    0|1|2|3|4|5|6|7|8) "step_$1" ;;
    b1) step_b1 ;; f1|b1fix) step_f1 ;;
    b2) step_b2 ;; f2|b2fix) step_f2 ;;
    b3) step_b3 ;; f3|b3fix) step_b3fix ;;
    b4) step_b4 ;; f4|b4fix) step_b4fix ;;
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
