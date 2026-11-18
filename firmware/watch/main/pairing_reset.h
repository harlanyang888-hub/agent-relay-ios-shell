#pragma once
#include <stdbool.h>
#include <stdint.h>

// Recovery requires a physical hold on a connection with a confirmed bond
// conflict. Ordinary long presses and healthy encrypted links never clear keys.
static inline bool watch_pairing_reset_allowed(bool conflict, bool encrypted,
        bool held, uint64_t held_ms, bool already_requested) {
    return conflict && !encrypted && held && held_ms >= 8000 && !already_requested;
}
