# frozen_string_literal: true

require "mkmf"

have_header("linux/mount.h")
have_header("sys/mount.h")
have_header("sys/syscall.h")
have_header("sched.h")
have_func("syscall", "unistd.h")
have_func("unshare", "sched.h")
create_header
create_makefile("mountfd/mountfd")
