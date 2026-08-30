<!--
SPDX-FileCopyrightText: 2026 Chimera-NAS Project Contributors
SPDX-License-Identifier: Unlicense
-->

# kvm-test-base

Build infrastructure for the QEMU guest images used by [chimera](https://github.com/chimera-nas/chimera)'s
KVM-based integration tests (NFS/SMB/pNFS over a real client kernel).

These images contain **no chimera code** — they are generic Ubuntu guests with
NFS/CIFS client tooling plus the [cthon04](https://github.com/chimera-nas/cthon04)
and [xfstests](https://github.com/chimera-nas/xfstests) suites. Since `v1.10.0`
they also carry `nfs-kernel-server`, so a guest can serve NFS (knfsd) as a
reference implementation for the [specs](https://github.com/chimera-nas/specs)
conformance harness; nothing starts it unless a harness asks. At test time
chimera runs a server on the host (in a network namespace) and the VM mounts its
export and runs the suites against it.

This repo was split out of `chimera/kvm/` so the (expensive) image build runs
**once per version** and is published as a downloadable artifact, instead of
being rebuilt on every chimera CI run.

### Kerberos (sec=krb5) NFS

The image ships `krb5-user` and `nfs-common`'s `rpc.gssd` so the guest can mount
with `sec=krb5`/`krb5i`/`krb5p`. The realm material (krb5.conf, the client
machine keytab, and `/etc/hosts` entries) is generated per test by an ephemeral
KDC on the host and handed to the guest over a 9p share tagged `krbshare`, so it
is **not** baked into the image. To activate it the host harness passes
`krb5=1` (and optionally `guest_host=<fqdn>`) on the kernel cmdline and exposes
the share, e.g.:

```
-fsdev local,id=krbfs,path=<krbdir>,security_model=none \
-device virtio-9p-pci,fsdev=krbfs,mount_tag=krbshare
```

`init.sh` then copies `krbshare/{krb5.conf,krb5.keytab,hosts}` into place, sets
the hostname, loads `rpcsec_gss_krb5`, mounts `rpc_pipefs`, and starts
`rpc.gssd`.

## Published artifacts

The [publish workflow](.github/workflows/publish.yml) builds each variant for
`amd64` and `arm64` and pushes the kernel + initrd + rootfs as a single
**OCI artifact** (via [ORAS](https://oras.land) — these are opaque blobs, not
runnable container images) to GHCR:

```
ghcr.io/chimera-nas/kvm-test-base:<variant>-<version>-<arch>
  payload: vmlinuz, initrd, rootfs.qcow2
```

A single 2-segment repository is used with the variant encoded in the tag (not
`.../kvm-test-base/<variant>`), so registry pull-through proxies that can't
route nested 3+ segment repository paths still work.

- `<version>` is read from the [`VERSION`](VERSION) file (e.g. `v1.0.0`).
- **Versions are immutable**: the publish workflow refuses to overwrite an
  already-published `<variant>-<version>-<arch>` tag. To ship changes, bump
  `VERSION` — that creates new artifacts and leaves existing ones untouched.
  Bump the major on breaking changes so pinned consumers keep working.
- A moving `<variant>-latest-<arch>` tag tracks the most recently published version.

Packages are public, so pulls need no authentication:

```sh
oras pull ghcr.io/chimera-nas/kvm-test-base:ubuntu2404-v1.0.0-amd64 -o ./out
```

### Variants

| variant | Ubuntu | kernel |
|---|---|---|
| `ubuntu2404` | 24.04 | `linux-image-generic` |
| `ubuntu2404_hwe` | 24.04 | `linux-image-generic-hwe-24.04` |
| `ubuntu2204_hwe` | 22.04 | `linux-image-generic-hwe-22.04` |
| `ubuntu2604` | 26.04 | `linux-image-generic` |

See [`variants.txt`](variants.txt) for the canonical list.

> The 22.04 **generic** kernel was dropped in `v1.1.0`: it builds `virtio_blk`
> as a module, so it can only mount its root disk from an initrd, whereas
> chimera boots these guests with no initrd. 22.04 is covered by its HWE kernel
> (`ubuntu2204_hwe`), which has virtio built in. `v1.0.0` still has all four
> variants for consumers pinned to it.

> The 26.04 **generic** kernel (added in `v1.4.0`) builds `virtio_blk` in, so it
> boots no-initrd like 24.04 -- no HWE variant is needed yet. (`ubuntu2604_hwe`
> is deferred: the `linux-image-generic-hwe-26.04` meta-package does not exist
> until the 26.04.1 point release.)

## Building locally

No registry access is required to build an image yourself — only Docker plus
`qemu-utils` and `e2fsprogs`:

```sh
mkdir -p out
bash build_vm_image.sh "$PWD/out" "$PWD/Dockerfile.kvm" "$PWD" \
    UBUNTU_VERSION=24.04 UBUNTU_VERSION_CODENAME=noble \
    KERNEL_PACKAGE=linux-image-generic
# -> out/vmlinuz, out/initrd, out/rootfs.qcow2
```

## License

[Unlicense](LICENSE) — see [REUSE](https://reuse.software) headers on each file.
