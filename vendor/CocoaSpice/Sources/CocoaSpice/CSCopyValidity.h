// Astra scanout-copy validity. Only access on the serialized SPICE context.
#ifndef ASTRA_COPY_VALIDITY_H
#define ASTRA_COPY_VALIDITY_H
#include <stdbool.h>
#include <stdint.h>
typedef struct { uint64_t generation; bool needsFullCopy; bool valid; } CSCopyValidity;
typedef struct { uint64_t generation; bool full; } CSCopyTicket;
static inline void CSCopyReset(CSCopyValidity *state) {
    state->generation++; state->needsFullCopy = true; state->valid = false;
}
static inline CSCopyTicket CSCopyBegin(CSCopyValidity *state) {
    CSCopyTicket ticket = { state->generation, state->needsFullCopy };
    state->needsFullCopy = false;
    return ticket;
}
static inline bool CSCopyComplete(CSCopyValidity *state, CSCopyTicket ticket, bool succeeded) {
    if (ticket.generation != state->generation) return false;
    if (!succeeded) { CSCopyReset(state); return false; }
    if (ticket.full) state->valid = true;
    return state->valid;
}
#endif
