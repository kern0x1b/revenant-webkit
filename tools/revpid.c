/* Print the pid of each running process, optionally only those whose name
 * contains a substring.
 *
 *   revpid              # every process
 *   revpid MobileSafari # just the browser
 *
 * The device has no ps, and revmem takes a pid rather than a name, so there was
 * no way to measure a process's memory without first knowing its pid. The
 * kernel will list them through sysctl, which needs no entitlement.
 *
 *   clang -target armv7-apple-ios6.0 -isysroot $IOS_SDK -O1 -o revpid revpid.c
 *   ldid -S revpid && scp revpid root@device:/usr/bin/
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

int main(int argc, char **argv)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t length = 0;

    if (sysctl(mib, 4, NULL, &length, NULL, 0) < 0) {
        perror("sysctl");
        return 1;
    }

    struct kinfo_proc *processes = malloc(length);
    if (!processes) {
        perror("malloc");
        return 1;
    }

    if (sysctl(mib, 4, processes, &length, NULL, 0) < 0) {
        perror("sysctl");
        free(processes);
        return 1;
    }

    int count = (int)(length / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        const char *name = processes[i].kp_proc.p_comm;
        if (argc > 1 && !strstr(name, argv[1]))
            continue;
        printf("%d %s\n", processes[i].kp_proc.p_pid, name);
    }

    free(processes);
    return 0;
}
