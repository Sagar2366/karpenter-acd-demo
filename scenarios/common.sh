#!/bin/bash
# Shared helpers — resolve cluster/region from terraform outputs (env vars win)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="$ROOT/terraform"

tf_out() { terraform -chdir="$TF" output -raw "$1" 2>/dev/null || true; }

export AWS_REGION="${AWS_REGION:-$(tf_out region)}";       export AWS_REGION="${AWS_REGION:-ap-south-1}"
export CLUSTER_NAME="${CLUSTER_NAME:-$(tf_out cluster_name)}"; export CLUSTER_NAME="${CLUSTER_NAME:-karpenter-acd-demo}"
export INSTANCE_PROFILE="${INSTANCE_PROFILE:-$(tf_out karpenter_instance_profile_name)}"
export CONTROLLER_ROLE="${CONTROLLER_ROLE:-$(tf_out karpenter_controller_role_name)}"
export CONTROLLER_ROLE_ARN="${CONTROLLER_ROLE_ARN:-$(tf_out karpenter_controller_role_arn)}"

BOLD=$(tput bold 2>/dev/null||true); RED=$(tput setaf 1 2>/dev/null||true)
GREEN=$(tput setaf 2 2>/dev/null||true); YELLOW=$(tput setaf 3 2>/dev/null||true)
CYAN=$(tput setaf 6 2>/dev/null||true); RESET=$(tput sgr0 2>/dev/null||true)
say()  { echo; echo "${BOLD}${CYAN}▶ $1${RESET}"; }
boom() { echo "${BOLD}${RED}💥 $1${RESET}"; }
heal() { echo "${BOLD}${GREEN}✅ $1${RESET}"; }
note() { echo "${YELLOW}$1${RESET}"; }
