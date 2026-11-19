# DFS power candidate (ESP-IDF 5.5.1)

This first candidate enables only `CONFIG_PM_ENABLE=y` and
`CONFIG_PM_DFS_INIT_AUTO=y` in `sdkconfig.defaults`. ESP-IDF 5.5.1 documents
automatic DFS initialization as using `CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ` for
the maximum CPU frequency and the crystal frequency for the minimum. It does
not enable automatic light sleep: the startup configuration sets
`light_sleep_enable` false unless `CONFIG_FREERTOS_USE_TICKLESS_IDLE` enables
that path. This project does not request light sleep or deep sleep here.

The ESP32-S3 Bluetooth controller Kconfig sources the ESP32-C3 controller
options; `BT_CTRL_MODEM_SLEEP` defaults to `n`. This candidate does not change
that default. If DFS causes Bluetooth to hold PM locks, those locks keep the
requested CPU/APB frequency as specified by the controller. Verify generated
`sdkconfig` and runtime BLE behavior before any device trial.

The newer I2C master driver takes an `ESP_PM_APB_FREQ_MAX` lock around
operations on an APB-clocked bus and releases it afterward. It does not appear
to prevent idle CPU DFS between bus transactions. The current watch firmware
does not initialize the newer I2C master driver, so this is not a direct
dependency of this candidate.

No application code or hardware rail control changed. This is a build
candidate, not evidence of lower measured power or unchanged device response.
