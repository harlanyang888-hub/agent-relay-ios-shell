#include "watch_battery.h"
#include <string.h>
#include "driver/i2c_master.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "host/ble_hs.h"

static portMUX_TYPE lock=portMUX_INITIALIZER_UNLOCKED;
static uint8_t cached[12]={1,0,255,0,0,0,0,0,0,0,0,0};
static uint16_t characteristic,connection=BLE_HS_CONN_HANDLE_NONE;
static i2c_master_dev_handle_t pmic;
static TaskHandle_t reader_task;
static uint16_t requested_token;
static bool refresh_pending;
bool watch_battery_request(uint16_t token) {
    portENTER_CRITICAL(&lock);
    TaskHandle_t task=reader_task;
    if(task) {requested_token=token;refresh_pending=true;}
    portEXIT_CRITICAL(&lock);
    if(task) xTaskNotifyGive(task);
    return task!=NULL;
}
static bool read_reg(uint8_t reg,uint8_t *out,size_t n) {
    return i2c_master_transmit_receive(pmic,&reg,1,out,n,20)==ESP_OK;
}
void watch_battery_packet(uint8_t out[12]) {
    portENTER_CRITICAL(&lock);memcpy(out,cached,12);portEXIT_CRITICAL(&lock);
}
void watch_battery_link(uint16_t handle) {
    portENTER_CRITICAL(&lock);connection=handle;portEXIT_CRITICAL(&lock);
}
static void battery_task(void *arg) {
    (void)arg;
    i2c_master_bus_handle_t bus=NULL;
    i2c_master_bus_config_t config={.i2c_port=I2C_NUM_0,.sda_io_num=15,.scl_io_num=14,
        .clk_source=I2C_CLK_SRC_DEFAULT,.glitch_ignore_cnt=7,.flags.enable_internal_pullup=true};
    esp_err_t rc=i2c_new_master_bus(&config,&bus);
    if(rc==ESP_OK) {
        i2c_device_config_t device={.dev_addr_length=I2C_ADDR_BIT_LEN_7,.device_address=0x34,.scl_speed_hz=100000};
        rc=i2c_master_bus_add_device(bus,&device,&pmic);
    }
    // Read-only telemetry: never copy example charger/rail configuration.
    int64_t last_sample=0;
    for(;;) {
        portENTER_CRITICAL(&lock);
        bool manual=refresh_pending;uint16_t token=manual ? requested_token : 0;refresh_pending=false;
        portEXIT_CRITICAL(&lock);
        int64_t now=esp_timer_get_time();
        if(manual && last_sample && now-last_sample<1000000) vTaskDelay(pdMS_TO_TICKS((1000000-(now-last_sample))/1000+1));
        uint8_t packet[12]={1,0,255,0,0,0,0,0,0,0,0,0};
        uint8_t id=0,status[2]={0},percent=255,adc=0,voltage[2]={0};
        bool ok=rc==ESP_OK && read_reg(0x03,&id,1) && id==0x4a && read_reg(0x00,status,2);
        if(ok) {
            packet[1]=1;
            if(status[0]&8) {
                packet[1]|=2;
                if(read_reg(0xa4,&percent,1) && percent<=100) packet[2]=percent;
                if(read_reg(0x30,&adc,1) && (adc&1) && read_reg(0x34,voltage,2)) {
                    uint16_t mv=((uint16_t)(voltage[0]&31)<<8)|voltage[1];
                    if(mv>=2000 && mv<=5000) {packet[1]|=16;packet[4]=mv;packet[5]=mv>>8;}
                }
            }
            if((status[0]&32) && !(status[1]&8)) packet[1]|=4;
            if((status[1]>>5)==1) packet[1]|=8;
        }
        uint32_t seconds=(uint32_t)(esp_timer_get_time()/1000000);
        for(unsigned i=0;i<4;i++) packet[6+i]=(uint8_t)(seconds>>(8*i));
        packet[10]=(uint8_t)token;packet[11]=(uint8_t)(token>>8);
        last_sample=esp_timer_get_time();
        portENTER_CRITICAL(&lock);memcpy(cached,packet,12);uint16_t handle=connection;portEXIT_CRITICAL(&lock);
        ESP_LOGI("relay-battery","valid=%d present=%d usb=%d charging=%d percent=%u millivolts=%u",
            !!(packet[1]&1),!!(packet[1]&2),!!(packet[1]&4),!!(packet[1]&8),packet[2],packet[4]|packet[5]<<8);
        struct ble_gap_conn_desc desc;
        if(handle!=BLE_HS_CONN_HANDLE_NONE && ble_gap_conn_find(handle,&desc)==0 && desc.sec_state.encrypted)
            ble_gatts_chr_updated(characteristic);
        ulTaskNotifyTake(pdTRUE,pdMS_TO_TICKS(60000));
    }
}
void watch_battery_start(uint16_t value_handle) {
    characteristic=value_handle;
    if(xTaskCreate(battery_task,"battery-read",3072,NULL,1,&reader_task)!=pdPASS)
        ESP_LOGW("relay-battery","telemetry unavailable: task allocation failed");
}
