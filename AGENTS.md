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
make prepare-network                                   # one-time network setup on hypervisor
make deploy                                            # full deployment (never modifies hypervisor)
make preflight                                         # read-only checks
make lint                                              # ansible-lint
make check                                             # dry run
make cleanup                                           # destroy VMs only
make cleanup-network                                   # destroy hypervisor network
make deploy INVENTORY=/path/to/hosts.yml \
            CUSTOM_VARS=/path/to/vars.yml              # multi-hypervisor (both required)
```

## Architecture

### Directory layout

- `playbooks/` -- `site.yml` imports numbered stage playbooks (01-07).
  Each stage playbook calls one or more roles.
- `roles/` -- Reusable units. Each owns defaults, tasks, handlers,
  templates.
- `inventory/` -- YAML inventory with `group_vars/all/`. Default
  hypervisor is `localhost` (no SSH needed). Multi-hypervisor via
  custom inventory override. `.example` templates provided:
  - `hosts-multi.yml.example` -- hypervisors and VM placement
  - `lab-vars.yml.example` -- VM resource overrides (CPU, RAM, disk)

### Execution flow

`make deploy` **never modifies the hypervisor**. Network and
hypervisor preparation are one-time prerequisites the user runs
explicitly via `make prepare-network`.

1. **preflight** -- read-only validation (network, KVM, disk, RAM)
2. **01** -- generate SSH key pair
3. **03** -- download and customize RHEL 10 golden images
4. **04** -- create libvirt VMs (utility, ceph, 3 control-planes)
5. **05** -- configure dnsmasq on utility VM
6. **06** -- bootstrap single-node Ceph with 3 OSDs
7. **07** -- boot control-planes from discovery ISO
8. **08** -- post-install (oc client, kubeconfig)
9. **09** -- configure ODF with external Ceph
10. **10** -- configure HTPasswd identity provider

### Network modes

Controlled by `network_mode` in `group_vars/all/main.yml`:

- **`nat`** (default) -- Ansible creates a libvirt NAT network
  (`make prepare-network`). No manual bridge needed. Best for
  single-host localhost deployments.
- **`bridge`** -- user provides a pre-existing bridge (`bridge_bm`).
  Required for multi-hypervisor setups where VMs must share an
  L2 domain.

DNAT port forwarding (443/6443) is configured by
`make prepare-network` in both modes when `enable_portfw` is true.

### ODF channel auto-detection

The ODF operator channel is derived at runtime from the cluster
version (e.g., OCP 4.22.1 → `stable-4.22`). The OCP version is
chosen on console.redhat.com, not in Ansible variables.

To override (e.g., ODF 4.22 not yet released), set
`odf_channel_override: "stable-4.21"` in extra-vars or group_vars.

### Node definitions

All VMs defined in `inventory/group_vars/all/main.yml` under
`cluster_nodes`. Each entry: name, role, hypervisor, ip, mac.
The `hypervisor` field controls which physical host creates the VM
(`localhost` by default, override via custom vars).

### Customising a multi-hypervisor deployment

Two files are needed, both gitignored:

1. **Custom inventory** (`inventory/hosts-*.yml`) -- defines the
   hypervisor hosts (SSH connection, `image_dir`, `bridge_bm`).
2. **Extra-vars file** (`inventory/*-vars.yml`) -- overrides
   `cluster_nodes` (VM placement) and `vm_specs` (CPU, RAM, disk).
   This must be a separate file passed via `CUSTOM_VARS` because
   Ansible gives `-e @file` the highest variable precedence, which
   is needed to override `group_vars/all/main.yml`.

`.example` templates for both files are provided in `inventory/`.

### Hypervisor preparation

The `hypervisor` role (playbook `02-prepare-hypervisor.yml`, run via
`make prepare-hypervisor`) is a one-time prerequisite run explicitly
by the user against the `hypervisors` group. It is **not** part of
`make deploy` (which never touches the hypervisor) -- the
`prepare-hypervisor` target is standalone and is never a dependency of
`deploy`. It configures nested virtualization, iptables
NAT/port-forwarding, and installs the base virtualization packages
(`hypervisor_base_packages`, overridable per host via
`hypervisor.base_packages`).

OS handling is keyed off Ansible facts:

- **RHEL** (`ansible_distribution == "RedHat"`) -- registers the
  system with `subscription-manager` first, reusing
  `rh_activation_key` / `rh_org_id` from the vault, then installs
  packages via `dnf`.
- **CentOS Stream** (`ansible_distribution == "CentOS"`) -- the
  subscription step is **skipped** (no entitlement required);
  packages are installed via `dnf`.
- **Gentoo** (the default reference hypervisor) -- both steps are
  skipped; package management is left to the user.

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
7. **Run `make lint` after every change** to playbooks or roles.
   It must pass with zero errors before committing. CI enforces
   this via GitHub Actions (ansible-lint + yamllint + syntax-check).
8. **`make deploy` must never modify the hypervisor.** Network
   setup and hypervisor configuration are one-time prerequisites
   run explicitly by the user (`make prepare-network`). The deploy
   pipeline only validates (preflight) and creates/configures VMs.
