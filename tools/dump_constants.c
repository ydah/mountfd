#include <linux/mount.h>
#include <stdio.h>

#define DUMP(name) printf(#name "=%llu\n", (unsigned long long)(name))

int main(void)
{
    DUMP(FSOPEN_CLOEXEC);
    DUMP(FSCONFIG_SET_FLAG);
    DUMP(FSCONFIG_SET_STRING);
    DUMP(FSCONFIG_CMD_CREATE);
    DUMP(FSMOUNT_CLOEXEC);
    DUMP(OPEN_TREE_CLONE);
    DUMP(OPEN_TREE_CLOEXEC);
    DUMP(MOVE_MOUNT_F_EMPTY_PATH);
    DUMP(MOUNT_ATTR_RDONLY);
    DUMP(MOUNT_ATTR_IDMAP);
    return 0;
}
