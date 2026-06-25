# ocp-assisted-in-the-jars

Deploy a 3-node compact OpenShift cluster using the **Assisted Installer** on KVM/libvirt VMs with nested virtualization.

## Architecture

```
[Hypervisor(s) - Gentoo Linux, KVM, nested virt]
   |
   +-- bridge: bm (192.168.203.0/24)
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
| control-plane-0/1/2 | 16 | 64 GB | 120G | DVD/cdrom | host-passthrough | ISO |

Control-plane VMs use `host-passthrough` CPU mode for OpenShift Virtualization support.

## Prerequisites

- **Hypervisor**: Gentoo Linux (or any Linux with KVM) with nested virtualization enabled
- **Bridge**: Network bridge `bm` must be created manually on the hypervisor
- **RHEL image**: `rhel-10.2-x86_64-kvm.qcow2` downloaded from access.redhat.com
- **Pull secret**: Downloaded from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) and saved to `files/pull-secret.txt` (used by cephadm to pull container images from `registry.redhat.io`)
- **Discovery ISO**: Generated from [Assisted Installer](https://console.redhat.com/openshift/assisted-installer/clusters) -- the playbook prompts for it at stage 07 (not needed upfront)
- **Ansible**: >= 2.15 with required collections (`make collections`)
- **Packages on hypervisor**: `qemu`, `libvirt`, `libguestfs-tools`, `virt-install`
- **RAM**: Minimum ~210GB for all VMs on a single host
- **Disk**: Minimum ~500GB in `/var/lib/libvirt/images`

## Quick start

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

# 6. Create custom inventory and vars (multi-hypervisor)
cp inventory/hosts-multi.yml.example inventory/hosts-mylab.yml
cp inventory/lab-vars.yml.example inventory/lab-vars.yml
# Edit both files with your lab values

# 7. Run pre-flight checks
make preflight INVENTORY=inventory/hosts-mylab.yml CUSTOM_VARS=inventory/lab-vars.yml

# 8. Deploy everything
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
| `make deploy` | Full deployment |
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
| `make cleanup` | Destroy everything and remove SSH config |
| `make startup` | Start all VMs (utility → ceph → control-planes, with health checks) |
| `make shutdown` | Graceful shutdown (oc debug shutdown → wait → ceph → utility) |
| `make lint` | Lint and syntax check |
| `make check` | Dry run |
| `make vault-edit` | Edit encrypted vault |
| `make pull-secret-encrypt` | Encrypt pull secret |
| `make pull-secret-decrypt` | Decrypt pull secret |

## Execution flow

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

Never commit vault files or SSH keys.
