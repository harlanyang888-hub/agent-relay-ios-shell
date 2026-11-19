idf_component_register(SRCS "main.c" "watch_protocol.c" "watch_battery.c" INCLUDE_DIRS "." REQUIRES bt nvs_flash esp_driver_gpio esp_driver_i2c esp_timer)
