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
         +-- ceph             (.252) -- cephadm single-node, 3 OSD, CephFS/MDS, RHEL 10
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

## RWX volumes via CephFS

The cluster gets three StorageClasses:

| StorageClass | Provisioner | Access modes | |
|---|---|---|---|
| `ocs-external-storagecluster-ceph-rbd` | RBD | RWO | **default** |
| `ocs-external-storagecluster-cephfs` | CephFS | RWO, **RWX** | |
| `openshift-storage.noobaa.io` | NooBaa | object (OBC) | |

CephFS is additive: it does not change the default class, and RBD and
NooBaa/OBC are untouched. Disable it with `enable_cephfs: false` in
extra-vars or `group_vars`, which skips the filesystem, the MDS and the
CephFS entries in the ODF external-cluster secret.

`make configure-ceph` creates two pools (`openshift-fs-metadata`,
`openshift-fs-data`, both on the `replicated_ssd` CRUSH rule), the
`openshift-fs` filesystem, one MDS daemon, the `csi` subvolume group and
the two CephFS CSI cephx users. `make configure-odf` then adds the
matching entries to `rook-ceph-external-cluster-details`, and ODF
derives the StorageClass and deploys the CephFS CSI driver from them.

Tune sizing via `ceph_cephfs` in `inventory/group_vars/all/main.yml`.
The defaults (32 PGs per pool) keep the three OSDs well under
`mon_max_pg_per_osd` alongside the existing 128-PG RBD pool, and match
`pg_num_min` so the autoscaler leaves them alone.

**Single-MDS trade-off.** One Ceph host means one MDS, so there is no
standby and `standby_count_wanted` is set to `0`. Without that the
cluster would sit permanently in `HEALTH_WARN`
(`MDS_INSUFFICIENT_STANDBY`), and `make shutdown` refuses to run unless
Ceph reports exactly `HEALTH_OK`. A second, colocated MDS would only
double MDS memory on a 16 GB VM without buying real redundancy.

To verify RWX end-to-end, set `odf_cephfs_smoke_test: true`: the odf role
provisions a `ReadWriteMany` PVC, waits for it to bind and deletes it
again. It is the only check that actually exercises the CSI caps and the
subvolume group.

## Valid SSL certificates (optional)

By default the cluster serves self-signed certificates. The optional
`letsencrypt` stage obtains a publicly trusted wildcard certificate for
`*.apps.<domain>` from Let's Encrypt using a DNS-01 challenge over
[DuckDNS](https://www.duckdns.org), and applies it to the default
IngressController.

**Requirements:**

- A publicly resolvable domain. DuckDNS provides one for free: set
  `base_domain: duckdns.org` and `cluster_name` to your DuckDNS subdomain
  (e.g. `ocp-lab` → `ocp-lab.duckdns.org`). The cluster **must be created on
  console.redhat.com with this same base domain** -- it is fixed at install
  time and cannot be changed by the certificate afterwards.
- `duckdns_token` in `vault.yml`, and `letsencrypt_email` set.

**Enable** it in your gitignored vars file (e.g. `inventory/lab-vars.yml`):

```yaml
base_domain: duckdns.org
enable_letsencrypt: true
letsencrypt_email: "you@example.com"
letsencrypt_staging: true   # validate the flow first; see below
```

Then run the stage (it only touches the utility VM, which already has `oc`
and a kubeconfig):

```bash
# 1. first run on the ACME staging endpoint (untrusted cert, no rate limits)
make configure-letsencrypt INVENTORY=inventory/hosts-mylab.yml CUSTOM_VARS=inventory/lab-vars.yml

# 2. set letsencrypt_staging: false, then re-run for a publicly trusted cert
make configure-letsencrypt INVENTORY=inventory/hosts-mylab.yml CUSTOM_VARS=inventory/lab-vars.yml
```

Staging and production certificates are stored in separate directories, so
switching to production issues a fresh trusted certificate rather than
re-applying the staging one.

**Renewal** is idempotent: re-running the target renews only when fewer than
`letsencrypt_remaining_days` (default 60) remain on the 90-day certificate --
otherwise it is a no-op. Renewal is manual, so schedule the target (e.g. a
weekly cron) if you want it hands-off.

## Additional container registries

Stage `10c` merges extra registry credentials into the cluster-wide pull
secret (`pull-secret` in namespace `openshift-config`) of an already
installed cluster. It is skipped unless `registry_auths` is defined.

The installation pull secret (`files/pull-secret.txt`) is **not** touched --
that file only feeds `cephadm`, and the cluster secret is authoritative once
the cluster is up.

Add the credentials to `vault.yml`:

```yaml
registry_auths:
  - registry: "quay.io/asalvati"
    username: "asalvati+ocp"
    password: "<robot token>"
    test_repository: "asalvati/myapp"   # optional, see verify-registries
  - registry: "registry.gitlab.com"
    username: "myuser"
    password: "<token>"
    email: "me@example.com"   # optional, omitted when unset
```

The `registry` key may be a host (`quay.io`) or a namespaced path
(`quay.io/asalvati`) -- CRI-O picks the most specific match, so a namespaced
entry lets you use a scoped robot account without granting cluster-wide
access to that host. Ansible builds the base64 `auth` value from
`username:password`; never paste a pre-encoded blob.

```bash
make vault-decrypt        # edit vault.yml, add registry_auths
make vault-encrypt
make configure-registries
```

The role is **additive and idempotent**: registries you do not list
(`registry.redhat.io`, `cloud.openshift.com`, ...) are preserved untouched, and
re-running with no changes reports nothing changed. For a registry you *do*
list the vault is authoritative -- its entry is replaced wholesale, so a
rotated password or a removed `email` takes effect. Removing an entry from
`registry_auths` does **not** remove it from the cluster -- delete it by hand
with `oc set data` (or `oc extract`/`oc set data`) if you need that.

The Machine Config Operator propagates the new secret to
`/var/lib/kubelet/config.json` on every node. Since OCP 4.7 this happens
**without draining or rebooting nodes**. Verify with:

```bash
oc get secret pull-secret -n openshift-config -o json \
  | jq -r '.data[".dockerconfigjson"]' | base64 -d | jq '.auths | keys'
```

### Troubleshooting image pulls

Start with the read-only checker -- it is the fastest way to separate "bad
credentials" from everything else:

```bash
make verify-registries
```

For every entry in `registry_auths` it reports whether the registry is present
in the cluster pull secret, whether that entry still matches the vault, and
whether the registry's own token endpoint accepts the username and password.
Add `test_repository` to an entry and it also asserts the account was granted
`pull` on that repository *and* can really read it. Passwords never appear in
the output.

`test_repository` is a bare repository name -- **no tag and no registry host**,
since the registry comes from `registry:` and the value ends up in the OAuth
scope `repository:<name>:pull`, where a tag is meaningless:

```yaml
test_repository: "asalvati/myapp"             # correct
test_repository: "asalvati/myapp:latest"      # rejected: INVALID_REQUEST
test_repository: "quay.io/asalvati/myapp"     # wrong: a different repository
```

The last one matters: quay hands out a `pull` scope even for repository names
that do not exist, so the scope alone would report success. That is why the
check also reads `tags/list` and requires HTTP 200.

If the credentials check out, read the CRI-O error on the pod carefully:

- `unauthorized: access to the requested resource is not authorized` --
  credentials or permissions.
- `manifest unknown` -- authentication was fine; the tag or digest does not
  exist in the registry.

**CRI-O tries every auth entry that matches the image**, so a namespaced entry
(`quay.io/asalvati`) and a host entry (`quay.io`) are both attempted and a
single failure message can contain *both* errors concatenated. Judge the error
that belongs to the most specific entry -- the broader entry failing with
`unauthorized` is expected and not the problem.

A `manifest unknown` shortly after a fresh push usually means an ImageStream is
still pinned to a digest the registry has since deleted. Deployments wired to
an ImageStream through an `image.openshift.io/triggers` annotation run a pinned
digest, not the tag, so they keep retrying the dead digest until the next
scheduled import. Compare and force the re-import:

```bash
oc get is <name> -n <ns> -o jsonpath='{.status.tags[*].items[0].image}{"\n"}'
oc import-image <name>:<tag> -n <ns> --confirm
```

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
| `make configure-ceph` | Bootstrap Ceph with 3 OSDs, plus the CephFS filesystem and MDS when `enable_cephfs` is set (default) |
| `make boot-control-planes` | Start control-planes from ISO (prompts for Assisted Installer setup) |
| `make monitor-installation` | Monitor Assisted Installer and wait for cluster ready |
| `make post-install` | Setup oc client and kubeconfig on utility VM |
| `make configure-odf` | Install ODF with external Ceph storage (adds the CephFS RWX StorageClass when `enable_cephfs` is set) |
| `make configure-htpasswd` | Configure HTPasswd identity provider with users |
| `make configure-letsencrypt` | Configure valid SSL certs via Let's Encrypt (optional; needs `enable_letsencrypt`) |
| `make configure-registries` | Add extra registries to the cluster pull secret (optional; needs `registry_auths`) |
| `make verify-registries` | Test the configured registry credentials against each registry (read-only) |
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
8. **06-configure-ceph** -- base config + bootstraps Ceph, adds 3 OSDs (SSD class), creates pool, and (unless `enable_cephfs` is false) the CephFS filesystem, MDS, `csi` subvolume group and CephFS CSI users
9. **07-boot-control-planes** -- prompts user to confirm Assisted Installer setup, inserts discovery ISO, boots control-plane VMs (skipped if API VIP already reachable)
10. **07b-monitor-installation** -- waits for API VIP, restarts shut-off VMs without ISO, monitors kubeconfig/clusterversion/cluster operators
11. **08-post-install** -- installs oc client, fetches kubeconfig on utility VM
12. **09-configure-odf** -- deploys ODF operator with external Ceph storage, enables odf-console plugin, and (unless `enable_cephfs` is false) adds the CephFS RWX StorageClass
13. **10-configure-htpasswd** -- configures HTPasswd identity provider (admin, reader, test01-03) with ClusterRoleBindings
14. **10b-configure-letsencrypt** -- *optional* (skipped unless `enable_letsencrypt`): obtains a valid wildcard cert for `*.apps.<domain>` via Let's Encrypt DNS-01 over DuckDNS and applies it to the default IngressController
15. **10c-configure-registries** -- *optional* (skipped unless `registry_auths` is set): merges extra registry credentials into the cluster-wide pull secret
16. **11-print-hosts** -- prints the `/etc/hosts` entries needed to reach the console and API (hypervisor public IP in NAT+port-forwarding mode, VIPs in bridge mode)

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
- `duckdns_token` -- *optional*, only for the Let's Encrypt stage ([duckdns.org](https://www.duckdns.org) token)
- `registry_auths` -- *optional*, extra registry credentials for the cluster pull secret (see below)

Never commit vault files or SSH keys.

## License

This project is licensed under the **GNU General Public License v3.0**.
See the [LICENSE](LICENSE) file for the full text.
