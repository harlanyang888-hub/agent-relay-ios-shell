#include "watch_protocol.h"
#include "pairing_reset.h"
#include "watch_link.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static void snapshot(watch_state *s,uint8_t *p,uint8_t result,uint8_t capture) {
 memset(p,0,20);p[0]='A';p[1]='R';p[2]=3;p[3]=result;p[4]=s->sequence;p[5]=s->sequence>>8;
 p[6]=42;p[10]=7;p[12]=100;p[16]=capture;
}
int main(void) {
 // Real trace: ENC_CHANGE arrived before CONNECT. All permutations of a secure
 // connection and restored subscription must reach the same usable state.
 const unsigned permutations[6][3]={{0,1,2},{0,2,1},{1,0,2},{1,2,0},{2,0,1},{2,1,0}};
 for(unsigned p=0;p<6;++p) {
  watch_link_state link;watch_link_init(&link);
  for(unsigned i=0;i<3;++i) {
   switch(permutations[p][i]) {
    case 0:watch_link_up(&link,1,true);break;
    case 1:watch_link_secure(&link,1,true);break;
    case 2:watch_link_subscribe(&link,1,true);break;
   }
  }
  assert(link.handle==1 && link.secure && link.subscribed);
  watch_link_secure(&link,2,false);assert(link.secure);
  assert(!watch_link_down(&link,2));assert(link.secure && link.subscribed);
  assert(watch_link_down(&link,1));assert(!link.secure && !link.subscribed);
  watch_link_up(&link,1,false);assert(!link.secure && !link.subscribed);
 }
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
 // END remains available to cancel an opening call or finish a saving message.
 assert(watch_request(&s,WATCH_SYNC,26000));snapshot(&s,p,WATCH_SNAPSHOT,WATCH_STARTING);watch_accept(&s,p,20,26001);
 assert(!watch_request(&s,WATCH_BOOT_LONG,26002));
 assert(watch_request(&s,WATCH_SYNC,26003));snapshot(&s,p,WATCH_SNAPSHOT,WATCH_STARTING);watch_accept(&s,p,20,26004);
 assert(watch_request(&s,WATCH_END,26005));
 snapshot(&s,p,WATCH_APPLIED,WATCH_IDLE);assert(watch_accept(&s,p,20,26006)==1);
 assert(watch_request(&s,WATCH_SYNC,27000));snapshot(&s,p,WATCH_SNAPSHOT,WATCH_FINALIZING);watch_accept(&s,p,20,27001);
 assert(watch_request(&s,WATCH_END,27002));
 puts("watch protocol tests passed");
}
