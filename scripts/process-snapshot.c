// Capture process relationships and start times without reading arguments.
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>

int main(void) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    for (int attempt = 0; attempt < 3; attempt++) {
        size_t bytes = 0;
        if (sysctl(mib, 3, NULL, &bytes, NULL, 0) || !bytes) return 1;
        bytes += 256 * sizeof(struct kinfo_proc);
        struct kinfo_proc *processes = malloc(bytes);
        if (!processes) return 1;
        if (sysctl(mib, 3, processes, &bytes, NULL, 0)) {
            int error = errno;
            free(processes);
            if (error == ENOMEM) continue;
            return 1;
        }
        if (bytes % sizeof(*processes)) { free(processes); return 1; }
        size_t count = bytes / sizeof(*processes);
        for (size_t index = 0; index < count; index++) {
            struct kinfo_proc *process = &processes[index];
            printf("%d %d %d %jd:%jd %u\n", process->kp_proc.p_pid,
                   process->kp_eproc.e_ppid, process->kp_eproc.e_pgid,
                   (intmax_t)process->kp_proc.p_starttime.tv_sec,
                   (intmax_t)process->kp_proc.p_starttime.tv_usec,
                   (unsigned)process->kp_proc.p_stat);
        }
        free(processes);
        return count ? 0 : 1;
    }
    return 1;
}
