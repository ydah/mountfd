#ifndef MOUNTFD_H
#define MOUNTFD_H

#include "ruby.h"

VALUE mountfd_wrap_fd(int fd);
#if defined(__GNUC__) || defined(__clang__)
__attribute__((noreturn))
#endif
void mountfd_syscall_failed(const char *name);
void mountfd_user_namespace_init(VALUE native);
void mountfd_mount_info_init(VALUE native);
void mountfd_namespace_init(VALUE native);

#endif
