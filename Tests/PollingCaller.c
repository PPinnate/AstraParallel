extern int g_poll(void *, unsigned int, int);
int astra_test_external_gpoll(void *fds, unsigned int count, int timeout) {
    return g_poll(fds, count, timeout);
}
