// Read the kernel's current physical footprint without walking VM mappings.
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    int measured = 0;
    for (int index = 1; index < argc; index++) {
        char *end;
        errno = 0;
        long parsed = strtol(argv[index], &end, 10);
        if (errno || !*argv[index] || *end || parsed <= 0 || parsed > INT_MAX) return 2;
        int pid = (int)parsed;
        struct rusage_info_v0 usage = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&usage)) {
            // Exited children are expected between the tree snapshot and probe.
            // Any inaccessible live process makes the entire sample unusable.
            if (kill(pid, 0) == -1 && errno == ESRCH) continue;
            return 1;
        }
        printf("process [%d]: 64-bit Footprint: %" PRIu64 " B\n", pid, usage.ri_phys_footprint);
        measured++;
    }
    return measured ? 0 : 1;
}
