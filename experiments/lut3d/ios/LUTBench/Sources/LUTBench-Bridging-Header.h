// proc_pid_rusage is exported by libsystem on iOS, but its prototype lives in libproc.h, which the
// iOS SDK does not ship. Declare it here (signature identical to macOS libproc.h) so Swift calls it
// with the C calling convention.
#include <sys/resource.h>

int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);
