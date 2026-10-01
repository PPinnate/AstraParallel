#ifndef ASTRA_PLATFORM_H
#define ASTRA_PLATFORM_H
int astra_gpoll(void *fds, unsigned int count, int timeout_ms);
void astra_configure_glib_context(void *context);
const void *astra_poll_interposer_anchor(void);
#endif
