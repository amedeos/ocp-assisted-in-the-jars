# ocp-assisted-in-the-jars

[![Lint](https://github.com/amedeos/ocp-assisted-in-the-jars/actions/workflows/lint.yml/badge.svg)](https://github.com/amedeos/ocp-assisted-in-the-jars/actions/workflows/lint.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Built with Ansible](https://img.shields.io/badge/Built%20with-Ansible-1A1918?logo=ansible&logoColor=white)](https://www.ansible.com/)
[![ansible-lint](https://img.shields.io/badge/ansible--lint-production-success.svg)](.ansible-lint)
[![OpenShift](https://img.shields.io/badge/OpenShift-compact%203--node-EE0000?logo=redhatopenshift&logoColor=white)](https://console.redhat.com/openshift/assisted-installer/clusters)

Deploy a 3-node compact OpenShift cluster using the **Assisted Installer** on KVM/libvirt VMs with nested virtualization.

## Architecture

```
[Hypervisor(s) - Gentoo Linux, KVM, nested virt]
   |
   +-- network: 192.168.203.0/24
   |   (NAT mode: libvirt-managed network, default)
   |   (Bridge mode: manual bridge for multi-hypervisor)
         |
         +-- utility         (.254) -- dnsmasq (DNS+DHCP), RHEL 10
         +-- ceph             (.252) -- cephadm single-node, 3 OSD, RHEL 10
         +-- control-plane-0  (.53)  -- empty VM, boot from discovery ISO
         +-- control-plane-1  (.54)  -- empty VM, boot from discovery ISO
         +-- control-plane-2  (.55)  -- empty VM, boot from discovery ISO
         |
         +-- API VIP          (.80)  -- managed by OpenShift
         +-- Ingress VIP      (.81)  -- managed by OpenShift
```

### VMs

| VM | vCPU | RAM | OS Disk | Extra | CPU Mode | Boot |
|---|---|---|---|---|---|---|
| utility | 2 | 4 GB | 50G | - | host-model | qcow2 |
| ceph | 4 | 16 GB | 50G | 3x 200G OSD | host-model | qcow2 |
| control-plane-0/1/2 | 16 | 32 GB | 120G | DVD/cdrom | host-passthrough | ISO |

Control-plane VMs use `host-passthrough` CPU mode for OpenShift Virtualization support.

## Prerequisites

> **`make deploy` never touches the hypervisor.** Hypervisor and network
> preparation are one-time prerequisites that **you** run explicitly and
> consciously (`make prepare-hypervisor`, `make prepare-network`). The deploy
> pipeline only validates (preflight) and creates/configures VMs -- it will
> never enable nested virtualization, change iptables, or create the network
> on its own.

- **Hypervisor**: Gentoo Linux (or any Linux with KVM) with nested
  virtualization enabled. On RHEL/CentOS Stream you can automate this with
  `make prepare-hypervisor`, which configures nested virt, iptables
  NAT/port-forwarding, and installs the base virtualization packages. On Gentoo
  (the reference hypervisor) package management is left to you -- install the
  packages below manually.
- **Network**: Run `make prepare-network` before the first deploy. It creates
  the libvirt NAT network (default) and the DNAT port-forwarding rules, or set
  `network_mode: bridge` to use a pre-existing manual bridge instead.
- **RHEL image**: `rhel-10.2-x86_64-kvm.qcow2` downloaded from access.redhat.com, placed at `/root/images/` on each hypervisor (path set by `image_location`)
- **Pull secret**: Downloaded from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) and saved to `files/pull-secret.txt` (used by cephadm to pull container images from `registry.redhat.io`)
- **Discovery ISO**: Generated from [Assisted Installer](https://console.redhat.com/openshift/assisted-installer/clusters) -- the playbook prompts for it at stage 07 (not needed upfront). It is placed at `{{ image_dir }}/discovery-image.iso` (default `/var/lib/libvirt/images/discovery-image.iso`)
- **Ansible**: >= 2.15 with required collections (`make collections`)
- **Packages on hypervisor**: `qemu`, `libvirt`, `guestfs-tools` (provides `virt-resize`/`virt-customize`), `virt-install` (installed automatically by `make prepare-hypervisor` on RHEL/CentOS)
- **Memory**: Minimum ~120GB (RAM + swap) for all VMs on a single host
- **Disk**: Minimum ~500GB in `/var/lib/libvirt/images`

## Quick start

### Common setup (both single-host and multi-hypervisor)

```bash
# 1. Install Ansible collections
make collections

# 2. Generate SSH key pair (needed for Assisted Installer cluster setup)
make ssh-key
cat files/.ssh/id_rsa.pub   # copy this to console.redhat.com

# 3. Set up secrets
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
# Edit vault.yml with your credentials (activation key, org id, password)
make vault-encrypt

# 4. Pull secret (for Ceph container images)
cp /path/to/pull-secret.txt files/pull-secret.txt
make pull-secret-encrypt

# 5. Place RHEL 10 image on each hypervisor
#    /root/images/rhel-10.2-x86_64-kvm.qcow2
#    (Discovery ISO is downloaded later, before stage 07)

# 6. One-time hypervisor + network prep (run consciously -- never done by deploy)
make prepare-hypervisor   # RHEL/CentOS only; on Gentoo prepare the host manually
make prepare-network      # creates libvirt NAT network + port-forwarding
```

### Single host (default -- all VMs on localhost)

No custom inventory or vars are needed: the defaults in
`inventory/group_vars/all/main.yml` place every VM on `localhost`.

```bash
# 7. Run pre-flight checks, then deploy
make preflight
make deploy
```

### Multi-hypervisor (VMs distributed across hosts)

```bash
# 7. Create custom inventory and vars
cp inventory/hosts-multi.yml.example inventory/hosts-mylab.yml
cp inventory/lab-vars.yml.example inventory/lab-vars.yml
# Edit both files with your lab values

# 8. Run pre-flight checks
make preflight INVENTORY=inventory/hosts-mylab.yml CUSTOM_VARS=inventory/lab-vars.yml

# 9. Deploy everything
make deploy INVENTORY=inventory/hosts-mylab.yml CUSTOM_VARS=inventory/lab-vars.yml
```

## Custom overrides (multi-hypervisor)

By default, all VMs are created on `localhost`. To distribute VMs across multiple hypervisors you need two files:

| File | What it controls | Why separate |
|---|---|---|
| **Custom inventory** (`hosts-*.yml`) | Hypervisor connection details (`bridge_bm`, `image_dir`) | Defines *who connects where* |
| **Extra-vars file** (`*-vars.yml`) | VM placement (`cluster_nodes`) and resources (`vm_specs`) | Needs `-e @file` to override `group_vars/all/main.yml` (highest Ansible precedence) |

Both are gitignored. Templates are provided in `inventory/`:

```bash
# 1. Create your files from examples
cp inventory/hosts-multi.yml.example inventory/hosts-mylab.yml
cp inventory/lab-vars.yml.example inventory/lab-vars.yml

# 2. Edit with your hostnames, bridge names, IPs, MACs, VM resources
vi inventory/hosts-mylab.yml inventory/lab-vars.yml

# 3. Deploy
make deploy INVENTORY=inventory/hosts-mylab.yml CUSTOM_VARS=inventory/lab-vars.yml
```

### Network modes

Controlled by `network_mode` in `inventory/group_vars/all/main.yml`:

| Mode | Default | Network setup | Use case |
|---|---|---|---|
| `nat` | **yes** | `make prepare-network` creates a libvirt NAT network | Single-host localhost deployments |
| `bridge` | no | User creates bridge manually | Multi-hypervisor (VMs share L2 domain) |

In NAT mode, DHCP is **not** provided by the libvirt network -- the utility VM runs dnsmasq for DNS and DHCP. DNAT port forwarding (443 and 6443) is configured automatically by `make prepare-network` to expose API and Ingress VIPs.

To switch to bridge mode, set `network_mode: bridge` and ensure `bridge_bm` is configured in your inventory.

### Per-hypervisor settings

Each hypervisor can have its own `bridge_bm` and `image_dir`:

```yaml
hypervisors:
  hosts:
    host01:
      bridge_bm: br-2003       # libvirt bridge name on this host
      image_dir: /var/lib/libvirt/images
    host02:
      bridge_bm: virbr-ocp     # different bridge on this host
      image_dir: /data/libvirt/images
```

### VM resource overrides

To change CPU, RAM, or disk for a VM role, set `vm_specs` in the extra-vars file:

```yaml
vm_specs:
  controlplane:
    cpu: 8
    memory_mb: 32768
    os_disk_gb: 120
```

Only include the roles you want to override; defaults for the rest come from `inventory/group_vars/all/main.yml`.

## Makefile targets

| Target | Description |
|---|---|
| `make help` | List all targets with their descriptions |
| `make collections` | Install required Ansible Galaxy collections |
| `make prepare-hypervisor` | Configure nested virt, iptables, base packages (one-time, RHEL/CentOS; **never run by deploy**) |
| `make prepare-network` | Create network on hypervisor (one-time, run before first deploy; **never run by deploy**) |
| `make deploy` | Full deployment (never modifies hypervisor) |
| `make preflight` | Read-only pre-flight checks |
| `make ssh-key` | Generate SSH key pair |
| `make ssh-config` | Add VM entries to ~/.ssh/config |
| `make create-utility` | Create utility VM only |
| `make create-vms` | Create ceph and control-plane VMs |
| `make configure-utility` | Configure dnsmasq (DNS+DHCP) |
| `make configure-ceph` | Bootstrap Ceph with 3 OSDs |
| `make boot-control-planes` | Start control-planes from ISO (prompts for Assisted Installer setup) |
| `make monitor-installation` | Monitor Assisted Installer and wait for cluster ready |
| `make post-install` | Setup oc client and kubeconfig on utility VM |
| `make configure-odf` | Install ODF with external Ceph storage |
| `make configure-htpasswd` | Configure HTPasswd identity provider with users |
| `make print-hosts` | Print /etc/hosts entries for console and API access |
| `make cleanup` | Destroy and undefine all VMs (incl. storage and OSD disks), remove golden images + discovery ISO (`cleanup_remove_images: true`), and clean up the generated SSH key pair and `~/.ssh/config` entries |
| `make cleanup-network` | Destroy hypervisor network (libvirt NAT mode only) |
| `make startup` | Start all VMs (utility → ceph → control-planes, with health checks) |
| `make shutdown` | Graceful shutdown (oc debug shutdown → wait → ceph → utility) |
| `make lint` | Lint and syntax check |
| `make check` | Dry run |
| `make vault-edit` | Edit encrypted vault |
| `make vault-encrypt` | Encrypt the vault file |
| `make vault-decrypt` | Decrypt the vault file (for manual editing) |
| `make pull-secret-encrypt` | Encrypt pull secret |
| `make pull-secret-decrypt` | Decrypt pull secret |

## Execution flow

0. **prepare-network** -- one-time hypervisor network setup (`make prepare-network`, not part of deploy)
1. **preflight** -- validates prerequisites (read-only)
2. **01-create-ssh-key** -- generates ed25519 SSH key pair
3. **03-prepare-images** -- customizes RHEL 10 golden images (utility, ceph)
4. **04a-create-utility** -- creates utility VM with virt-install
5. **04c-ssh-config** -- adds VM entries to ~/.ssh/config
6. **05-configure-utility** -- base config (subscription, hostname, updates) + dnsmasq
7. **04b-create-remaining-vms** -- creates ceph and control-plane VMs (empty cdrom, no ISO)
8. **06-configure-ceph** -- base config + bootstraps Ceph, adds 3 OSDs (SSD class), creates pool
9. **07-boot-control-planes** -- prompts user to confirm Assisted Installer setup, inserts discovery ISO, boots control-plane VMs (skipped if API VIP already reachable)
10. **07b-monitor-installation** -- waits for API VIP, restarts shut-off VMs without ISO, monitors kubeconfig/clusterversion/cluster operators
11. **08-post-install** -- installs oc client, fetches kubeconfig on utility VM
12. **09-configure-odf** -- deploys ODF operator with external Ceph storage, enables odf-console plugin
13. **10-configure-htpasswd** -- configures HTPasswd identity provider (admin, reader, test01-03) with ClusterRoleBindings
14. **11-print-hosts** -- prints the `/etc/hosts` entries needed to reach the console and API (hypervisor public IP in NAT+port-forwarding mode, VIPs in bridge mode)

## Secrets

`vault.yml` is **gitignored** -- it never enters the repository. A template is provided:

```bash
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
# fill in your values, then encrypt:
make vault-encrypt
```

Variables in vault.yml:
- `secure_password` -- root password for utility and ceph VMs
- `rh_activation_key` -- Red Hat activation key ([registration](https://console.redhat.com/insights/registration), [manage keys](https://console.redhat.com/insights/connector/activation-keys))
- `rh_org_id` -- Red Hat organization ID
- `htpasswd_admin_password` -- password for HTPasswd users (generate with `openssl rand -hex 30`)

Never commit vault files or SSH keys.

## License

This project is licensed under the **GNU General Public License v3.0**.
See the [LICENSE](LICENSE) file for the full text.
