<h1 align="center">Mountfd</h1>

<p align="center">
  <strong>Ruby bindings for Linux's file-descriptor-based mount API</strong>
</p>

<p align="center">
  <a href="https://github.com/ydah/mountfd/actions/workflows/main.yml"><img src="https://github.com/ydah/mountfd/actions/workflows/main.yml/badge.svg" alt="Build Status"></a>
  <a href="https://rubygems.org/gems/mountfd"><img src="https://img.shields.io/gem/v/mountfd.svg?colorB=319e8c" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/mountfd"><img src="https://img.shields.io/gem/dt/mountfd.svg" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.2-ruby.svg" alt="Ruby Version">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License">
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#how-it-works">How It Works</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#compatibility">Compatibility</a>
</p>

---

Mountfd builds Linux mounts while detached, applies their final attributes,
and only then attaches them to a mount namespace. This avoids the visibility
window and option-string limitations of the legacy `mount(2)` API.

## Features

- Create and configure filesystems through `fsopen`, `fsconfig`, and `fsmount`
- Clone bind mounts with `open_tree` and attach them atomically with `move_mount`
- Apply read-only, recursive, propagation, and idmapped mount attributes
- Surface structured kernel diagnostics from filesystem contexts
- Discover mounts through `statmount`/`listmount`, with a mountinfo fallback
- Create user namespaces and inspect or change mount namespaces
- Load safely on macOS and Windows for runtime feature detection
- Use a native C extension without Fiddle or FFI

## Installation

Add Mountfd to your Gemfile:

```ruby
gem "mountfd"
```

Then install dependencies:

```sh
bundle install
```

Alternatively, run `bundle add mountfd` or `gem install mountfd`.

### Requirements

- Ruby 3.2 or newer
- Linux 5.2 or newer for the new mount API
- `CAP_SYS_ADMIN` in the owning user namespace, normally provided by an
  unprivileged user namespace or privileged container

Newer operations have additional kernel requirements:

| Feature | Minimum kernel |
|---|---:|
| New mount API | 5.2 |
| `mount_setattr` and idmapped mounts | 5.12 |
| `statmount` and `listmount` | 6.8 |
| Mount namespace descriptors with `statmount` | 6.11 |

## Quick Start

Create, configure, and attach a tmpfs mount:

```ruby
require "mountfd"

Mountfd.mount(
  "tmpfs", "/mnt/tmp",
  options: {size: "64M"},
  attrs: {nosuid: true, nodev: true, atime: :noatime}
)

Mountfd.umount("/mnt/tmp")
```

Check support before using mount operations on a portable application:

```ruby
Mountfd.supported? # false on macOS or a kernel older than 5.2
Mountfd.features   # [:new_mount_api, :mount_setattr, :idmap, ...]
```

## How It Works

```text
FsContext (fsopen) -> superblock (fsconfig) -> DetachedMount (fsmount)
                                                    |
existing mount ---------------- open_tree(CLONE) ---+
                                                    |
                                             move_mount
                                                    v
                                             mounted path
```

Mountfd calls `fsopen`, `fsconfig`, `fsmount`, `fspick`, `open_tree`,
`move_mount`, `mount_setattr`, `statmount`, `listmount`, and `umount2`
directly. A detached mount remains invisible until `move_mount` attaches it;
closing its file descriptor discards it.

## Usage

### Filesystem contexts

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

### Bind and idmapped mounts

`bind` clones a detached mount tree. Recursive attributes are applied before
the tree becomes visible:

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

The triples are written to `uid_map` and `gid_map` in kernel order. Mapping an
on-disk UID 100000 to UID 0 from the initial user namespace uses
`{100_000 => [0, 1]}`. A container that maps root to host UID 100000 normally
uses `{0 => [100_000, 65_536]}` for both its user namespace and mount.

`:auto` uses `newuidmap` and `newgidmap` for non-root callers when both are
installed. Requested ranges must also be delegated in `/etc/subuid` and
`/etc/subgid`.

### Mount discovery

```ruby
Mountfd.mounts                 # Array<Mountfd::MountInfo>
Mountfd.mount_at("/home")      # MountInfo or nil
Mountfd.mounts_backend         # :statmount or :mountinfo
Mountfd.mounts(ns: 1234)       # parses /proc/1234/mountinfo
File.open("/proc/1234/ns/mnt") { Mountfd.mounts(ns: _1) } # Linux 6.11+
```

The mountinfo fallback decodes octal path escapes and variable optional
fields. A disappearing mount during `statmount` enumeration is treated as a
normal race. Generic attributes and propagation are normalized across both
backends. An integer namespace argument remains a process ID. `source` and
filesystem-specific `options` may be nil or empty when the kernel does not
return the corresponding statmount field.

### Namespace helpers

Namespace changes affect the calling OS thread and belong in a single-threaded
setup phase:

```ruby
Mountfd::Namespace.reexec_user! # robust entry path, including Ruby 3.4+
Mountfd::Namespace.unshare_user!(map_root: true)
Mountfd::Namespace.unshare_mount!(propagation: :private)
Mountfd.pivot_root(new_root, put_old)
```

`reexec_user!` restarts the current command through `unshare -Ur`; use it
before creating threads. In-process `unshare_user!` is available when Ruby has
only one OS thread.

### Examples

The [`examples`](examples) directory contains:

- An overlay mini-container
- An idmapped volume
- A read-only sandbox with a writable tmpfs at `/tmp`
- An atomic mount replacement using `MOVE_MOUNT_BENEATH`

Set `MOUNTFD_LANDLOCK=1` when running `readonly_sandbox.rb` with the optional
`landlock` gem to restrict writes to `/tmp` and `/dev/null`. Exec-based examples
use a supervising parent to remove temporary mount trees after the command
exits, including after a nonzero status. Landlock provides defense in depth;
the mount namespace remains the primary boundary.

## Compatibility

Unsupported platforms still load the gem, but mount operations raise
`Mountfd::UnsupportedError`.

| Environment | Behavior |
|---|---|
| macOS and Windows | The gem builds and loads; mount operations are unavailable. |
| WSL2 with a kernel older than 5.2 | The new mount syscalls are unavailable. |
| Docker Desktop | Operations affect the Linux VM or container namespace, not the host filesystem. |
| Unprivileged Docker | Default seccomp and capability policies commonly reject mount and user-namespace operations. |
| Ubuntu 24.04+ | AppArmor may block unprivileged user namespaces through `kernel.apparmor_restrict_unprivileged_userns=1`. |
| GitHub-hosted runners | Unit tests work; system tests depend on the runner's user-namespace policy. |

Idmapped mount support also varies by filesystem and kernel. The safe,
source-free probe produced:

| Kernel | tmpfs | ramfs | hugetlbfs |
|---|---|---|---|
| 5.10 | no/unavailable | no/unavailable | no/unavailable |
| 5.15 | no/unavailable | no/unavailable | no/unavailable |
| 6.1 | no/unavailable | no/unavailable | no/unavailable |
| 6.6 | yes | no/unavailable | no/unavailable |
| 6.8 | yes | no/unavailable | no/unavailable |
| 6.12 | yes | no/unavailable | no/unavailable |

Run `bundle exec rake research:idmap_support` in the target environment.
Filesystems that need a block device or mount options are excluded from the
safe probe; the system suite separately verifies ext4 on a loop device on
Linux 5.15 and 6.8.

## Development

```sh
bundle install
bundle exec rake test:unit
bundle exec rbs -I sig validate
```

System tests change mount namespaces and require Linux with user namespaces
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

Additional diagnostics and benchmarks:

```sh
bundle exec rake research:idmap_support
bundle exec rake benchmark:mounts # defaults to a namespace with 1000 mounts
```

## Scope

Mountfd intentionally does not wrap legacy `mount(2)`, FUSE mount helpers, or
systemd `.mount` units. Filesystem-specific `fsconfig` keys are passed directly
to the kernel without duplicating kernel validation.

## Contributing

Bug reports and pull requests are welcome at
[github.com/ydah/mountfd](https://github.com/ydah/mountfd).

## License

Released under the [MIT License](LICENSE.txt).
