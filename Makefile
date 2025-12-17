# Makefile for LiveKit EKS deployment

.PHONY: help prerequisites plan apply deploy destroy clean validate fmt output status

# Default environment and region
ENV ?= dev
REGION ?= us-east-1
AUTO_APPROVE ?= false

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m # No Color

help: ## Show this help message
	@echo "$(GREEN)LiveKit EKS Deployment Commands:$(NC)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "$(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Environment Variables:$(NC)"
	@echo "  ENV=$(ENV)           # Environment (dev/uat/prod)"
	@echo "  REGION=$(REGION)     # AWS Region"
	@echo "  AUTO_APPROVE=$(AUTO_APPROVE)  # Skip confirmation prompts"
	@echo ""
	@echo "$(GREEN)Examples:$(NC)"
	@echo "  make prerequisites              # Check and install tools"
	@echo "  make plan ENV=prod             # Plan for production"
	@echo "  make deploy AUTO_APPROVE=true  # Deploy without prompts"
	@echo "  make destroy ENV=uat           # Destroy UAT environment"

prerequisites: ## Check and install prerequisites
	@echo "$(GREEN)🔍 Checking prerequisites...$(NC)"
	@chmod +x scripts/*.sh
	@./scripts/00-prerequisites.sh

init: ## Initialize Terraform
	@echo "$(GREEN)🔧 Initializing Terraform...$(NC)"
	@cd resources && terraform init -upgrade

validate: ## Validate Terraform configuration
	@echo "$(GREEN)🔍 Validating Terraform configuration...$(NC)"
	@cd resources && terraform validate

fmt: ## Format Terraform files
	@echo "$(GREEN)📝 Formatting Terraform files...$(NC)"
	@cd resources && terraform fmt -recursive

plan: init validate ## Create Terraform plan
	@echo "$(GREEN)📋 Creating Terraform plan for $(ENV) environment...$(NC)"
	@cd resources && terraform plan -var-file="../environments/livekit-poc/$(REGION)/$(ENV)/inputs.tfvars" -out=tfplan

apply: ## Apply Terraform plan (requires manual approval)
	@echo "$(GREEN)🚀 Applying Terraform plan for $(ENV) environment...$(NC)"
ifeq ($(AUTO_APPROVE),true)
	@cd resources && terraform apply -auto-approve -var-file="../environments/livekit-poc/$(REGION)/$(ENV)/inputs.tfvars"
else
	@cd resources && terraform apply -var-file="../environments/livekit-poc/$(REGION)/$(ENV)/inputs.tfvars"
endif

deploy-infra: ## Deploy only infrastructure (Step 1)
	@echo "$(GREEN)🏗️  Deploying infrastructure...$(NC)"
	@chmod +x scripts/01-deploy-infrastructure.sh
ifeq ($(AUTO_APPROVE),true)
	@export TF_AUTO_APPROVE=true && ./scripts/01-deploy-infrastructure.sh
else
	@./scripts/01-deploy-infrastructure.sh
endif

deploy-lb: ## Deploy Load Balancer Controller (Step 2)
	@echo "$(GREEN)⚖️  Deploying Load Balancer Controller...$(NC)"
	@chmod +x scripts/02-setup-load-balancer.sh
	@./scripts/02-setup-load-balancer.sh

deploy-livekit: ## Deploy LiveKit (Step 3)
	@echo "$(GREEN)🎥 Deploying LiveKit...$(NC)"
	@chmod +x scripts/03-deploy-livekit.sh
	@./scripts/03-deploy-livekit.sh

deploy: deploy-infra deploy-lb deploy-livekit ## Deploy complete LiveKit stack
	@echo "$(GREEN)🎉 Complete deployment finished!$(NC)"

deploy-all: ## Deploy everything using the all-in-one script
	@echo "$(GREEN)🚀 Running complete deployment...$(NC)"
	@chmod +x scripts/deploy-all.sh
	@./scripts/deploy-all.sh

destroy: ## Destroy infrastructure
	@echo "$(RED)🗑️  Destroying infrastructure for $(ENV) environment...$(NC)"
	@echo "$(YELLOW)⚠️  WARNING: This will destroy all resources!$(NC)"
ifeq ($(AUTO_APPROVE),true)
	@cd resources && terraform destroy -auto-approve -var-file="../environments/livekit-poc/$(REGION)/$(ENV)/inputs.tfvars"
else
	@read -p "Are you sure you want to destroy all resources? Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ]
	@cd resources && terraform destroy -var-file="../environments/livekit-poc/$(REGION)/$(ENV)/inputs.tfvars"
endif

cleanup: ## Run cleanup script
	@echo "$(RED)🧹 Running cleanup script...$(NC)"
	@chmod +x scripts/cleanup.sh
	@./scripts/cleanup.sh

clean: ## Clean Terraform files
	@echo "$(YELLOW)🧹 Cleaning Terraform files...$(NC)"
	@cd resources && rm -rf .terraform terraform.tfstate* .terraform.lock.hcl tfplan

output: ## Show Terraform outputs
	@echo "$(GREEN)📊 Terraform outputs:$(NC)"
	@cd resources && terraform output

status: ## Show deployment status
	@echo "$(GREEN)📊 Deployment Status:$(NC)"
	@echo ""
	@echo "$(YELLOW)Infrastructure:$(NC)"
	@cd resources && terraform output cluster_name 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "$(YELLOW)Kubernetes Cluster:$(NC)"
	@kubectl get nodes 2>/dev/null || echo "  Not accessible"
	@echo ""
	@echo "$(YELLOW)LiveKit Pods:$(NC)"
	@kubectl get pods -n livekit 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "$(YELLOW)Load Balancer:$(NC)"
	@kubectl get ingress -n livekit 2>/dev/null || echo "  Not deployed"

logs: ## Show LiveKit logs
	@echo "$(GREEN)📋 LiveKit logs:$(NC)"
	@kubectl logs -n livekit -l app.kubernetes.io/name=livekit --tail=50

shell: ## Open shell in LiveKit pod
	@echo "$(GREEN)🐚 Opening shell in LiveKit pod...$(NC)"
	@kubectl exec -it -n livekit deployment/livekit -- /bin/sh

port-forward: ## Port forward LiveKit service for local access
	@echo "$(GREEN)🔗 Port forwarding LiveKit service to localhost:7880...$(NC)"
	@kubectl port-forward -n livekit svc/livekit 7880:80

test-redis: ## Test Redis connectivity
	@echo "$(GREEN)🔍 Testing Redis connectivity...$(NC)"
	@REDIS_ENDPOINT=$$(cd resources && terraform output -raw redis_cluster_endpoint 2>/dev/null) && \
	kubectl run redis-test --image=redis:alpine --rm -it -- redis-cli -h $$REDIS_ENDPOINT ping

scale: ## Scale LiveKit deployment (usage: make scale REPLICAS=3)
	@echo "$(GREEN)📈 Scaling LiveKit to $(REPLICAS) replicas...$(NC)"
	@kubectl scale deployment livekit -n livekit --replicas=$(REPLICAS)

update-livekit: ## Update LiveKit deployment with new values
	@echo "$(GREEN)🔄 Updating LiveKit deployment...$(NC)"
	@helm upgrade livekit livekit/livekit -f livekit-values-deployed.yaml -n livekit

# Development helpers
dev-setup: prerequisites deploy ## Complete development setup
	@echo "$(GREEN)🎉 Development environment ready!$(NC)"

prod-deploy: ## Deploy to production (requires confirmation)
	@echo "$(RED)⚠️  PRODUCTION DEPLOYMENT$(NC)"
	@read -p "Are you sure you want to deploy to production? Type 'PRODUCTION' to confirm: " confirm && [ "$$confirm" = "PRODUCTION" ]
	@$(MAKE) deploy ENV=prod

# Monitoring and debugging
debug: ## Show debug information
	@echo "$(GREEN)🔍 Debug Information:$(NC)"
	@echo ""
	@echo "$(YELLOW)Environment: $(ENV)$(NC)"
	@echo "$(YELLOW)Region: $(REGION)$(NC)"
	@echo "$(YELLOW)Auto Approve: $(AUTO_APPROVE)$(NC)"
	@echo ""
	@echo "$(YELLOW)AWS Identity:$(NC)"
	@aws sts get-caller-identity 2>/dev/null || echo "  Not configured"
	@echo ""
	@echo "$(YELLOW)Terraform State:$(NC)"
	@cd resources && terraform show -json 2>/dev/null | jq -r '.values.root_module.resources[].address' 2>/dev/null || echo "  No state found"

watch: ## Watch LiveKit pods
	@echo "$(GREEN)👀 Watching LiveKit pods...$(NC)"
	@kubectl get pods -n livekit -w

# CI/CD helpers
ci-deploy: prerequisites ## Deploy for CI/CD (auto-approve)
	@$(MAKE) deploy AUTO_APPROVE=true

ci-destroy: ## Destroy for CI/CD (auto-approve)
	@$(MAKE) destroy AUTO_APPROVE=true