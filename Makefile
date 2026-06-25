.PHONY: help deploy preflight ssh-key ssh-config create-utility create-vms configure-utility configure-ceph \
        boot-control-planes monitor-installation post-install configure-odf cleanup startup shutdown lint check \
        vault-edit vault-encrypt vault-decrypt \
        pull-secret-encrypt pull-secret-decrypt collections

VAULT_PASS_FILE ?= .vault-pass
ANSIBLE_OPTS ?=

ifdef INVENTORY
  INVENTORY_OPT := -i $(INVENTORY)
endif

ifdef CUSTOM_VARS
  EXTRA_VARS := -e @$(CUSTOM_VARS)
endif

ANSIBLE_CMD = ansible-playbook $(INVENTORY_OPT) \
              --vault-password-file $(VAULT_PASS_FILE) \
              $(EXTRA_VARS) $(ANSIBLE_OPTS)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

collections: ## Install required Ansible Galaxy collections
	ansible-galaxy collection install -r requirements.yml --force

deploy: ## Run the full deployment (all stages)
	$(ANSIBLE_CMD) playbooks/site.yml

ssh-key: ## Generate SSH key pair (run before creating cluster on console.redhat.com)
	$(ANSIBLE_CMD) playbooks/01-create-ssh-key.yml

preflight: ## Run pre-flight validation only (read-only)
	$(ANSIBLE_CMD) playbooks/preflight.yml

ssh-config: ## Add VM entries to ~/.ssh/config
	$(ANSIBLE_CMD) playbooks/04c-ssh-config.yml

create-utility: ## Create utility VM only
	$(ANSIBLE_CMD) playbooks/04a-create-utility.yml

create-vms: ## Create ceph and control-plane VMs
	$(ANSIBLE_CMD) playbooks/04b-create-remaining-vms.yml

configure-utility: ## Configure dnsmasq (DNS+DHCP) on utility VM
	$(ANSIBLE_CMD) playbooks/05-configure-utility.yml

configure-ceph: ## Bootstrap Ceph with 3 OSDs
	$(ANSIBLE_CMD) playbooks/06-configure-ceph.yml

boot-control-planes: ## Boot control-plane VMs from discovery ISO
	$(ANSIBLE_CMD) playbooks/07-boot-control-planes.yml

monitor-installation: ## Monitor Assisted Installer progress and wait for cluster ready
	$(ANSIBLE_CMD) playbooks/07b-monitor-installation.yml

post-install: ## Setup oc client and kubeconfig on utility VM
	$(ANSIBLE_CMD) playbooks/08-post-install.yml

configure-odf: ## Install ODF with external Ceph storage
	$(ANSIBLE_CMD) playbooks/09-configure-odf.yml

cleanup: ## Destroy all VMs and remove images
	$(ANSIBLE_CMD) playbooks/cleanup.yml

startup: ## Start all VMs in correct order
	$(ANSIBLE_CMD) playbooks/startup.yml

shutdown: ## Gracefully shut down all VMs
	$(ANSIBLE_CMD) playbooks/shutdown.yml

lint: ## Run ansible-lint and YAML syntax check
	ansible-lint playbooks/ roles/
	ansible-playbook playbooks/site.yml --syntax-check

check: ## Run deployment in check mode (dry run)
	$(ANSIBLE_CMD) playbooks/site.yml --check --diff

vault-edit: ## Edit the encrypted vault file
	ansible-vault edit inventory/group_vars/all/vault.yml \
	  --vault-password-file $(VAULT_PASS_FILE)

vault-encrypt: ## Encrypt the vault file
	ansible-vault encrypt inventory/group_vars/all/vault.yml \
	  --vault-password-file $(VAULT_PASS_FILE)

vault-decrypt: ## Decrypt the vault file (for manual editing)
	ansible-vault decrypt inventory/group_vars/all/vault.yml \
	  --vault-password-file $(VAULT_PASS_FILE)

pull-secret-encrypt: ## Encrypt the pull secret file
	ansible-vault encrypt files/pull-secret.txt \
	  --vault-password-file $(VAULT_PASS_FILE)

pull-secret-decrypt: ## Decrypt the pull secret file
	ansible-vault decrypt files/pull-secret.txt \
	  --vault-password-file $(VAULT_PASS_FILE)
