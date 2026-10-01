#include "AstraPlatform.h"
#include <poll.h>
#include <stddef.h>

// GLib's GPollFD ABI on Darwin matches pollfd. Its installed fallback uses
// select(), which fails once a watched descriptor exceeds FD_SETSIZE.
struct AstraGPollFD { int fd; unsigned short events, revents; };
_Static_assert(sizeof(struct AstraGPollFD) == sizeof(struct pollfd), "poll ABI size");
_Static_assert(offsetof(struct AstraGPollFD, revents) == offsetof(struct pollfd, revents), "poll ABI layout");
extern void g_main_context_set_poll_func(void *, int (*)(void *, unsigned int, int));

int astra_gpoll(void *fds, unsigned int count, int timeout_ms) {
    return poll((struct pollfd *)fds, (nfds_t)count, timeout_ms);
}

void astra_configure_glib_context(void *context) {
    g_main_context_set_poll_func(context, astra_gpoll);
}
