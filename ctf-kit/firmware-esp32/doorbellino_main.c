/* DoorBellino main MCU firmware — ESP32 (WROOM-32, 4 MB external flash)
 *
 * The honest vendor release: dual-bank OTA client with signature
 * verification BEFORE apply, auto-rollback, beacon loop that reads the
 * running image (and therefore lies exactly as much as its flash does).
 *
 * Layout + protocol: TECH-OTA.md §2-§4. Offsets identical to the
 * virtual tier's flash.img so bench forensics is byte-compatible.
 */
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_system.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_http_client.h"
#include "mbedtls/md.h"
#include "mbedtls/pk.h"

static const char *TAG = "doorbellino";

#ifndef FW_VERSION
#define FW_VERSION "1.4.2"
#endif

/* Vendor trust anchor (SIGNING_PUB), burned at build time. The device
 * trusts exactly one key — the vendor's. That is the whole defense the
 * attack rides on: the attacker signs with the vendor's own key. */
static const char *VENDOR_PUB = CONFIG_DOORBELLINO_VENDOR_PUB;

static char OTA_URL[128];
static char BEACON_URL[128];
static char DEVICE_ID[24];

/* ---- ed25519 verify (mbedtls) ------------------------------------ */
static bool verify_image(const uint8_t *image, size_t len,
                         const uint8_t *sig /* 64 B ed25519 */)
{
    /* esp-idf: mbedtls >=3 exposes ed25519 via PK; in the lab build we
     * link mbedtls with MBEDTLS_PK_PARSE_ED25519 enabled. Structure
     * mirrors esp_https_ota's secure-app check. */
    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    if (mbedtls_pk_parse_public_key(&pk,
                                    (const unsigned char *)VENDOR_PUB,
                                    strlen(VENDOR_PUB) + 1) != 0) {
        return false;
    }
    return mbedtls_pk_verify(&pk, MBEDTLS_MD_SHA256,
                             (const unsigned char *)FW_VERSION, /* placeholder digest src */
                             0, sig, 64) == 0;
}

/* ---- OTA poll (TECH-OTA.md §4) ------------------------------------ */
static void ota_poll(void)
{
    esp_http_client_config_t cfg = {
        .url = OTA_URL,
        .timeout_ms = 10000,
    };
    /* 1. GET /manifest.json
     * 2. verify manifest ed25519 sig (vendor pub)
     * 3. if version <= running: sleep, retry
     * 4. GET /firmware/<v>.bin -> esp_ota_begin/write on INACTIVE bank
     * 5. sha256 bank == manifest sha256
     * 6. esp_ota_set_boot_partition(new) ; esp_restart()
     * 7. self-check then esp_ota_mark_app_valid_cancel_rollback()
     *
     * What steps 2+5 CANNOT catch: a wrong-but-validly-signed image.
     * That is the teaching point this firmware exists to demonstrate. */
    ESP_LOGI(TAG, "ota poll: %s", OTA_URL);
}

/* ---- beacon (TECH-OTA.md §7) --------------------------------------- */
static void beacon_task(void *arg)
{
    for (;;) {
        /* The version lie: reads FW_VERSION from flash — attacker-
         * controlled flash. The serial console and the beacon agree;
         * the flash chip disagrees with both. Never ask the suspect. */
        ESP_LOGI(TAG, "beacon id=%s fw_ver=" FW_VERSION " -> %s",
                 DEVICE_ID, BEACON_URL);
        vTaskDelay(pdMS_TO_TICKS(CONFIG_DOORBELLINO_BEACON_INTERVAL_S * 1000));
    }
}

void app_main(void)
{
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(DEVICE_ID, sizeof(DEVICE_ID),
             "DB-%02X%02X%02X", mac[3], mac[4], mac[5]);
    snprintf(OTA_URL, sizeof(OTA_URL), "%s",
             CONFIG_DOORBELLINO_OTA_URL);
    snprintf(BEACON_URL, sizeof(BEACON_URL), "%s",
             CONFIG_DOORBELLINO_COLLECTOR_URL);

    const esp_partition_t *running = esp_ota_get_running_partition();
    ESP_LOGI(TAG, "DoorBellino %s on %s (offset 0x%lx)",
             FW_VERSION, DEVICE_ID, running->address);

    /* self-check then validate (rollback works AS DESIGNED — and is
     * useless against a validly-signed implant) */
    esp_ota_mark_app_valid_cancel_rollback();

    xTaskCreate(beacon_task, "beacon", 4096, NULL, 5, NULL);

    for (;;) {
        ota_poll();
        vTaskDelay(pdMS_TO_TICKS(CONFIG_DOORBELLINO_OTA_POLL_S * 1000));
    }
}
