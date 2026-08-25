#include "ruby.h"
#include "ruby/io.h"
#include "extconf.h"
#include "compat.h"
#include "mountfd.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#ifdef __linux__
# include <sys/mount.h>
#endif

typedef struct { int fd; } mountfd_handle;

static VALUE mMountfd, mNative, cHandle, eError, eUnsupported;

static void handle_free(void *ptr)
{
    mountfd_handle *handle = ptr;
    if (handle->fd >= 0) close(handle->fd);
    xfree(handle);
}

static size_t handle_size(const void *ptr)
{
    return ptr ? sizeof(mountfd_handle) : 0;
}

static const rb_data_type_t handle_type = {
    "Mountfd::Native::Handle",
    {NULL, handle_free, handle_size, NULL},
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED
};

static VALUE handle_alloc(VALUE klass)
{
    mountfd_handle *handle;
    VALUE object = TypedData_Make_Struct(klass, mountfd_handle, &handle_type, handle);
    handle->fd = -1;
    return object;
}

static mountfd_handle *get_handle(VALUE object)
{
    mountfd_handle *handle;
    TypedData_Get_Struct(object, mountfd_handle, &handle_type, handle);
    if (handle->fd < 0) rb_raise(eError, "closed file descriptor");
    return handle;
}

#ifdef __linux__
static int fd_from(VALUE value)
{
    if (rb_typeddata_is_kind_of(value, &handle_type)) return get_handle(value)->fd;
    return NUM2INT(value);
}
#endif

VALUE mountfd_wrap_fd(int fd)
{
    mountfd_handle *handle;
    VALUE object = handle_alloc(cHandle);
    TypedData_Get_Struct(object, mountfd_handle, &handle_type, handle);
    handle->fd = fd;
    return object;
}

static VALUE handle_fileno(VALUE self)
{
    return INT2NUM(get_handle(self)->fd);
}

static VALUE handle_close(VALUE self)
{
    mountfd_handle *handle;
    TypedData_Get_Struct(self, mountfd_handle, &handle_type, handle);
    if (handle->fd >= 0) {
        if (close(handle->fd) < 0) rb_sys_fail("close");
        handle->fd = -1;
    }
    return Qnil;
}

static VALUE handle_closed(VALUE self)
{
    mountfd_handle *handle;
    TypedData_Get_Struct(self, mountfd_handle, &handle_type, handle);
    return handle->fd < 0 ? Qtrue : Qfalse;
}

#ifndef __linux__
#if defined(__GNUC__) || defined(__clang__)
__attribute__((noreturn))
#endif
static void unavailable(void)
{
    rb_raise(eUnsupported, "the Linux new mount API is unavailable on this platform");
}
#endif

void mountfd_syscall_failed(const char *name)
{
    if (errno == ENOSYS || errno == EOPNOTSUPP)
        rb_raise(eUnsupported, "%s is not supported by this kernel or filesystem", name);
    if (errno == EPERM)
        rb_exc_raise(rb_syserr_new_str(errno, rb_sprintf(
            "%s (insufficient privilege or operation disallowed in this namespace)", name
        )));
    rb_syserr_fail(errno, name);
}

static VALUE native_linux_p(VALUE self)
{
#ifdef __linux__
    return Qtrue;
#else
    return Qfalse;
#endif
}

static VALUE native_syscall_available(VALUE self, VALUE name)
{
#ifdef __linux__
    const char *value = StringValueCStr(name);
    long result;
    if (strcmp(value, "fsopen") == 0) {
        result = syscall(SYS_fsopen, "__mountfd_probe__", FSOPEN_CLOEXEC);
    } else if (strcmp(value, "mount_setattr") == 0) {
        result = syscall(SYS_mount_setattr, -1, "", 0, NULL, 0);
    } else if (strcmp(value, "statmount") == 0) {
        result = syscall(SYS_statmount, NULL, NULL, 0, 0);
    } else if (strcmp(value, "listmount") == 0) {
        result = syscall(SYS_listmount, NULL, NULL, 0, 0);
    } else {
        rb_raise(rb_eArgError, "unknown syscall: %s", value);
    }
    if (result >= 0) close((int)result);
    return result >= 0 || errno != ENOSYS ? Qtrue : Qfalse;
#else
    return Qfalse;
#endif
}

static VALUE native_fsopen(VALUE self, VALUE fsname, VALUE flags)
{
#ifdef __linux__
    int fd = (int)syscall(SYS_fsopen, StringValueCStr(fsname), NUM2UINT(flags));
    if (fd < 0) mountfd_syscall_failed("fsopen");
    if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) {
        int error = errno;
        close(fd);
        errno = error;
        rb_sys_fail("fcntl");
    }
    return mountfd_wrap_fd(fd);
#else
    unavailable(); return Qnil;
#endif
}

static VALUE native_fsconfig(VALUE self, VALUE handle, VALUE command, VALUE key,
                             VALUE value, VALUE aux)
{
#ifdef __linux__
    unsigned int cmd = NUM2UINT(command);
    const char *key_ptr = NIL_P(key) ? NULL : StringValueCStr(key);
    const void *value_ptr;
    if (NIL_P(value)) value_ptr = NULL;
    else if (cmd == FSCONFIG_SET_BINARY) value_ptr = RSTRING_PTR(StringValue(value));
    else value_ptr = StringValueCStr(value);
    if (syscall(SYS_fsconfig, fd_from(handle), cmd, key_ptr, value_ptr, NUM2INT(aux)) < 0)
        mountfd_syscall_failed("fsconfig");
    return Qnil;
#else
    unavailable(); return Qnil;
#endif
}

static VALUE native_fsmount(VALUE self, VALUE handle, VALUE flags, VALUE attrs)
{
#ifdef __linux__
    int fd = (int)syscall(SYS_fsmount, fd_from(handle), NUM2UINT(flags), NUM2UINT(attrs));
    if (fd < 0) mountfd_syscall_failed("fsmount");
    return mountfd_wrap_fd(fd);
#else
    unavailable(); return Qnil;
#endif
}

static VALUE native_fspick(VALUE self, VALUE dfd, VALUE path, VALUE flags)
{
#ifdef __linux__
    int fd = (int)syscall(SYS_fspick, NUM2INT(dfd), StringValueCStr(path), NUM2UINT(flags));
    if (fd < 0) mountfd_syscall_failed("fspick");
    if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) {
        int error = errno;
        close(fd); errno = error; rb_sys_fail("fcntl");
    }
    return mountfd_wrap_fd(fd);
#else
    unavailable(); return Qnil;
#endif
}

static VALUE native_open_tree(VALUE self, VALUE dfd, VALUE path, VALUE flags)
{
#ifdef __linux__
    int fd = (int)syscall(SYS_open_tree, NUM2INT(dfd), StringValueCStr(path), NUM2UINT(flags));
    if (fd < 0) mountfd_syscall_failed("open_tree");
    return mountfd_wrap_fd(fd);
#else
    unavailable(); return Qnil;
#endif
}

static VALUE native_move_mount(VALUE self, VALUE from_dfd, VALUE from_path,
                               VALUE to_dfd, VALUE to_path, VALUE flags)
{
#ifdef __linux__
    if (syscall(SYS_move_mount, fd_from(from_dfd), StringValueCStr(from_path),
                NUM2INT(to_dfd), StringValueCStr(to_path), NUM2UINT(flags)) < 0)
        mountfd_syscall_failed("move_mount");
    return Qnil;
#else
    unavailable(); return Qnil;
#endif
}

static VALUE native_mount_setattr(VALUE self, VALUE dfd, VALUE path, VALUE flags,
                                  VALUE attr_set, VALUE attr_clr, VALUE propagation,
                                  VALUE userns_fd)
{
#ifdef __linux__
    struct mount_attr attr = {
        NUM2ULL(attr_set), NUM2ULL(attr_clr), NUM2ULL(propagation),
        NIL_P(userns_fd) ? 0 : (uint64_t)fd_from(userns_fd)
    };
    if (syscall(SYS_mount_setattr, fd_from(dfd), StringValueCStr(path), NUM2UINT(flags),
                &attr, MOUNT_ATTR_SIZE_VER0) < 0) mountfd_syscall_failed("mount_setattr");
    return Qnil;
#else
    unavailable(); return Qnil;
#endif
}

static VALUE native_umount2(VALUE self, VALUE path, VALUE flags)
{
#ifdef __linux__
    if (umount2(StringValueCStr(path), NUM2INT(flags)) < 0) mountfd_syscall_failed("umount2");
    return Qnil;
#else
    unavailable(); return Qnil;
#endif
}

static VALUE native_read_diagnostics(VALUE self, VALUE handle)
{
#ifdef __linux__
    char buffer[4096];
    VALUE output = rb_str_new(NULL, 0);
    ssize_t length;
    while ((length = read(fd_from(handle), buffer, sizeof(buffer))) > 0)
        rb_str_cat(output, buffer, length);
    if (length < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != ENODATA)
        rb_sys_fail("read(fs_context)");
    return output;
#else
    unavailable(); return Qnil;
#endif
}

void mountfd_define_constants(VALUE native);

void Init_mountfd(void)
{
    mMountfd = rb_define_module("Mountfd");
    eError = rb_const_get(mMountfd, rb_intern("Error"));
    eUnsupported = rb_const_get(mMountfd, rb_intern("UnsupportedError"));
    mNative = rb_define_module_under(mMountfd, "Native");
    cHandle = rb_define_class_under(mNative, "Handle", rb_cObject);
    rb_define_alloc_func(cHandle, handle_alloc);
    rb_undef_method(rb_singleton_class(cHandle), "new");
    rb_define_method(cHandle, "fileno", handle_fileno, 0);
    rb_define_method(cHandle, "close", handle_close, 0);
    rb_define_method(cHandle, "closed?", handle_closed, 0);
    rb_define_singleton_method(mNative, "linux?", native_linux_p, 0);
    rb_define_singleton_method(mNative, "syscall_available?", native_syscall_available, 1);
    rb_define_singleton_method(mNative, "fsopen", native_fsopen, 2);
    rb_define_singleton_method(mNative, "fsconfig", native_fsconfig, 5);
    rb_define_singleton_method(mNative, "fsmount", native_fsmount, 3);
    rb_define_singleton_method(mNative, "fspick", native_fspick, 3);
    rb_define_singleton_method(mNative, "open_tree", native_open_tree, 3);
    rb_define_singleton_method(mNative, "move_mount", native_move_mount, 5);
    rb_define_singleton_method(mNative, "mount_setattr", native_mount_setattr, 7);
    rb_define_singleton_method(mNative, "umount2", native_umount2, 2);
    rb_define_singleton_method(mNative, "read_diagnostics", native_read_diagnostics, 1);
    mountfd_define_constants(mNative);
    mountfd_user_namespace_init(mNative);
    mountfd_mount_info_init(mNative);
    mountfd_namespace_init(mNative);
}
