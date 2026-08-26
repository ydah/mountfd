#include "ruby.h"
#include "mountfd.h"
#include "compat.h"

#include <errno.h>
#include <unistd.h>
#ifdef __linux__
# include <sched.h>
# include <sys/mount.h>
#endif

static VALUE native_unshare(VALUE self, VALUE flags)
{
#ifdef __linux__
    if (unshare(NUM2INT(flags)) < 0) mountfd_syscall_failed("unshare");
    return Qnil;
#else
    VALUE mountfd = rb_const_get(rb_cObject, rb_intern("Mountfd"));
    VALUE error = rb_const_get(mountfd, rb_intern("UnsupportedError"));
    rb_raise(error, "namespaces are unavailable on this platform");
#endif
}

static VALUE native_change_propagation(VALUE self, VALUE path, VALUE flags)
{
#ifdef __linux__
    unsigned long raw_flags = NUM2ULONG(flags);
    const char *raw_path = StringValueCStr(path);
    if (mount(NULL, raw_path, NULL, raw_flags, NULL) < 0) {
        int error = errno;
        RB_GC_GUARD(path);
        errno = error;
        mountfd_syscall_failed("mount(propagation)");
    }
    RB_GC_GUARD(path);
    return Qnil;
#else
    VALUE mountfd = rb_const_get(rb_cObject, rb_intern("Mountfd"));
    VALUE error = rb_const_get(mountfd, rb_intern("UnsupportedError"));
    rb_raise(error, "mount propagation is unavailable on this platform");
#endif
}

static VALUE native_pivot_root(VALUE self, VALUE new_root, VALUE put_old)
{
#ifdef __linux__
    const char *root_path, *old_path;
    StringValueCStr(new_root);
    StringValueCStr(put_old);
    root_path = RSTRING_PTR(new_root);
    old_path = RSTRING_PTR(put_old);
    if (syscall(SYS_pivot_root, root_path, old_path) < 0) {
        int error = errno;
        RB_GC_GUARD(new_root);
        RB_GC_GUARD(put_old);
        errno = error;
        mountfd_syscall_failed("pivot_root");
    }
    RB_GC_GUARD(new_root);
    RB_GC_GUARD(put_old);
    return Qnil;
#else
    VALUE mountfd = rb_const_get(rb_cObject, rb_intern("Mountfd"));
    VALUE error = rb_const_get(mountfd, rb_intern("UnsupportedError"));
    rb_raise(error, "pivot_root is unavailable on this platform");
#endif
}

void mountfd_namespace_init(VALUE native)
{
    rb_define_singleton_method(native, "unshare", native_unshare, 1);
    rb_define_singleton_method(native, "change_propagation", native_change_propagation, 2);
    rb_define_singleton_method(native, "pivot_root", native_pivot_root, 2);
}
