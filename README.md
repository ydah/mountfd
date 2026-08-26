# Mountfd

Mountfd exposes Linux's file-descriptor-based mount API to Ruby. It builds a
mount while detached, applies its final attributes, and only then attaches it
to the mount namespace. This avoids the visibility and option-string problems
of the legacy `mount(2)` API.

```text
FsContext (fsopen) -> superblock (fsconfig) -> DetachedMount (fsmount)
                                                    |
existing mount ---------------- open_tree(CLONE) ---+
                                                    |
                                             move_mount
                                                    v
                                             mounted path
```

The native extension calls `fsopen`, `fsconfig`, `fsmount`, `fspick`,
`open_tree`, `move_mount`, `mount_setattr`, `statmount`, `listmount`, and
`umount2` directly. It does not use Fiddle or FFI.

## Requirements

- Ruby 3.2 or newer
- Linux 5.2 or newer for the new mount API
- Linux 5.12 or newer for `mount_setattr` and idmapped mounts
- Linux 6.8 or newer for `statmount`/`listmount`; older kernels use
  `/proc/self/mountinfo`
- `CAP_SYS_ADMIN` in the owning user namespace, normally obtained through an
  unprivileged user namespace or a privileged container

`require "mountfd"` succeeds on unsupported platforms so applications can use
feature detection:

```ruby
Mountfd.supported? # false on macOS or a kernel older than 5.2
Mountfd.features   # [:new_mount_api, :mount_setattr, :idmap, ...]
```

Known unsupported or restricted environments:

| Environment | Result |
|---|---|
| macOS and Windows | The gem builds and loads, but mount operations raise `UnsupportedError`. |
| WSL2 with a kernel older than 5.2 | The new mount syscalls are unavailable. |
| Docker Desktop | Operations affect the Linux VM/container namespace, never the host filesystem. |
| Unprivileged Docker | The default seccomp/capability policy commonly rejects mount and user-namespace operations. |
| Ubuntu 24.04+ | AppArmor may block unprivileged user namespaces via `kernel.apparmor_restrict_unprivileged_userns=1`. |
| GitHub-hosted runners | Unit tests work; system tests depend on the runner's user-namespace policy. |

Filesystem support for idmapped mounts is kernel-dependent. The safe,
source-free probe produced:

| kernel | tmpfs | ramfs | hugetlbfs |
|---|---|---|---|
| 5.10 | no/unavailable | no/unavailable | no/unavailable |
| 5.15 | no/unavailable | no/unavailable | no/unavailable |
| 6.1 | no/unavailable | no/unavailable | no/unavailable |
| 6.6 | yes | no/unavailable | no/unavailable |
| 6.8 | yes | no/unavailable | no/unavailable |
| 6.12 | yes | no/unavailable | no/unavailable |

Run `rake research:idmap_support` in the target environment. Filesystems that
need a block device or mount options are deliberately excluded from this safe
probe; the system suite separately verifies ext4 on a loop device on Linux
5.15 and 6.8.

## Installation

```sh
bundle add mountfd
```

Or install it directly with `gem install mountfd`.

## Create and attach a mount

The block form closes the filesystem context while returning ownership of the
detached mount:

```ruby
mount = Mountfd::FsContext.open("tmpfs") do |context|
  context.set("size", "64M")
  context.set_flag("noswap")
  context.create!
  context.mount(attrs: {nosuid: true, nodev: true})
end

mount.attach("/mnt/tmp")
```

Configuration failures include diagnostics read from the filesystem context:

```ruby
context = Mountfd::FsContext.new("tmpfs")
context.set("sizee", "64M")
# Mountfd::ConfigError: fsconfig: Invalid argument
# error: tmpfs: Unknown parameter 'sizee'
```

The high-level form performs the same lifecycle:

```ruby
Mountfd.mount(
  "tmpfs", "/mnt/tmp",
  options: {size: "64M"},
  attrs: {nosuid: true, nodev: true, atime: :noatime}
)
Mountfd.umount("/mnt/tmp")
```

## Bind and idmapped mounts

`bind` uses `open_tree(OPEN_TREE_CLONE)`. Recursive attributes are applied to
the detached tree before it becomes visible:

```ruby
Mountfd.bind("/src", "/dst", recursive: true, attrs: {rdonly: true})
```

Pass an existing user namespace or a mapping. Mapping ranges may use a hash or
an array of `[inside, outside, length]` triples:

```ruby
Mountfd.bind(
  "/data", "/container/data", recursive: true,
  idmap: {
    uid: {0 => [100_000, 65_536]},
    gid: {0 => [100_000, 65_536]},
    helper: :auto
  }
)
```

The triples are written to `uid_map`/`gid_map` in kernel order. When the caller
uses the initial user namespace, mapping an on-disk UID 100000 so it is reported
as UID 0 uses `{100_000 => [0, 1]}`. A container that itself maps root to host
UID 100000 normally uses `{0 => [100_000, 65_536]}` for both its user namespace
and mount.

`:auto` uses `newuidmap` and `newgidmap` for non-root callers when both are
installed. Requested ranges must also be delegated in `/etc/subuid` and
`/etc/subgid`.

## Mount discovery

```ruby
Mountfd.mounts                 # Array<Mountfd::MountInfo>
Mountfd.mount_at("/home")      # MountInfo or nil
Mountfd.mounts_backend         # :statmount or :mountinfo
Mountfd.mounts(ns: 1234)       # parses /proc/1234/mountinfo
File.open("/proc/1234/ns/mnt") { Mountfd.mounts(ns: _1) } # statmount, Linux 6.11+
```

The mountinfo fallback decodes octal path escapes and handles the variable
optional-field section. A disappearing mount during `statmount` enumeration is
ignored as a normal race. An open mount namespace descriptor can be passed on
Linux 6.11 or newer; an integer namespace argument remains a process ID.

## Namespace helpers

Namespace changes affect the calling OS thread and are intended for a
single-threaded setup phase:

```ruby
Mountfd::Namespace.reexec_user! # robust entry path, including Ruby 3.4+
Mountfd::Namespace.unshare_user!(map_root: true)
Mountfd::Namespace.unshare_mount!(propagation: :private)
Mountfd.pivot_root(new_root, put_old)
```

`reexec_user!` restarts the current command through `unshare -Ur`; use it before
creating threads. The in-process `unshare_user!` is available when the Ruby
process has only one OS thread.

See `examples/` for an overlay mini-container, idmapped volume, read-only
sandbox with a writable tmpfs at `/tmp`, and `MOVE_MOUNT_BENEATH` atomic swap.
Set `MOUNTFD_LANDLOCK=1` when running `readonly_sandbox.rb` with the optional
`landlock` gem installed to restrict filesystem writes to `/tmp` (plus `/dev/null`)
as defense in depth. The exec-based examples use a supervising parent so their
temporary mount trees are removed after the command exits, including on a
nonzero exit status.

## Development

```sh
bundle install
bundle exec rake test:unit
bundle exec rbs -I sig validate
```

System tests change mount namespaces and must run on Linux with user namespaces
enabled:

```sh
bundle exec rake test:system
bundle exec rake test:adversarial # 270-mount pagination and long statmount data
bundle exec rake test:ext4       # root plus loop-device access
```

For kernel-matrix testing, install `virtme-ng` and run:

```sh
make -C tools/vm KVER=6.12.20
```

The source-free idmap probe prints a Markdown table for the current kernel:

```sh
bundle exec rake research:idmap_support
bundle exec rake benchmark:mounts # defaults to a namespace with 1000 mounts
```

## Scope

Mountfd intentionally does not wrap legacy `mount(2)`, FUSE mount helpers, or
systemd `.mount` units. Filesystem-specific `fsconfig` keys are passed to the
kernel without duplicating kernel validation.

## License

Mountfd is available under the MIT License.
