# Kernel notes

Results recorded on 2026-08-25 while implementing the initial release.

| Environment | Result |
|---|---|
| macOS arm64, Ruby 4.0 | Native extension builds; `require` and unit tests pass; feature detection returns unsupported. |
| Linux arm64 container, Ruby 3.2 | Native extension builds and detects the new mount API and `mount_setattr`. |
| Privileged Linux container | `fsopen(tmpfs)` → `fsconfig` → `fsmount` → `move_mount`, file I/O, and `umount2` pass in a private mount namespace. |
| Privileged Linux container | A misspelled tmpfs option returns `error: tmpfs: Unknown parameter 'sizee'`. |
| Privileged Linux container | `open_tree(CLONE)` plus `mount_setattr(MOUNT_ATTR_RDONLY)` rejects writes with `EROFS`. |
| Privileged Linux container | C-level user-namespace keeper returns a usable namespace fd and releases the keeper process. |
| Privileged Linux container | A tmpfs file owned by UID 100000 is reported as UID 0 through an idmapped bind using `100000 0 1`. |
| Current container host kernel | `statmount`/`listmount` are unavailable, so mount discovery correctly selects mountinfo. |

The ext4 loopback idmap matrix and the `statmount` backend still require the
kernel matrix below; they cannot be meaningfully exercised by the macOS host's
Linux VM kernel. Run the checked-in system suite on 5.15, 6.1, 6.6, and 6.12
before publishing a release.

```sh
make -C tools/vm KVER=5.15
make -C tools/vm KVER=6.1
make -C tools/vm KVER=6.6
make -C tools/vm KVER=6.12
```
