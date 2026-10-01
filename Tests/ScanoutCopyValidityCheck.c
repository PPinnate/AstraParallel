#include <assert.h>
#include <stdio.h>
#include "CSCopyValidity.h"
int main(void) {
    CSCopyValidity state = {0};
    CSCopyReset(&state);
    CSCopyTicket first = CSCopyBegin(&state);
    CSCopyTicket queued = CSCopyBegin(&state);
    assert(first.full && !queued.full);
    assert(!CSCopyComplete(&state, first, false));
    assert(state.needsFullCopy && !state.valid);
    // A successful partial copy queued before the failure cannot publish.
    assert(!CSCopyComplete(&state, queued, true));
    CSCopyTicket recovery = CSCopyBegin(&state);
    assert(recovery.full);
    assert(CSCopyComplete(&state, recovery, true));
    CSCopyTicket partial = CSCopyBegin(&state);
    assert(!partial.full && CSCopyComplete(&state, partial, true));
    CSCopyReset(&state); // resize / new surface while an old copy is pending
    assert(!CSCopyComplete(&state, partial, true));
    assert(state.needsFullCopy && !state.valid);
    puts("PASS: failed baseline, queued partial update, full recovery and surface replacement");
}
