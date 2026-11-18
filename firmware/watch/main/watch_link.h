#pragma once
#include <stdbool.h>
#include <stdint.h>
#define WATCH_LINK_NONE UINT16_MAX

typedef struct {
    uint16_t handle, subscription_handle;
    bool secure, subscribed, subscription_enabled;
} watch_link_state;

static inline void watch_link_init(watch_link_state *s) {
    *s=(watch_link_state){.handle=WATCH_LINK_NONE,.subscription_handle=WATCH_LINK_NONE};
}
static inline void watch_link_up(watch_link_state *s,uint16_t handle,bool encrypted_now) {
    s->handle=handle;
    // Read actual GAP security at CONNECT. ENC_CHANGE can precede CONNECT.
    s->secure=encrypted_now;
    s->subscribed=s->subscription_handle==handle && s->subscription_enabled;
}
static inline void watch_link_subscribe(watch_link_state *s,uint16_t handle,bool enabled) {
    // iOS may restore CCCD before the application consumes LINK_UP.
    s->subscription_handle=handle;s->subscription_enabled=enabled;
    if(s->handle==handle) s->subscribed=enabled;
}
static inline void watch_link_secure(watch_link_state *s,uint16_t handle,bool encrypted_now) {
    if(s->handle==handle) s->secure=encrypted_now;
}
static inline bool watch_link_down(watch_link_state *s,uint16_t handle) {
    if(s->subscription_handle==handle) {
        s->subscription_handle=WATCH_LINK_NONE;s->subscription_enabled=false;
    }
    if(s->handle!=handle) return false;
    s->handle=WATCH_LINK_NONE;s->secure=false;s->subscribed=false;
    return true;
}
