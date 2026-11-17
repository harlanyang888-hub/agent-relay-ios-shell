idf_component_register(SRCS "main.c" "watch_protocol.c" INCLUDE_DIRS "." REQUIRES bt nvs_flash esp_driver_gpio esp_timer)
