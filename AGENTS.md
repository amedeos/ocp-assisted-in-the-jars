# AGENTS.md

Guidance for Claude Code when working with this repository.

## Project overview

`ocp-assisted-in-the-jars` deploys a 3-node compact OpenShift cluster
using the Assisted Installer on KVM/libvirt VMs. The hypervisor runs
Gentoo Linux with nested virtualization. A separate Ceph VM provides
external storage for OpenShift Data Foundation (ODF).

VMs created:
- **utility** (RHEL 10) -- dnsmasq for DNS+DHCP
- **ceph** (RHEL 10) -- single-node Ceph via cephadm, 3 OSDs
- **control-plane-0/1/2** -- empty VMs with DVD/cdrom, boot from
  Assisted Installer discovery ISO, CPU host-passthrough for
  OpenShift Virtualization

## Commands

```bash
ansible-galaxy collection install -r requirements.yml  # install deps
make deploy                                            # full deployment
make preflight                                         # read-only checks
make lint                                              # ansible-lint
make check                                             # dry run
make cleanup                                           # destroy everything
make deploy CUSTOM_VARS=/path/to/vars.yml              # custom overrides
make deploy INVENTORY=/path/to/hosts.yml               # custom inventory
```

## Architecture

### Directory layout

- `playbooks/` -- `site.yml` imports numbered stage playbooks (01-07).
  Each stage playbook calls one or more roles.
- `roles/` -- Reusable units. Each owns defaults, tasks, handlers,
  templates.
- `inventory/` -- YAML inventory with `group_vars/all/`. Default
  hypervisor is `localhost` (no SSH needed). Multi-hypervisor via
  custom inventory override.

### Execution flow

1. **preflight** -- read-only validation (bridge, KVM, disk, RAM)
2. **01** -- generate SSH key pair
3. **02** -- configure hypervisor (iptables NAT/DNAT, nested virt)
4. **03** -- download and customize RHEL 10 golden images
5. **04** -- create libvirt VMs (utility, ceph, 3 control-planes)
6. **05** -- configure dnsmasq on utility VM
7. **06** -- bootstrap single-node Ceph with 3 OSDs
8. **07** -- boot control-planes from discovery ISO

### Node definitions

All VMs defined in `inventory/group_vars/all/main.yml` under
`cluster_nodes`. Each entry: name, role, hypervisor, ip, mac.
The `hypervisor` field controls which physical host creates the VM
(`localhost` by default, override via custom vars).

### Secrets

`inventory/group_vars/all/vault.yml` is **gitignored** and never
committed. A `.example` template is provided in the repo. The user
copies it, fills in credentials, and encrypts with ansible-vault.
Never commit: SSH keys, pull-secret, vault password files, CephX
credentials.

## Ansible conventions

- **`loop:` not `with_items:`** -- with_items is deprecated
- **FQCN** -- `ansible.builtin.` prefix on all modules
- **Handlers** for service restarts via `notify:`
- **`changed_when:` and `failed_when:`** on every `command:`/`shell:`
- **`no_log: true`** on tasks handling passwords or secrets
- **`block:/rescue:/always:`** for error handling
- **Two-space indentation**, files start with `---`
- **Templates** live inside their owning role under `templates/`

## Rules

1. **Never commit secrets.** No vault passwords, SSH private keys,
   pull-secret files, or cleartext credentials.
2. **Never use `with_items:`.** Always use `loop:`.
3. **Never use bare `shell:` or `command:` without `changed_when:`.**
4. **Never modify vault.yml without encrypting it.**
5. **Never restart services inline** -- use handlers with `notify:`.
6. **Never hardcode IPs** -- use variables from `cluster_nodes` or
   `baremetal_net`.
