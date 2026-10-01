#include "AstraPlatform.h"
extern int g_poll(void *, unsigned int, int);

// Only Astra's processes receive this adaptation. Installed UTM files are not
// changed. This also covers QEMU's direct calls outside a GMainContext.
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } interpose_gpoll = {
    (const void *)astra_gpoll, (const void *)g_poll
};

const void *astra_poll_interposer_anchor(void) { return &interpose_gpoll; }
