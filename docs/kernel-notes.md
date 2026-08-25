# Kernel notes

Results recorded on 2026-08-25 while implementing the initial release.

| Environment | Result |
|---|---|
| macOS arm64, Ruby 4.0 | Native extension builds; `require` and unit tests pass; feature detection returns unsupported. |
| Linux arm64 container, Ruby 3.2/3.3/3.4 | Native extension builds; unit tests and RBS validation pass on every version. |
| Privileged Linux container | `fsopen(tmpfs)` → `fsconfig` → `fsmount` → `move_mount`, file I/O, and `umount2` pass in a private mount namespace. |
| Privileged Linux container | A misspelled tmpfs option returns `error: tmpfs: Unknown parameter 'sizee'`. |
| Privileged Linux container | `open_tree(CLONE)` plus `mount_setattr(MOUNT_ATTR_RDONLY)` rejects writes with `EROFS`. |
| Privileged Linux container | C-level user-namespace keeper returns a usable namespace fd and releases the keeper process. |
| Privileged Linux container | A tmpfs file owned by UID 100000 is reported as UID 0 through an idmapped bind using `100000 0 1`. |
| Linux 6.8.0-64 arm64 | `statmount` and mountinfo return the same visible mounts, including overmount filtering. |
| Linux 6.8.0-64 arm64 | `listmount` pagination passes with 270 new mounts; `statmount` buffer growth passes with more than 4 KiB of path data. |
| Linux 6.8.0-64 arm64 | 1000 explicit fd closes and `GC.stress` leave `/proc/self/fd` unchanged. |
| Linux 6.8.0-64 arm64 | Recursive read-only, attribute set/clear, propagation, detached discard, and atomic replacement tests pass. |
| Linux 6.8.0-64 arm64 | An ext4 loopback file owned by UID 1000 is UID 0 through an idmapped bind; an unmapped UID is 65534. |
| Linux 6.8.0-64 arm64, non-root | `newuidmap`/`newgidmap` create a namespace fd with delegated `100000:65536` sub-ID ranges. |
| Linux 6.8.0-64 arm64 | Safe source-free idmap probe: tmpfs yes; ramfs and hugetlbfs no/unavailable. |
| Linux 6.8.0-64 arm64 | 1000-mount benchmark, 10 iterations: statmount/listmount 30 ms; mountinfo parse 37 ms. |
| Linux 5.10.0 arm64, virtme-ng/QEMU | System suite: 15 examples, 0 failures, 11 expected pending; `mount_setattr` reports `UnsupportedError`. |
| Linux 5.15.0 arm64, virtme-ng/QEMU | System suite: 15 examples, 0 failures, 8 expected pending. |
| Linux 6.1.0 arm64, virtme-ng/QEMU | System suite: 15 examples, 0 failures, 8 expected pending. |
| Linux 6.6.0 arm64, virtme-ng/QEMU | System suite: 15 examples, 0 failures, 6 expected pending. |
| Linux 6.12.0 arm64, QEMU/TCG | A static initramfs probe passes `NS_GET_MNTNS_ID`, namespace-selected `listmount`, and namespace-selected `statmount`. |

The checked-in VM harness remains the source of truth for older-kernel
regressions. The full Ruby rootfs suite cannot boot with the tested 6.12.0
image because its kernel panics in netfs/9p before userspace starts; the static
initramfs probe isolates and validates the new 6.11 namespace-selection ABI.
Re-run the matrix before publishing a release.

```sh
make -C tools/vm KVER=5.15
make -C tools/vm KVER=6.1
make -C tools/vm KVER=6.6
make -C tools/vm KVER=6.12
```
