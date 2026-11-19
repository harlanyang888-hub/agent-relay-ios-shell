#pragma once
#include <stdint.h>
// Independent from the recording protocol. 255 percent / 0 mV mean unknown.
// flags: sample valid, battery present, USB present, charging, voltage valid.
void watch_battery_start(uint16_t value_handle);
void watch_battery_packet(uint8_t out[12]);
void watch_battery_link(uint16_t handle);
