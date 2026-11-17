#include "watch_protocol.h"
#include <string.h>
static uint16_t r16(const uint8_t *p) { return (uint16_t)p[0] | (uint16_t)p[1]<<8; }
static uint32_t r32(const uint8_t *p) { return (uint32_t)r16(p) | (uint32_t)r16(p+2)<<16; }
static void w16(uint8_t *p, uint16_t x) { p[0]=x; p[1]=x>>8; }
static void w32(uint8_t *p, uint32_t x) { w16(p,x); w16(p+2,x>>16); }
void watch_init(watch_state *s, uint32_t nonce) { memset(s,0,sizeof(*s)); s->nonce=nonce ? nonce : 1; }
void watch_disconnected(watch_state *s) { s->ready=false; s->pending=false; }
bool watch_request(watch_state *s, enum watch_action action, uint64_t now) {
    if (s->pending || action>WATCH_END || (action!=WATCH_SYNC && !s->ready)) return false;
    if (action!=WATCH_SYNC && (now-s->synchronized_ms>15000 || s->capture==WATCH_STARTING || s->capture==WATCH_FINALIZING)) {
        s->ready=false; return false;
    }
    if (++s->sequence==0) { s->sequence=1; ++s->nonce; if (!s->nonce) ++s->nonce; }
    uint8_t *p=s->packet; memset(p,0,WATCH_PACKET_SIZE);
    p[0]='A';p[1]='R';p[2]=3;p[3]=action;
    w32(p+4,s->nonce);w16(p+8,s->sequence);w32(p+10,s->epoch);w16(p+14,s->revision);
    if(action!=WATCH_SYNC) w32(p+16,s->phone_time+(uint32_t)((now-s->synchronized_ms)/1000)+8);
    s->pending=true;s->deadline_ms=now+(action==WATCH_SYNC ? 5000 : 8000);return true;
}
int watch_accept(watch_state *s, const uint8_t *p, unsigned n, uint64_t now) {
    if(n!=WATCH_PACKET_SIZE || p[0]!='A' || p[1]!='R' || p[2]!=3 ||
       (p[3]!=WATCH_SNAPSHOT && p[3]!=WATCH_APPLIED && p[3]!=WATCH_REJECTED && p[3]!=WATCH_RECEIVED) || p[16]>WATCH_FINALIZING) return 0;
    // Only a response to the single in-flight request can establish fresh state.
    if(!s->pending || r16(p+4)!=s->sequence) return 0;
    if(now>=s->deadline_ms) {s->pending=false;s->ready=false;return 0;}
    if(p[3]==WATCH_RECEIVED) return 0;
    s->epoch=r32(p+6);s->revision=r16(p+10);s->phone_time=r32(p+12);
    s->capture=p[16];s->flags=p[17];s->synchronized_ms=now;
    s->pending=false;s->ready=true;
    return p[3]==WATCH_APPLIED ? 1 : p[3]==WATCH_REJECTED ? 2 : 0;
}
bool watch_timeout(watch_state *s, uint64_t now) {
    if(!s->pending || now<s->deadline_ms) return false;
    s->pending=false;s->ready=false;return true;
}
