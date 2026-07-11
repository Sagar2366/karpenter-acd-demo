# ══════════════════════════════════════════════════════════════════
#  Karpenter ACD demo — one command per intention
#  💰 make up costs real money. make down when finished. Always.
# ══════════════════════════════════════════════════════════════════
.PHONY: up kube base demo flow b1 f1 b2 f2 b3 f3 b4 f4 reset down

up:            ## Create everything: VPC + EKS + Karpenter (~20 min)
	terraform -chdir=terraform init
	terraform -chdir=terraform apply -auto-approve
	$(MAKE) kube base

kube:          ## Point kubectl at the cluster
	aws eks update-kubeconfig \
	  --name  $$(terraform -chdir=terraform output -raw cluster_name) \
	  --region $$(terraform -chdir=terraform output -raw region)

base:          ## Apply NodePool + EC2NodeClass + inflate workload
	CLUSTER_NAME=$$(terraform -chdir=terraform output -raw cluster_name) \
	INSTANCE_PROFILE=$$(terraform -chdir=terraform output -raw karpenter_instance_profile_name) \
	  envsubst < k8s/base/karpenter-resources.yaml | kubectl apply -f -

demo:          ## Interactive driver menu
	./demo.sh

flow:          ## ONE talk-day flow: safety checks + happy path + all 4 breaks
	./demo.sh flow

b1:            ## 💥 Break #1: Pod Identity credentials
	./scenarios/break1-pod-identity/break.sh
f1:            ## ✅ Fix   #1
	./scenarios/break1-pod-identity/fix.sh

b2:            ## 💥 Break #2: runtime IAM write vs explicit deny
	./scenarios/break2-instance-profile/break.sh
f2:            ## ✅ Fix   #2
	./scenarios/break2-instance-profile/fix.sh

b3:            ## 💥 Break #3: discovery tags vanish
	./scenarios/break3-discovery-tags/break.sh
f3:            ## ✅ Fix   #3
	./scenarios/break3-discovery-tags/fix.sh

b4:            ## 💥 Break #4: the one-character toleration typo
	./scenarios/break4-toleration-typo/break.sh
f4:            ## ✅ Fix   #4
	./scenarios/break4-toleration-typo/fix.sh

reset:         ## Scale to zero, remove scenario leftovers
	-kubectl scale deploy/inflate --replicas=0
	-kubectl delete deploy workspace-typo --ignore-not-found
	-kubectl delete nodepool warm-pool --ignore-not-found
	kubectl get nodeclaims

down: reset    ## Destroy EVERYTHING (then eyeball the EC2 console)
	-kubectl delete nodepool default --ignore-not-found --timeout=120s
	terraform -chdir=terraform destroy -auto-approve
	@echo "🔎 Double-check: aws ec2 describe-instances --filters Name=tag:karpenter.sh/nodepool,Values=* Name=instance-state-name,Values=running"
