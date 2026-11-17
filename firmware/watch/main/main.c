#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "watch_protocol.h"

// All BLE callbacks enqueue events. Only the application task owns recording state.
#define UUID(x) BLE_UUID128_INIT(0x80,0x81,0x4b,0xa3,0xf2,0x73,0xd5,0xa2,0x93,0x4e,0x44,0x6b,x,0x02,0xd7,0xa8)
static const ble_uuid128_t service_uuid=UUID(0x00), event_uuid=UUID(0x01), state_uuid=UUID(0x02), identity_uuid=UUID(0x03);
static const char *TAG="relay-watch";
static uint8_t identity[16], own_type;
static uint16_t event_handle;
static QueueHandle_t events;
static portMUX_TYPE packet_lock=portMUX_INITIALIZER_UNLOCKED;
static uint8_t readable_packet[20];
static unsigned readable_length;
enum event_kind { LINK_UP, LINK_DOWN, SUBSCRIBED, SECURED, PHONE_STATE };
typedef struct { enum event_kind kind; uint16_t handle; bool enabled; uint8_t data[20]; } app_event;
static void advertise(void);
void ble_store_config_init(void);

static int access_value(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)attr;
    struct ble_gap_conn_desc desc;
    if(ble_gap_conn_find(conn,&desc)!=0 || !desc.sec_state.encrypted) return BLE_ATT_ERR_INSUFFICIENT_ENC;
    if(arg==(void*)1 && ctxt->op==BLE_GATT_ACCESS_OP_READ_CHR) {
        uint8_t copy[20];unsigned length;
        portENTER_CRITICAL(&packet_lock);length=readable_length;memcpy(copy,readable_packet,length);portEXIT_CRITICAL(&packet_lock);
        return os_mbuf_append(ctxt->om,copy,length)==0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if(arg==(void*)2 && ctxt->op==BLE_GATT_ACCESS_OP_WRITE_CHR) {
        app_event event={.kind=PHONE_STATE,.handle=conn};uint16_t length=0;
        if(OS_MBUF_PKTLEN(ctxt->om)!=20 || ble_hs_mbuf_to_flat(ctxt->om,event.data,20,&length)!=0) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        return xQueueSend(events,&event,0)==pdTRUE ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if(arg==(void*)3 && ctxt->op==BLE_GATT_ACCESS_OP_READ_CHR)
        return os_mbuf_append(ctxt->om,identity,16)==0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    return BLE_ATT_ERR_UNLIKELY;
}
static const struct ble_gatt_svc_def services[]={
    {.type=BLE_GATT_SVC_TYPE_PRIMARY,.uuid=&service_uuid.u,.characteristics=(struct ble_gatt_chr_def[]){
        {.uuid=&event_uuid.u,.access_cb=access_value,.arg=(void*)1,.val_handle=&event_handle,
         .flags=BLE_GATT_CHR_F_READ|BLE_GATT_CHR_F_READ_ENC|BLE_GATT_CHR_F_NOTIFY},
        {.uuid=&state_uuid.u,.access_cb=access_value,.arg=(void*)2,.flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_ENC},
        {.uuid=&identity_uuid.u,.access_cb=access_value,.arg=(void*)3,.flags=BLE_GATT_CHR_F_READ|BLE_GATT_CHR_F_READ_ENC},
        {0}}}, {0}};

static void enqueue(enum event_kind kind,uint16_t handle,bool enabled) {
    app_event event={.kind=kind,.handle=handle,.enabled=enabled};
    // Loss of a link event is unsafe: reset rather than continue using stale state.
    if(xQueueSend(events,&event,0)!=pdTRUE) abort();
}
static int gap_event(struct ble_gap_event *event,void *arg) {
    (void)arg;
    switch(event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if(event->connect.status==0) {enqueue(LINK_UP,event->connect.conn_handle,true);ble_gap_security_initiate(event->connect.conn_handle);}
        else advertise();
        break;
    case BLE_GAP_EVENT_DISCONNECT: enqueue(LINK_DOWN,event->disconnect.conn.conn_handle,false);advertise();break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if(event->subscribe.attr_handle==event_handle) enqueue(SUBSCRIBED,event->subscribe.conn_handle,event->subscribe.cur_notify);
        break;
    case BLE_GAP_EVENT_ENC_CHANGE: {
        struct ble_gap_conn_desc desc;
        bool secure=event->enc_change.status==0 && ble_gap_conn_find(event->enc_change.conn_handle,&desc)==0 && desc.sec_state.encrypted;
        enqueue(SECURED,event->enc_change.conn_handle,secure);break;
    }
    case BLE_GAP_EVENT_ADV_COMPLETE: advertise();break;
    // Never silently delete an old bond to accept a new pairing. Explicit reset is separate.
    case BLE_GAP_EVENT_REPEAT_PAIRING: return BLE_GAP_REPEAT_PAIRING_IGNORE;
    default:break;
    }
    return 0;
}
static void advertise(void) {
    struct ble_hs_adv_fields fields={0};
    fields.flags=BLE_HS_ADV_F_DISC_GEN|BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128=(ble_uuid128_t*)&service_uuid;fields.num_uuids128=1;fields.uuids128_is_complete=1;
    int rc=ble_gap_adv_set_fields(&fields);
    if(rc!=0) {ESP_LOGE(TAG,"advertising fields rc=%d",rc);return;}
    struct ble_hs_adv_fields response={0};const char *name=ble_svc_gap_device_name();
    response.name=(uint8_t*)name;response.name_len=strlen(name);response.name_is_complete=1;
    ble_gap_adv_rsp_set_fields(&response);
    struct ble_gap_adv_params params={.conn_mode=BLE_GAP_CONN_MODE_UND,.disc_mode=BLE_GAP_DISC_MODE_GEN};
    rc=ble_gap_adv_start(own_type,NULL,BLE_HS_FOREVER,&params,gap_event,NULL);
    ESP_LOGI(TAG,"advertising rc=%d",rc);
}
static void synchronized(void) {
    // ESP32 factory public identity remains stable across normal resets and battery loss.
    int rc=ble_hs_util_ensure_addr(0);assert(rc==0);
    rc=ble_hs_id_infer_auto(0,&own_type);assert(rc==0);advertise();
}
static void host_task(void *arg) { (void)arg;nimble_port_run();nimble_port_freertos_deinit(); }
static void transmit(watch_state *state,uint16_t handle) {
    portENTER_CRITICAL(&packet_lock);memcpy(readable_packet,state->packet,20);readable_length=20;portEXIT_CRITICAL(&packet_lock);
    struct os_mbuf *packet=ble_hs_mbuf_from_flat(state->packet,20);
    if(packet) {int rc=ble_gatts_notify_custom(handle,event_handle,packet);if(rc) ESP_LOGW(TAG,"notify rc=%d",rc);}
}
static void pulse(unsigned count,unsigned duration) {
    for(unsigned i=0;i<count;++i) {gpio_set_level(GPIO_NUM_18,1);vTaskDelay(pdMS_TO_TICKS(duration));gpio_set_level(GPIO_NUM_18,0);vTaskDelay(pdMS_TO_TICKS(80));}
}
typedef struct { bool raw,stable,long_sent;uint64_t changed,pressed; } button;
static int gesture(button *b,bool pressed,uint64_t now) {
    if(pressed!=b->raw) {b->raw=pressed;b->changed=now;}
    if(now-b->changed>=35 && b->stable!=b->raw) {
        b->stable=b->raw;
        if(b->stable) {b->pressed=now;b->long_sent=false;}
        else if(!b->long_sent) return 1;
    }
    if(b->stable && !b->long_sent && now-b->pressed>=1200) {b->long_sent=true;return 2;}
    return 0;
}
void app_main(void) {
    // Do not erase NVS on initialization failure: it contains pairing identity/keys.
    ESP_ERROR_CHECK(nvs_flash_init());
    nvs_handle_t store;ESP_ERROR_CHECK(nvs_open("relay_watch",NVS_READWRITE,&store));
    size_t length=sizeof(identity);esp_err_t rc=nvs_get_blob(store,"identity",identity,&length);
    if(rc==ESP_ERR_NVS_NOT_FOUND) {esp_fill_random(identity,16);identity[6]=(identity[6]&15)|64;identity[8]=(identity[8]&63)|128;ESP_ERROR_CHECK(nvs_set_blob(store,"identity",identity,16));ESP_ERROR_CHECK(nvs_commit(store));}
    else {ESP_ERROR_CHECK(rc);assert(length==16);}nvs_close(store);
    gpio_config_t buttons={.pin_bit_mask=1ULL<<0,.mode=GPIO_MODE_INPUT,.pull_up_en=GPIO_PULLUP_ENABLE};ESP_ERROR_CHECK(gpio_config(&buttons));
    gpio_config_t power_input={.pin_bit_mask=1ULL<<10,.mode=GPIO_MODE_INPUT,.pull_down_en=GPIO_PULLDOWN_ENABLE};ESP_ERROR_CHECK(gpio_config(&power_input));
    gpio_config_t motor={.pin_bit_mask=1ULL<<18,.mode=GPIO_MODE_OUTPUT};ESP_ERROR_CHECK(gpio_config(&motor));gpio_set_level(GPIO_NUM_18,0);
    events=xQueueCreate(16,sizeof(app_event));assert(events);
    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.sync_cb=synchronized;ble_hs_cfg.store_status_cb=ble_store_util_status_rr;
    ble_hs_cfg.sm_io_cap=BLE_HS_IO_NO_INPUT_OUTPUT;ble_hs_cfg.sm_bonding=1;ble_hs_cfg.sm_sc=1;
    ble_hs_cfg.sm_our_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_svc_gap_init();ble_svc_gatt_init();ble_svc_gap_device_name_set("AgentRelay-Watch");
    ESP_ERROR_CHECK(ble_gatts_count_cfg(services));ESP_ERROR_CHECK(ble_gatts_add_svcs(services));
    ble_store_config_init();nimble_port_freertos_init(host_task);
    watch_state state;watch_init(&state,esp_random());button boot={0},power={0};
    uint16_t handle=BLE_HS_CONN_HANDLE_NONE;bool secure=false,subscribed=false;
    uint64_t retry_at=0,sync_at=0,gesture_deadline=0;
    int deferred_gesture=-1;
    ESP_LOGI(TAG,"watch protocol v3; requires matching phone build; no local microphone capture");
    while(true) {
        uint64_t now=esp_timer_get_time()/1000;app_event event;
        while(xQueueReceive(events,&event,0)==pdTRUE) {
            if(event.kind==LINK_UP) {handle=event.handle;secure=false;subscribed=false;watch_disconnected(&state);}
            else if(event.kind==LINK_DOWN && event.handle==handle) {handle=BLE_HS_CONN_HANDLE_NONE;secure=false;subscribed=false;deferred_gesture=-1;sync_at=0;watch_disconnected(&state);}
            else if(event.handle==handle) {
                if(event.kind==SECURED) {secure=event.enabled;if(!secure) watch_disconnected(&state);else sync_at=0;}
                if(event.kind==SUBSCRIBED) {subscribed=event.enabled;if(!subscribed) watch_disconnected(&state);else sync_at=0;}
                if(event.kind==PHONE_STATE && secure && subscribed) {
                    int result=watch_accept(&state,event.data,20,now);
                    if(result==1) pulse(state.capture==WATCH_PAUSED ? 2 : 1,state.capture==WATCH_IDLE ? 200 : 60);
                    if(result==2) pulse(3,40);
                    if(state.ready && !state.pending) sync_at=UINT64_MAX;
                }
            }
        }
        if(watch_timeout(&state,now)) {ESP_LOGW(TAG,"phone confirmation timed out");pulse(3,40);deferred_gesture=-1;sync_at=UINT64_MAX;}
        if(deferred_gesture>=0 && now>=gesture_deadline) {deferred_gesture=-1;pulse(3,40);}
        if(deferred_gesture>=0 && state.ready && !state.pending) {
            enum watch_action action=(enum watch_action)deferred_gesture;deferred_gesture=-1;
            if(watch_request(&state,action,now)) {transmit(&state,handle);retry_at=now+1000;}
            else pulse(3,40);
        }
        int b=gesture(&boot,!gpio_get_level(GPIO_NUM_0),now),p=gesture(&power,gpio_get_level(GPIO_NUM_10),now);
        if(b || p==2) {
            enum watch_action action=p==2 ? WATCH_END : b==2 ? WATCH_BOOT_LONG : WATCH_BOOT_SHORT;
            if(!secure || !subscribed || deferred_gesture>=0) pulse(3,40);
            else if(watch_request(&state,action,now)) {transmit(&state,handle);retry_at=now+1000;}
            else if(!state.ready && (!state.pending || state.packet[3]==WATCH_SYNC)) {
                // One live gesture may wait for its state handshake, never a historical FIFO.
                deferred_gesture=action;gesture_deadline=now+5000;sync_at=0;
            } else pulse(3,40);
        }
        if(secure && subscribed && !state.pending && now>=sync_at) {
            if(watch_request(&state,WATCH_SYNC,now)) {transmit(&state,handle);retry_at=now+1000;sync_at=UINT64_MAX;}
        }
        if(secure && subscribed && state.pending && now>=retry_at) {transmit(&state,handle);retry_at=now+1000;}
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
