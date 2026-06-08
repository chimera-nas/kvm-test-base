<!--
SPDX-FileCopyrightText: 2026 Chimera-NAS Project Contributors
SPDX-License-Identifier: Unlicense
-->

# kvm-test-base

Build infrastructure for the QEMU guest images used by [chimera](https://github.com/chimera-nas/chimera)'s
KVM-based integration tests (NFS/SMB/pNFS over a real client kernel).

These images contain **no chimera code** — they are generic Ubuntu guests with
NFS/CIFS client tooling plus the [cthon04](https://github.com/chimera-nas/cthon04)
and [xfstests](https://github.com/chimera-nas/xfstests) suites. At test time
chimera runs a server on the host (in a network namespace) and the VM mounts its
export and runs the suites against it.

This repo was split out of `chimera/kvm/` so the (expensive) image build runs
**once per version** and is published as a downloadable artifact, instead of
being rebuilt on every chimera CI run.

## Published artifacts

The [publish workflow](.github/workflows/publish.yml) builds each variant for
`amd64` and `arm64` and pushes the kernel + initrd + rootfs as a single
**OCI artifact** (via [ORAS](https://oras.land) — these are opaque blobs, not
runnable container images) to GHCR:

```
ghcr.io/chimera-nas/kvm-test-base/<variant>:<version>-<arch>
  payload: vmlinuz, initrd, rootfs.qcow2
```

- `<version>` is `latest` on `main`, or the git tag (e.g. `v1.2.0`) on release.
- An immutable `g<short-sha>-<arch>` tag is also published for reproducible pins.

Packages are public, so pulls need no authentication:

```sh
oras pull ghcr.io/chimera-nas/kvm-test-base/ubuntu2404:latest-amd64 -o ./out
```

### Variants

| variant | Ubuntu | kernel |
|---|---|---|
| `ubuntu2404` | 24.04 | `linux-image-generic` |
| `ubuntu2404_hwe` | 24.04 | `linux-image-generic-hwe-24.04` |
| `ubuntu2204` | 22.04 | `linux-image-generic` |
| `ubuntu2204_hwe` | 22.04 | `linux-image-generic-hwe-22.04` |

See [`variants.txt`](variants.txt) for the canonical list.

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
