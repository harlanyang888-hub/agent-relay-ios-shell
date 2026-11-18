#include "watch_protocol.h"
#include "pairing_reset.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static void snapshot(watch_state *s,uint8_t *p,uint8_t result,uint8_t capture) {
 memset(p,0,20);p[0]='A';p[1]='R';p[2]=3;p[3]=result;p[4]=s->sequence;p[5]=s->sequence>>8;
 p[6]=42;p[10]=7;p[12]=100;p[16]=capture;
}
int main(void) {
 // Existing trusted links and everyday BOOT gestures must never lose keys.
 assert(!watch_pairing_reset_allowed(false,false,true,10000,false));
 assert(!watch_pairing_reset_allowed(true,true,true,10000,false));
 assert(!watch_pairing_reset_allowed(true,false,false,10000,false));
 assert(!watch_pairing_reset_allowed(true,false,true,1200,false));
 assert(!watch_pairing_reset_allowed(true,false,true,7999,false));
 assert(watch_pairing_reset_allowed(true,false,true,8000,false));
 assert(!watch_pairing_reset_allowed(true,false,true,12000,true));
 watch_state s;uint8_t p[20];watch_init(&s,123);
 assert(!watch_request(&s,WATCH_BOOT_LONG,0));
 assert(watch_request(&s,WATCH_SYNC,0));
 assert(!watch_request(&s,WATCH_BOOT_LONG,1));
 snapshot(&s,p,WATCH_SNAPSHOT,WATCH_IDLE);assert(!watch_accept(&s,p,19,1));assert(!s.ready);
 p[4]++;assert(!watch_accept(&s,p,20,1));assert(!s.ready);p[4]--;
 assert(!watch_accept(&s,p,20,2));assert(s.ready);
 assert(watch_request(&s,WATCH_BOOT_LONG,3));uint8_t original[20];memcpy(original,s.packet,20);
 snapshot(&s,p,WATCH_RECEIVED,WATCH_STARTING);assert(!watch_accept(&s,p,20,4));assert(s.pending);
 assert(!memcmp(original,s.packet,20));
 snapshot(&s,p,WATCH_APPLIED,WATCH_RECORDING);assert(watch_accept(&s,p,20,5)==1);
 assert(!watch_accept(&s,p,20,6)); // Lost ACK replay must not buzz twice.
 assert(watch_request(&s,WATCH_BOOT_SHORT,7));
 assert(!watch_timeout(&s,8006));assert(watch_timeout(&s,8007));assert(!s.ready);
 assert(!watch_accept(&s,p,20,8008)); // Late response cannot restore stale state.
 assert(watch_request(&s,WATCH_SYNC,9000));snapshot(&s,p,WATCH_SNAPSHOT,WATCH_PAUSED);
 watch_accept(&s,p,20,9001);assert(s.capture==WATCH_PAUSED);
 assert(!watch_request(&s,WATCH_END,25002)); // Fresh snapshot required after idle.
 assert(watch_request(&s,WATCH_SYNC,25003));snapshot(&s,p,WATCH_SNAPSHOT,WATCH_IDLE);watch_accept(&s,p,20,25004);
 watch_disconnected(&s);assert(!s.pending && !s.ready);assert(!watch_request(&s,WATCH_END,25005));
 puts("watch protocol tests passed");
}
