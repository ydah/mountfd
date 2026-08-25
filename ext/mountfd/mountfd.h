#ifndef MOUNTFD_H
#define MOUNTFD_H

#include "ruby.h"

VALUE mountfd_wrap_fd(int fd);
void mountfd_syscall_failed(const char *name);
void mountfd_user_namespace_init(VALUE native);

#endif
