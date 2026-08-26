#include "ruby.h"
#include "mountfd.h"
#include "compat.h"

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#ifdef __linux__
#define MOUNTFD_STAT_SIZE 512
#define MOUNTFD_STAT_MASK (STATMOUNT_SB_BASIC | STATMOUNT_MNT_BASIC | \
    STATMOUNT_PROPAGATE_FROM | STATMOUNT_MNT_ROOT | STATMOUNT_MNT_POINT | \
    STATMOUNT_FS_TYPE | STATMOUNT_MNT_NS_ID | STATMOUNT_MNT_OPTS | \
    STATMOUNT_FS_SUBTYPE | STATMOUNT_SB_SOURCE)

struct mountfd_mnt_id_req {
    uint32_t size;
    uint32_t spare;
    uint64_t mnt_id;
    uint64_t param;
    uint64_t mnt_ns_id;
};

struct mountfd_statmount {
    uint32_t size;
    uint32_t mnt_opts;
    uint64_t mask;
    uint32_t dev_major;
    uint32_t dev_minor;
    uint64_t sb_magic;
    uint32_t sb_flags;
    uint32_t fs_type;
    uint64_t mnt_id;
    uint64_t parent_id;
    uint32_t old_id;
    uint32_t old_parent_id;
    uint64_t attrs;
    uint64_t propagation;
    uint64_t peer_group;
    uint64_t master;
    uint64_t propagate_from;
    uint32_t root;
    uint32_t point;
    uint64_t namespace_id;
    uint32_t fs_subtype;
    uint32_t source;
    unsigned char reserved[MOUNTFD_STAT_SIZE - 128];
};

static VALUE symbol(const char *name)
{
    return ID2SYM(rb_intern(name));
}

static VALUE stat_string(char *buffer, size_t capacity, uint32_t offset)
{
    struct mountfd_statmount *stat = (struct mountfd_statmount *)buffer;
    size_t position = MOUNTFD_STAT_SIZE + offset;
    size_t available;
    if (position >= capacity || position >= stat->size) return Qnil;
    available = stat->size < capacity ? stat->size - position : capacity - position;
    return rb_str_new(buffer + position, strnlen(buffer + position, available));
}

static VALUE stat_hash(char *buffer, size_t capacity)
{
    struct mountfd_statmount *stat = (struct mountfd_statmount *)buffer;
    VALUE hash = rb_hash_new();
#define PUT(name, value) rb_hash_aset(hash, symbol(name), value)
    PUT("mnt_id", ULL2NUM(stat->mnt_id));
    PUT("parent_id", ULL2NUM(stat->parent_id));
    PUT("old_id", UINT2NUM(stat->old_id));
    PUT("old_parent_id", UINT2NUM(stat->old_parent_id));
    PUT("dev_major", UINT2NUM(stat->dev_major));
    PUT("dev_minor", UINT2NUM(stat->dev_minor));
    PUT("attrs", ULL2NUM(stat->attrs));
    PUT("propagation", ULL2NUM(stat->propagation));
    PUT("peer_group", ULL2NUM(stat->peer_group));
    PUT("master", ULL2NUM(stat->master));
    PUT("propagate_from", ULL2NUM(stat->propagate_from));
    PUT("mnt_root", (stat->mask & STATMOUNT_MNT_ROOT) ? stat_string(buffer, capacity, stat->root) : Qnil);
    PUT("mount_point", (stat->mask & STATMOUNT_MNT_POINT) ? stat_string(buffer, capacity, stat->point) : Qnil);
    PUT("fs_type", (stat->mask & STATMOUNT_FS_TYPE) ? stat_string(buffer, capacity, stat->fs_type) : Qnil);
    PUT("source", (stat->mask & STATMOUNT_SB_SOURCE) ? stat_string(buffer, capacity, stat->source) : Qnil);
    PUT("options", (stat->mask & STATMOUNT_MNT_OPTS) ? stat_string(buffer, capacity, stat->mnt_opts) : Qnil);
#undef PUT
    return hash;
}

static VALUE stat_one(uint64_t id, uint64_t namespace_id, int namespace_selected)
{
    struct mountfd_mnt_id_req request = {
        namespace_selected ? MNT_ID_REQ_SIZE_VER1 : MNT_ID_REQ_SIZE_VER0,
        0, id, MOUNTFD_STAT_MASK, namespace_id
    };
    size_t capacity = 4096;
    char *buffer = NULL;
    long result;

    while (capacity <= 1024 * 1024) {
        buffer = realloc(buffer, capacity);
        if (!buffer) rb_memerror();
        memset(buffer, 0, capacity);
        result = syscall(SYS_statmount, &request, buffer, capacity, 0);
        if (result == 0) {
            VALUE hash = stat_hash(buffer, capacity);
            free(buffer);
            return hash;
        }
        if (errno == ENOENT) { free(buffer); return Qnil; }
        if (errno != EOVERFLOW) {
            int error = errno;
            free(buffer); errno = error; mountfd_syscall_failed("statmount");
        }
        capacity *= 2;
    }
    free(buffer);
    rb_raise(rb_eRuntimeError, "statmount response exceeds 1 MiB");
}
#endif

static VALUE native_statmounts(VALUE self, VALUE namespace_fd)
{
#ifdef __linux__
    uint64_t namespace_id = 0;
    int namespace_selected = !NIL_P(namespace_fd);
    struct mountfd_mnt_id_req request = {MNT_ID_REQ_SIZE_VER0, 0, LSMT_ROOT, 0, 0};
    uint64_t ids[256];
    VALUE mounts = rb_ary_new();
    long count;
    size_t index;

    if (namespace_selected) {
        if (ioctl(NUM2INT(namespace_fd), NS_GET_MNTNS_ID, &namespace_id) < 0)
            mountfd_syscall_failed("NS_GET_MNTNS_ID");
        request.size = MNT_ID_REQ_SIZE_VER1;
        request.mnt_ns_id = namespace_id;
    }

    while (1) {
        count = syscall(SYS_listmount, &request, ids, 256, 0);
        if (count < 0) mountfd_syscall_failed("listmount");
        if (count == 0) break;
        for (index = 0; index < (size_t)count; index++) {
            VALUE value = stat_one(ids[index], namespace_id, namespace_selected);
            if (!NIL_P(value)) rb_ary_push(mounts, value);
        }
        request.param = ids[count - 1];
        if (count < 256) break;
    }
    return mounts;
#else
    (void)namespace_fd;
    VALUE mountfd = rb_const_get(rb_cObject, rb_intern("Mountfd"));
    VALUE error = rb_const_get(mountfd, rb_intern("UnsupportedError"));
    rb_raise(error, "statmount is unavailable on this platform");
#endif
}

void mountfd_mount_info_init(VALUE native)
{
    rb_define_singleton_method(native, "statmounts", native_statmounts, 1);
}
