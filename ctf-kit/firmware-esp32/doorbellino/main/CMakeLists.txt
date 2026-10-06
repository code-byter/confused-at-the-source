idf_component_register(SRCS "doorbellino_main.c" "db_wifi.c"
                       INCLUDE_DIRS "."
                       REQUIRES esp_http_client app_update esp_netif esp_wifi nvs_flash driver
                       PRIV_REQUIRES mbedtls)
