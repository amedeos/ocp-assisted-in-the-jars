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
- **Pull secret**: Downloaded from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) and saved to `files/pull-secret.txt`
- **Discovery ISO**: Generated from [Assisted Installer](https://console.redhat.com/openshift/assisted-installer/clusters) and saved to `/var/lib/libvirt/images/discovery-image.iso`
- **Ansible**: >= 2.15 with required collections (`make collections`)
- **Packages on hypervisor**: `qemu`, `libvirt`, `libguestfs-tools`, `virt-install`
- **RAM**: Minimum ~210GB for all VMs on a single host
- **Disk**: Minimum ~500GB in `/var/lib/libvirt/images`

## Quick start

```bash
# 1. Install Ansible collections
make collections

# 2. Set up secrets
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
# Edit vault.yml with your credentials, then encrypt:
make vault-encrypt

# 3. Place required files
cp /path/to/rhel-10.2-x86_64-kvm.qcow2 /root/images/
cp /path/to/pull-secret.txt files/
cp /path/to/discovery-image.iso /var/lib/libvirt/images/

# 4. Run pre-flight checks
make preflight

# 5. Deploy everything
make deploy
```

## Custom overrides (multi-hypervisor)

By default, all VMs are created on `localhost`. To distribute VMs across multiple hypervisors, create custom files and pass them at runtime:

```bash
make deploy INVENTORY=/path/to/my-inventory.yml CUSTOM_VARS=/path/to/my-vars.yml
```

Example custom inventory (`my-inventory.yml`):
```yaml
all:
  children:
    hypervisors:
      hosts:
        amelab01:
          ansible_host: 192.168.1.10
          ansible_user: root
          image_dir: /var/lib/libvirt/images
        amelab02:
          ansible_host: 192.168.1.11
          ansible_user: root
          image_dir: /var/lib/libvirt/imagesnvme
    utility:
      hosts:
        utility:
          ansible_host: 192.168.203.254
          ansible_user: root
          ansible_ssh_private_key_file: files/.ssh/id_rsa
          ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ceph:
      hosts:
        ceph:
          ansible_host: 192.168.203.252
          ansible_user: root
          ansible_ssh_private_key_file: files/.ssh/id_rsa
          ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
```

Example custom vars (`my-vars.yml`):
```yaml
cluster_nodes:
  - name: utility
    role: utility
    hypervisor: amelab01
    ip: 192.168.203.254
    ip_last_octet: 254
    mac: "52:54:00:00:33:FE"
  - name: ceph
    role: ceph
    hypervisor: amelab01
    ip: 192.168.203.252
    ip_last_octet: 252
    mac: "52:54:00:00:33:FC"
  - name: control-plane-0
    role: control-plane
    hypervisor: amelab01
    ip: 192.168.203.53
    ip_last_octet: 53
    mac: "52:54:00:00:33:00"
  - name: control-plane-1
    role: control-plane
    hypervisor: amelab02
    ip: 192.168.203.54
    ip_last_octet: 54
    mac: "52:54:00:00:33:01"
  - name: control-plane-2
    role: control-plane
    hypervisor: amelab02
    ip: 192.168.203.55
    ip_last_octet: 55
    mac: "52:54:00:00:33:02"
```

## Makefile targets

| Target | Description |
|---|---|
| `make deploy` | Full deployment |
| `make preflight` | Read-only pre-flight checks |
| `make create-vms` | Create VMs only |
| `make configure-utility` | Configure dnsmasq |
| `make configure-ceph` | Bootstrap Ceph |
| `make boot-control-planes` | Start control-planes from ISO |
| `make cleanup` | Destroy everything |
| `make startup` | Start all VMs |
| `make shutdown` | Graceful shutdown |
| `make lint` | Lint and syntax check |
| `make check` | Dry run |
| `make vault-edit` | Edit encrypted vault |

## Execution flow

1. **preflight** -- validates prerequisites (read-only)
2. **01-create-ssh-key** -- generates SSH key pair
3. **02-prepare-hypervisor** -- iptables NAT/DNAT, nested virt
4. **03-prepare-images** -- downloads and customizes RHEL 10 images
5. **04-create-vms** -- creates all VMs in libvirt
6. **05-configure-utility** -- installs and configures dnsmasq
7. **06-configure-ceph** -- bootstraps Ceph, adds 3 OSDs, creates pool
8. **07-boot-control-planes** -- starts control-plane VMs from discovery ISO

After step 8, continue the installation from [console.redhat.com](https://console.redhat.com/openshift/assisted-installer/clusters).

## Secrets

`vault.yml` is **gitignored** -- it never enters the repository. A template is provided:

```bash
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
# fill in your values, then encrypt:
make vault-encrypt
```

Variables in vault.yml:
- `secure_password` -- root password for utility and ceph VMs
- `rh_subscription_user` / `rh_subscription_password` -- Red Hat portal credentials
- `rh_subscription_pool` -- RHEL subscription pool ID

Never commit vault files, SSH keys, or pull-secret files.
