#pragma once
#include <stdbool.h>
#include <stdint.h>
#define WATCH_PACKET_SIZE 20
enum watch_action { WATCH_SYNC=0, WATCH_BOOT_LONG=1, WATCH_BOOT_SHORT=2, WATCH_END=3 };
enum watch_capture { WATCH_IDLE=0, WATCH_STARTING=1, WATCH_RECORDING=2, WATCH_PAUSED=3, WATCH_FINALIZING=4 };
enum watch_result { WATCH_SNAPSHOT=0, WATCH_APPLIED=1, WATCH_REJECTED=2, WATCH_RECEIVED=4 };
typedef struct {
    uint32_t nonce, epoch, phone_time;
    uint16_t sequence, revision;
    uint64_t synchronized_ms, deadline_ms;
    uint8_t capture, flags;
    bool ready, pending;
    uint8_t packet[WATCH_PACKET_SIZE];
} watch_state;
void watch_init(watch_state *s, uint32_t nonce);
void watch_disconnected(watch_state *s);
bool watch_request(watch_state *s, enum watch_action action, uint64_t now_ms);
// Returns 1 only for matched terminal success; 2 for matched failure; 0 otherwise.
int watch_accept(watch_state *s, const uint8_t *packet, unsigned length, uint64_t now_ms);
bool watch_timeout(watch_state *s, uint64_t now_ms);
