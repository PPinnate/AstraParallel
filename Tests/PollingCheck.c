#include "AstraPlatform.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <sys/resource.h>
#include <unistd.h>
#include <dlfcn.h>

extern int g_poll(void *, unsigned int, int);

int main(int argc, char **argv) {
#ifdef ASTRA_LINKED_POLL_ADAPTER
    (void)astra_poll_interposer_anchor();
#endif
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit)) return 1;
    if (limit.rlim_cur < 4096) {
        limit.rlim_cur = limit.rlim_max < 4096 ? limit.rlim_max : 4096;
        if (setrlimit(RLIMIT_NOFILE, &limit)) return 1;
    }
    int pair[2];
    if (pipe(pair)) return 1;
    int high = fcntl(pair[0], F_DUPFD_CLOEXEC, 2048);
    close(pair[0]);
    if (high < 2048) return 1;
    if (write(pair[1], "x", 1) != 1) return 1;
    struct pollfd fd = {.fd=high, .events=POLLIN};
    errno = 0;
    int original = g_poll(&fd, 1, 0), original_errno = errno;
    fd.revents=0;
    int readable = astra_gpoll(&fd, 1, 0);
    int readable_ok = readable == 1 && (fd.revents & POLLIN);
    int interposed_ok = 1;
    if (argc == 2) {
        void *library = dlopen(argv[1], RTLD_NOW);
        int (*call)(void *, unsigned int, int) = library ? dlsym(library, "astra_test_external_gpoll") : NULL;
        fd.revents = 0;
        interposed_ok = call && call(&fd, 1, 0) == 1 && (fd.revents & POLLIN);
    }
    char byte;
    if (read(high, &byte, 1) != 1) return 1;
    fd.revents=0;
    int timeout = astra_gpoll(&fd, 1, 1);
    close(pair[1]);
    fd.revents=0;
    int hangup = astra_gpoll(&fd, 1, 0);
    int hangup_ok = hangup == 1 && (fd.revents & POLLHUP);
    close(high);
    int passed = readable_ok && timeout == 0 && hangup_ok && interposed_ok;
    printf("{\"pass\":%s,\"descriptor\":%d,\"original_result\":%d,\"original_errno\":%d,\"readable\":%s,\"timeout\":%d,\"hangup\":%s,\"external_interpose\":%s}\n",
           passed ? "true":"false", high, original, original_errno,
           readable_ok?"true":"false", timeout, hangup_ok?"true":"false", interposed_ok?"true":"false");
    return passed ? 0 : 1;
}
