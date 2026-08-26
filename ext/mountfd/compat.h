#ifndef MOUNTFD_COMPAT_H
#define MOUNTFD_COMPAT_H

#ifdef __linux__
# include <fcntl.h>
# include <stdint.h>
# include <sys/ioctl.h>
# include <sys/syscall.h>
# ifdef HAVE_LINUX_MOUNT_H
#  include <linux/mount.h>
# endif

# ifndef SYS_open_tree
#  define SYS_open_tree 428
# endif
# ifndef SYS_move_mount
#  define SYS_move_mount 429
# endif
# ifndef SYS_fsopen
#  define SYS_fsopen 430
# endif
# ifndef SYS_fsconfig
#  define SYS_fsconfig 431
# endif
# ifndef SYS_fsmount
#  define SYS_fsmount 432
# endif
# ifndef SYS_fspick
#  define SYS_fspick 433
# endif
# ifndef SYS_mount_setattr
#  define SYS_mount_setattr 442
# endif
# ifndef SYS_statmount
#  define SYS_statmount 457
# endif
# ifndef SYS_listmount
#  define SYS_listmount 458
# endif
# ifndef SYS_pivot_root
#  ifdef __NR_pivot_root
#   define SYS_pivot_root __NR_pivot_root
#  elif defined(__x86_64__)
#   define SYS_pivot_root 155
#  elif defined(__aarch64__)
#   define SYS_pivot_root 41
#  else
#   error "SYS_pivot_root is unavailable for this architecture"
#  endif
# endif

# ifndef FSOPEN_CLOEXEC
#  define FSOPEN_CLOEXEC 0x00000001
# endif
# ifndef FSPICK_CLOEXEC
#  define FSPICK_CLOEXEC 0x00000001
#  define FSPICK_SYMLINK_NOFOLLOW 0x00000002
#  define FSPICK_NO_AUTOMOUNT 0x00000004
#  define FSPICK_EMPTY_PATH 0x00000008
# endif
# ifndef FSCONFIG_SET_FLAG
#  define FSCONFIG_SET_FLAG 0
#  define FSCONFIG_SET_STRING 1
#  define FSCONFIG_SET_BINARY 2
#  define FSCONFIG_SET_PATH 3
#  define FSCONFIG_SET_PATH_EMPTY 4
#  define FSCONFIG_SET_FD 5
#  define FSCONFIG_CMD_CREATE 6
#  define FSCONFIG_CMD_RECONFIGURE 7
# endif
# ifndef FSCONFIG_CMD_CREATE_EXCL
#  define FSCONFIG_CMD_CREATE_EXCL 8
# endif
# ifndef FSMOUNT_CLOEXEC
#  define FSMOUNT_CLOEXEC 0x00000001
# endif
# ifndef OPEN_TREE_CLONE
#  define OPEN_TREE_CLONE 1
# endif
# ifndef OPEN_TREE_CLOEXEC
#  define OPEN_TREE_CLOEXEC O_CLOEXEC
# endif
# ifndef MOVE_MOUNT_F_SYMLINKS
#  define MOVE_MOUNT_F_SYMLINKS 0x00000001
#  define MOVE_MOUNT_F_AUTOMOUNTS 0x00000002
#  define MOVE_MOUNT_F_EMPTY_PATH 0x00000004
#  define MOVE_MOUNT_T_SYMLINKS 0x00000010
#  define MOVE_MOUNT_T_AUTOMOUNTS 0x00000020
#  define MOVE_MOUNT_T_EMPTY_PATH 0x00000040
# endif
# ifndef MOVE_MOUNT_SET_GROUP
#  define MOVE_MOUNT_SET_GROUP 0x00000100
# endif
# ifndef MOVE_MOUNT_BENEATH
#  define MOVE_MOUNT_BENEATH 0x00000200
# endif
# ifndef MOUNT_ATTR_RDONLY
#  define MOUNT_ATTR_RDONLY 0x00000001ULL
#  define MOUNT_ATTR_NOSUID 0x00000002ULL
#  define MOUNT_ATTR_NODEV 0x00000004ULL
#  define MOUNT_ATTR_NOEXEC 0x00000008ULL
#  define MOUNT_ATTR__ATIME 0x00000070ULL
#  define MOUNT_ATTR_RELATIME 0x00000000ULL
#  define MOUNT_ATTR_NOATIME 0x00000010ULL
#  define MOUNT_ATTR_STRICTATIME 0x00000020ULL
#  define MOUNT_ATTR_NODIRATIME 0x00000080ULL
# endif
# ifndef MOUNT_ATTR_IDMAP
#  define MOUNT_ATTR_IDMAP 0x00100000ULL
# endif
# ifndef MOUNT_ATTR_NOSYMFOLLOW
#  define MOUNT_ATTR_NOSYMFOLLOW 0x00200000ULL
# endif
# ifndef MOUNT_ATTR_SIZE_VER0
#  define MOUNT_ATTR_SIZE_VER0 32
struct mount_attr {
    uint64_t attr_set;
    uint64_t attr_clr;
    uint64_t propagation;
    uint64_t userns_fd;
};
# endif
# ifndef AT_RECURSIVE
#  define AT_RECURSIVE 0x8000
# endif
# ifndef AT_EMPTY_PATH
#  define AT_EMPTY_PATH 0x1000
# endif
# ifndef MS_UNBINDABLE
#  define MS_UNBINDABLE (1 << 17)
# endif
# ifndef MS_REC
#  define MS_REC 16384
# endif
# ifndef MS_PRIVATE
#  define MS_PRIVATE (1 << 18)
# endif
# ifndef MS_SLAVE
#  define MS_SLAVE (1 << 19)
# endif
# ifndef MS_SHARED
#  define MS_SHARED (1 << 20)
# endif
# ifndef CLONE_NEWNS
#  define CLONE_NEWNS 0x00020000
# endif
# ifndef CLONE_NEWUSER
#  define CLONE_NEWUSER 0x10000000
# endif
# ifndef NSIO
#  define NSIO 0xb7
# endif
# ifndef NS_GET_MNTNS_ID
#  define NS_GET_MNTNS_ID _IOR(NSIO, 0x5, uint64_t)
# endif
# ifndef MNT_ID_REQ_SIZE_VER0
#  define MNT_ID_REQ_SIZE_VER0 24
# endif
# ifndef MNT_ID_REQ_SIZE_VER1
#  define MNT_ID_REQ_SIZE_VER1 32
# endif
# ifndef STATMOUNT_SB_BASIC
#  define STATMOUNT_SB_BASIC 0x00000001U
# endif
# ifndef STATMOUNT_MNT_BASIC
#  define STATMOUNT_MNT_BASIC 0x00000002U
# endif
# ifndef STATMOUNT_PROPAGATE_FROM
#  define STATMOUNT_PROPAGATE_FROM 0x00000004U
# endif
# ifndef STATMOUNT_MNT_ROOT
#  define STATMOUNT_MNT_ROOT 0x00000008U
# endif
# ifndef STATMOUNT_MNT_POINT
#  define STATMOUNT_MNT_POINT 0x00000010U
# endif
# ifndef STATMOUNT_FS_TYPE
#  define STATMOUNT_FS_TYPE 0x00000020U
# endif
# ifndef STATMOUNT_MNT_NS_ID
#  define STATMOUNT_MNT_NS_ID 0x00000040U
# endif
# ifndef STATMOUNT_MNT_OPTS
#  define STATMOUNT_MNT_OPTS 0x00000080U
# endif
# ifndef STATMOUNT_FS_SUBTYPE
#  define STATMOUNT_FS_SUBTYPE 0x00000100U
# endif
# ifndef STATMOUNT_SB_SOURCE
#  define STATMOUNT_SB_SOURCE 0x00000200U
# endif
# ifndef LSMT_ROOT
#  define LSMT_ROOT UINT64_MAX
# endif
#endif

#endif
