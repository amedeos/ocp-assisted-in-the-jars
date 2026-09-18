# AGENTS.md

Guidance for Claude Code when working with this repository.

## Project overview

`ocp-assisted-in-the-jars` deploys a 3-node compact OpenShift cluster
using the Assisted Installer on KVM/libvirt VMs. The hypervisor runs
Gentoo Linux with nested virtualization. A separate Ceph VM provides
external storage for OpenShift Data Foundation (ODF).

VMs created:
- **utility** (RHEL 10) -- dnsmasq for DNS+DHCP
- **ceph** (RHEL 10) -- single-node Ceph via cephadm, 3 OSDs, plus a
  CephFS filesystem and one MDS when `enable_cephfs` is set (default)
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
6. **06** -- bootstrap single-node Ceph with 3 OSDs (plus CephFS and
   the MDS unless `enable_cephfs` is false)
7. **07** -- boot control-planes from discovery ISO
8. **08** -- post-install (oc client, kubeconfig)
9. **09** -- configure ODF with external Ceph (plus the CephFS RWX
   StorageClass unless `enable_cephfs` is false), ending on a NooBaa
   readiness gate that proves RBD provisioning works
10. **10** -- configure HTPasswd identity provider
11. **10b** -- configure valid SSL certs via Let's Encrypt
    (DNS-01 over DuckDNS); skipped unless `enable_letsencrypt`
12. **10c** -- merge extra registry credentials into the cluster
    pull secret; skipped unless `registry_auths` is set
13. **11** -- print /etc/hosts entries for console/API access

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

### Ceph client / cephx cipher skew

`cephadm` bootstraps from the mutable tag
`registry.redhat.io/rhceph/rhceph-9-rhel9:latest`, which moves ahead of
both the RHEL 10 `ceph-common` RPM and the Ceph client bundled in ODF.
Since the 2026-07-20 image rebuild the cluster issues AES-256 cephx
keys that those older clients cannot parse (`Malformed input`). Older
ODF is worse, not better: 4.18 ships ceph-csi 19.2.1 and 4.16 is older
still, so no version this repo targets reads AES-256. Two consequences,
both handled in the `ceph` role:

- Cluster commands run as `{{ ceph_cmd }}` (`cephadm shell -- ceph`),
  never the host `ceph` binary. See `ceph_cmd` in `group_vars`.
- `cephx_compat.yml` allows the AES-128 cipher in the monmap
  (`auth_allowed_ciphers`) *and makes it the default for every newly
  minted key* (`auth_preferred_cipher`). Toggle with
  `ceph_cephx_aes128_compat`.

The preferred-cipher half is not optional, and this is the non-obvious
part: **in external mode rook does not use the credentials we hand it.**
`rook-ceph-external-cluster-details` carries the real `client.admin`
key, so the operator connects as admin and runs its own
`auth get-or-create` for `client.csi-rbd-provisioner`,
`client.csi-rbd-node` and `client.ceph-exporter`, overwriting the CSI
secrets this repo wrote. That call passes no `--key-type`, so without a
cluster-wide default those keys come out AES-256 and ceph-csi fails
every `CreateVolume` with `rados: ret=-22, Invalid argument` -- leaving
every RBD PVC `Pending` while the StorageCluster still reports `Ready`.

Three things follow:

- `client.openshift` (`ceph_client_name`) is currently vestigial. It is
  still created and still written into the secret, so a future rook that
  honours the supplied credentials keeps working, but nothing reads it
  today. Do not use it to reason about which client is actually in use.
- The CephFS users escape the problem only by accident:
  `ceph_cephfs_provisioner_client` / `ceph_cephfs_node_client` already
  carry the exact names rook asks for, so its get-or-create finds the
  AES-128 keys `cephfs.yml` created. Do not rename them.
- Key type is readable without decoding a whole key: AES-128 keys are
  `AQ...` and 40 base64 characters, AES-256 keys `Ag...` and 60.

Since the image moved to `20.2.1-405` (9.1.2) the mon also raises three
health checks over exactly the state this workaround creates:
`AUTH_INSECURE_KEYS_ALLOWED`, `AUTH_INSECURE_KEYS_CREATABLE` and
`AUTH_INSECURE_CLIENT_KEY_TYPE` (one count per client holding an AES-128
key). They are permanent by construction and there is no `mon_warn_on_*`
option for them, so `cephx_compat.yml` mutes them, `--sticky` and without
a TTL. Two consequences:

- A healthy cluster prints `HEALTH_OK (muted: AUTH_INSECURE_...)`, not a
  bare `HEALTH_OK`. Every gate -- `cephfs.yml`, `playbooks/shutdown.yml`,
  `playbooks/startup.yml` -- matches the leading status word, never the
  whole line.
- `--sticky` is load-bearing. A plain mute is cleared as soon as the
  check gets worse, and `AUTH_INSECURE_CLIENT_KEY_TYPE` counts entities:
  rook mints three CSI/exporter users of its own in stage 09, taking the
  count from 4 to 7 and un-muting the check just after the deploy
  reported success.

The mute list is `ceph_cephx_insecure_health_checks`; empty it for an
image that predates these checks, since the wait for them to be raised is
deliberately fatal.

The downgrade is cluster-wide, future daemon keys included. Drop it --
along with the `--key-type AES` flags in `osd.yml` and `cephfs.yml` --
once the el10 tools repo and ODF ship clients that keep pace with the
image. Setting `ceph_cephx_aes128_compat: false` only affects fresh
deploys; it does not roll an existing cluster back.

### CephFS / RWX StorageClass

`enable_cephfs` (default true) adds a CephFS filesystem on the ceph VM
(`roles/ceph/tasks/cephfs.yml`) and the matching entries in the ODF
external-cluster secret (`roles/odf/templates/ceph-connection.yml.j2`),
yielding `ocs-external-storagecluster-cephfs`. RBD stays the default
StorageClass; NooBaa/OBC are untouched.

This repo hand-writes the secret that upstream generates with
`ceph-external-cluster-details-exporter.py`, so four non-obvious parts of
that contract have to be reproduced by hand. All four are silent
failures -- nothing errors at apply time:

- **`userID` / `userKey`, not `adminID` / `adminKey`.** ceph-csi accepts
  the latter only as a deprecated fallback.
- **Never run `osd pool application enable <pool> cephfs`.** The CSI osd
  caps match on `tag cephfs metadata=<fs>`, and only `ceph fs new`
  writes that key/value pair. A bare application enable leaves the tag
  empty and the provisioner is denied.
- **Never add or change parameters on the `ceph-rbd` entry.**
  ocs-operator compares `sc.Parameters` and *deletes and recreates* the
  StorageClass when they differ, dropping the hand-applied
  `is-default-class` annotation -- which breaks the NooBaa DB PVC and
  every PVC relying on the default class.
- **ocs-operator does not watch the secret.** Its `Owns(&corev1.Secret{})`
  is filtered by `GenerationChangedPredicate` and Secrets have no
  generation, so a changed secret alone takes effect only at the 10h
  resync. The odf role bumps an annotation on the StorageCluster to force
  a reconcile.

Two more single-host consequences: new cephx users must be created with
`--key-type AES` (same skew as above), and the filesystem runs a single
MDS with `standby_count_wanted 0` -- otherwise `MDS_INSUFFICIENT_STANDBY`
pins the cluster at HEALTH_WARN and `make shutdown`, which demands
`HEALTH_OK`, refuses to run.

### Verifying that ODF actually works

`StorageCluster` reaching phase `Ready` only means the external
CephCluster connected; it says nothing about provisioning. A cluster
whose RBD CSI credentials are unusable sits at `Ready` indefinitely with
every PVC `Pending`, and the deploy reports success.

The `odf` role therefore ends by waiting for the `noobaa` CR to reach
phase `Ready`. NooBaa is the only stock consumer of the default RBD
StorageClass, so this is an end-to-end provisioning check that costs no
extra PVC. On failure it lists the unbound PVCs and points at the CSI
provisioner log. It is unconditional, unlike `odf_cephfs_smoke_test`,
which is opt-in because it writes to the cluster.

CephFS has no equivalent free consumer, hence that separate opt-in smoke
test, which provisions an RWX PVC and deletes it again.

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
