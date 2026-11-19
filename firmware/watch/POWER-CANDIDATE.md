# Watch DFS-only power candidate

Baseline: 13b851e24fb211744c41f0b2eb441f9f0ec209ae.
Target: ESP32-S3, ESP-IDF v5.5.1.

Only two runtime build options are added: CONFIG_PM_ENABLE=y and
CONFIG_PM_DFS_INIT_AUTO=y. IDF components/esp_pm/pm_impl.c initializes DFS
with max_freq_mhz=CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ and
min_freq_mhz=esp_clk_xtal_freq()/1000000. The omitted light_sleep_enable
member is zero/false. This candidate does not request light sleep or deep
sleep, change CPU maximum frequency, or change the FreeRTOS tick rate.

All control sources, iOS files, button/haptic timing, command protocol,
acknowledgment/retry behavior, BLE parameters, pairing/NVS, telemetry and
PMIC rail settings remain byte-identical to baseline. There is no attempt
to integrate touch input, displays, a launcher, or alternative firmware.

ESP32-S3 sources the ESP32-C3 controller Kconfig. In v5.5.1,
CONFIG_BT_CTRL_MODEM_SLEEP defaults to n. This candidate preserves it.
The controller may therefore hold an APB maximum-frequency lock while
enabled, limiting idle DFS to 80 MHz rather than the crystal frequency.
The effective setting is checked against a generated baseline sdkconfig.
This is a conservative first experiment, not a promise of a large saving.

watch_battery.c already uses the newer I2C master driver. IDF's driver
accounts for APB clock requirements through PM locks during transactions.
No I2C application code is changed.

The comparison workflow builds the stable baseline and this candidate with
the same pinned SDK. tools/verify_watch_power_build.py checks the generated
configuration, source boundary and partition-table identity. It packages
both images, configs, build metadata and SHA-256 hashes. A successful build
is not evidence of measured energy saving or preserved physical response.

Device trial:
1. Verify the connected watch identity and idle state. Retain a verified
   current flash/NVS backup and the known-good 4cfc235 artifact.
2. Confirm the live partition table agrees with the package. Update only
   the application at its verified offset; do not erase flash/NVS or
   replace bootloader/partition table for this experiment.
3. Record boot/reset reason and PM initialization. Check lock-screen first
   gesture, start/pause/resume/send/end and physical confirmation haptics.
   Compare timing from valid gesture recognition to haptic onset and actual
   microphone capture, not from the start of a long press.
4. Repeat baseline/candidate battery-only idle measurements on the same
   device and conditions. Plugged-in USB readings are not discharge data.
   Keep ordinary telemetry frequency and recording behavior unchanged.
5. Any missed gesture, increased tail latency, reconnect failure, crash,
   lost/repeated message or audio issue requires return to the stable app.
   Do not mark this accepted from averages, compilation or BLE connect alone.

No firmware has been flashed as part of source/build preparation. Measured
current, runtime haptic latency, overnight idle and phone-side acceptance
remain required before daily adoption.

Official references:
- https://github.com/espressif/esp-idf/blob/v5.5.1/components/esp_pm/pm_impl.c
- https://github.com/espressif/esp-idf/blob/v5.5.1/components/esp_pm/Kconfig
- https://github.com/espressif/esp-idf/blob/v5.5.1/components/bt/controller/esp32c3/Kconfig.in
- https://docs.espressif.com/projects/esp-idf/en/v5.5.1/esp32s3/api-reference/system/power_management.html
