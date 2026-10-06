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
#include "esp_mac.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_http_client.h"
#include "driver/gpio.h"
#include "nvs.h"
#include "mbedtls/md.h"
#include "mbedtls/pk.h"

static const char *TAG = "doorbellino";

#ifndef FW_VERSION
#define FW_VERSION "1.4.2"
#endif

void wifi_init_blocking(void);

/* Vendor trust anchor (SIGNING_PUB), burned at build time. The device
 * trusts exactly one key — the vendor's. That is the whole defense the
 * attack rides on: the attacker signs with the vendor's own key. */
static const char *VENDOR_PUB = CONFIG_DOORBELLINO_VENDOR_PUB;

static char OTA_URL[128];
static char BEACON_URL[128];
static char DEVICE_ID[24];

/* ---- implant gate (TECH-OTA.md §7) ---------------------------------- */
/* The implant runtime gate. HONEST firmware never beacons: app_main gates the
 * task on the flash slot at IMPLANT_SLOT. Reading the slot from the RUNNING
 * bank (not a fixed address) keeps it correct in both banks. The virtual
 * tier implements the identical gate in device.py:implant_active().
 * The status LED reads the same slot: the light pattern is visible
 * telemetry of what the RUNNING image carries. */
#define IMPLANT_MAGIC "IMPLANT|"
#define IMPLANT_SLOT  0x1E0000   /* inside the 0x1F0000 app partition */

static bool implant_active(void)
{
    const esp_partition_t *run = esp_ota_get_running_partition();
    static char probe[sizeof(IMPLANT_MAGIC) - 1];
    if (esp_partition_read(run, IMPLANT_SLOT, probe, sizeof(probe)) != ESP_OK)
        return false;
    return memcmp(probe, IMPLANT_MAGIC, sizeof(probe)) == 0;
}

/* ---- status LED: the board makes the state visible from the seats ----
 * IDLE    slow heartbeat blink (1 s on, 1 s off)   honest firmware, waiting
 * UPDATE  fast blink while downloading/applying    the OTA is happening NOW
 * IMPLANT urgent double-flash every second          poison running (in flash)
 * The implant pattern is pure telemetry of the compromise: the LED cannot
 * read the manifest, only the flash slot, so a lie on the wire stays a lie
 * on the board. GPIO from menuconfig (DOORBELLINO_LED_GPIO, default 2,
 * the onboard LED on most devkits; -1 = headless board, no blink). */
#define LED_FAST_MS  100
#define LED_HEART_MS 1000

/* Set by ota_poll while it downloads/applies; the LED task races it for at
 * most one blink period, which is fine for a demo signal. */
static volatile bool led_update_mode = false;

static void led_set(int on)
{
#if CONFIG_DOORBELLINO_LED_GPIO >= 0
    gpio_set_level(CONFIG_DOORBELLINO_LED_GPIO, on);
#else
    (void)on;
#endif
}

static void led_blink(int ms_on, int ms_off)
{
    led_set(1);  vTaskDelay(pdMS_TO_TICKS(ms_on));
    led_set(0);  vTaskDelay(pdMS_TO_TICKS(ms_off));
}

static void led_task(void *arg)
{
#if CONFIG_DOORBELLINO_LED_GPIO >= 0
    gpio_reset_pin(CONFIG_DOORBELLINO_LED_GPIO);
    gpio_set_direction(CONFIG_DOORBELLINO_LED_GPIO, GPIO_MODE_OUTPUT);
#endif
    for (;;) {
        if (led_update_mode) {
            /* fast strobe: an OTA is downloading/applying right now */
            led_blink(LED_FAST_MS, LED_FAST_MS);
        } else if (implant_active()) {
            /* urgent double-flash: the compromised heartbeat */
            led_set(1); vTaskDelay(pdMS_TO_TICKS(80));
            led_set(0); vTaskDelay(pdMS_TO_TICKS(80));
            led_set(1); vTaskDelay(pdMS_TO_TICKS(80));
            led_set(0); vTaskDelay(pdMS_TO_TICKS(760));
        } else {
            /* slow heartbeat: the honest device idles here */
            led_blink(LED_HEART_MS, LED_HEART_MS);
        }
    }
}

/* ---- beacon POST (TECH-OTA.md §7) ---------------------------------- */
static void beacon_send(void)
{
    char frame[160];
    snprintf(frame, sizeof(frame),
             "{\"id\": \"%s\", \"fw_ver\": \"" FW_VERSION "\", "
             "\"key_fpr\": \"stolen-vendor-key\"}",
             DEVICE_ID);

    esp_http_client_config_t cfg = {
        .url = BEACON_URL,
        .method = HTTP_METHOD_POST,
        .timeout_ms = 8000,
    };
    esp_http_client_handle_t hc = esp_http_client_init(&cfg);
    if (!hc) {
        ESP_LOGE(TAG, "beacon: client init failed");
        return;
    }
    esp_http_client_set_header(hc, "Content-Type", "application/json");
    esp_http_client_set_post_field(hc, frame, strlen(frame));
    esp_err_t err = esp_http_client_perform(hc);
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "beacon sent: %s", frame);
    } else {
        ESP_LOGE(TAG, "beacon failed: %s", esp_err_to_name(err));
    }
    esp_http_client_cleanup(hc);
}

/* ---- applied-version tracking (NVS 'otav' namespace) ----------------
 * The board must accept the FIRST release the OTA server offers even when
 * that version equals the USB-flashed one: a freshly flashed board runs
 * 1.4.2, the seed's first pipeline ships 1.4.2, and a strict version-gate
 * would leave the board deaf to the whole lab. So the gate compares the
 * manifest against the last version THIS BOARD APPLIED, not the compiled
 * string: first poll applies (nothing recorded yet), later polls compare
 * 'greater than' exactly as before. Same-version repushes are still
 * ignored: that is the P3 teaching beat, unchanged. */
static bool applied_version_get(char *ver, size_t n)
{
    nvs_handle_t h;
    if (nvs_open("otav", NVS_READONLY, &h) != ESP_OK) return false;
    size_t len = n;
    esp_err_t e = nvs_get_str(h, "applied", ver, &len);
    nvs_close(h);
    return e == ESP_OK;
}

static void applied_version_set(const char *ver)
{
    nvs_handle_t h;
    if (nvs_open("otav", NVS_READWRITE, &h) != ESP_OK) return;
    if (nvs_set_str(h, "applied", ver) == ESP_OK) nvs_commit(h);
    nvs_close(h);
}

/* ---- OTA poll (TECH-OTA.md §4) ------------------------------------- */
/* Fetch a manifest from <base>/<path> into buf. Returns bytes read or <=0. */
static int fetch_manifest(const char *base, const char *path,
                          char *buf, size_t n)
{
    char url[160];
    snprintf(url, sizeof(url), "%s%s", base, path);
    esp_http_client_config_t cfg = { .url = url, .timeout_ms = 8000 };
    esp_http_client_handle_t hc = esp_http_client_init(&cfg);
    if (!hc) return -1;

    memset(buf, 0, n);
    int len = 0;
    esp_http_client_set_method(hc, HTTP_METHOD_GET);
    esp_err_t err = esp_http_client_open(hc, 0);
    if (err == ESP_OK) {
        esp_http_client_fetch_headers(hc);
        len = esp_http_client_read(hc, buf, n - 1);
        esp_http_client_close(hc);
    }
    esp_http_client_cleanup(hc);
    return len;
}

static void ota_poll(void)
{
    ESP_LOGI(TAG, "ota poll: %s", OTA_URL);

    /* 1. GET /board/manifest.json (board channel, CI noise stays off it).
     * 404/no release -> fall back to the shared /manifest.json so images
     * flashed before the board channel existed keep working unchanged. */
    char manifest[512] = {0};
    int len = fetch_manifest(OTA_URL, "/board/manifest.json",
                             manifest, sizeof(manifest));
    const char *channel = "board";
    if (len <= 0 || strstr(manifest, "\"version\"") == NULL) {
        len = fetch_manifest(OTA_URL, "/manifest.json",
                             manifest, sizeof(manifest));
        channel = "shared";
    }
    if (len <= 0) {
        ESP_LOGW(TAG, "manifest fetch failed");
        return;
    }
    ESP_LOGI(TAG, "manifest [%s channel]: %.60s", channel, manifest);

    /* Extract "version" (naive but fine for the lab JSON) */
    char ver[16] = {0};
    const char *v = strstr(manifest, "\"version\": \"");
    if (!v) v = strstr(manifest, "\"version\":\"");
    if (!v) return;
    v += strlen("\"version\": \"");
    for (int i = 0; i < 15 && v[i] && v[i] != '"'; i++) ver[i] = v[i];

    /* 3. only apply versions GREATER than the last one this board
     * applied. NOTE the flaw this lab is built around: comparison by
     * version string, trust by signature. A validly-signed implant
     * passes. First poll after a USB flash: nothing recorded yet -> the
     * board takes the seed's release even at the same version number. */
    char applied[16] = {0};
    bool have_applied = applied_version_get(applied, sizeof(applied));
    if (have_applied && strcmp(ver, applied) <= 0) {
        ESP_LOGI(TAG, "no update (serving %s, applied %s)", ver, applied);
        return;
    }
    ESP_LOGI(TAG, "update available: %s%s -> downloading", ver,
             have_applied ? "" : " (first OTA: accepting seed release)");
    led_update_mode = true;

    /* 4. GET /firmware/<v>.bin onto the INACTIVE bank */
    const esp_partition_t *target = esp_ota_get_next_update_partition(NULL);
    if (!target) {
        ESP_LOGE(TAG, "no inactive bank");
        led_update_mode = false;
        return;
    }
    char url[160];
    snprintf(url, sizeof(url), "%s/firmware/%s.bin", OTA_URL, ver);

    esp_ota_handle_t oh = 0;
    if (esp_ota_begin(target, OTA_SIZE_UNKNOWN, &oh) != ESP_OK) {
        ESP_LOGE(TAG, "ota_begin failed");
        led_update_mode = false;
        return;
    }

    esp_http_client_handle_t hc = esp_http_client_init(
            &(esp_http_client_config_t){
            .url = url, .timeout_ms = 15000 });
    if (!hc) { esp_ota_abort(oh); led_update_mode = false; return; }
    esp_err_t err = esp_http_client_open(hc, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "firmware GET failed");
        esp_http_client_cleanup(hc);
        esp_ota_abort(oh);
        led_update_mode = false;
        return;
    }
    esp_http_client_fetch_headers(hc);
    static char buf[4096];
    int total = 0, n;
    while ((n = esp_http_client_read(hc, buf, sizeof(buf))) > 0) {
        if (esp_ota_write(oh, buf, n) != ESP_OK) {
            ESP_LOGE(TAG, "ota_write failed");
            esp_http_client_close(hc);
            esp_http_client_cleanup(hc);
            esp_ota_abort(oh);
            led_update_mode = false;
            return;
        }
        total += n;
    }
    esp_http_client_close(hc);
    esp_http_client_cleanup(hc);
    ESP_LOGI(TAG, "downloaded %d bytes into %s (offset 0x%lx)",
             total, target->label, (unsigned long)target->address);

    /* 5+6. sha256-vs-manifest verification is the VENDOR'S check —
     * it passes for any attacker image signed with the vendor key.
     * Flip the boot partition and restart (verify-before-apply: the
     * bootloader self-check + mark-valid path lives in app_main). */
    if (esp_ota_set_boot_partition(target) != ESP_OK) {
        ESP_LOGE(TAG, "set_boot_partition failed");
        esp_ota_abort(oh);
        led_update_mode = false;
        return;
    }
    if (esp_ota_end(oh) != ESP_OK) {
        ESP_LOGE(TAG, "ota_end failed");
        led_update_mode = false;
        return;
    }
    /* record BEFORE the reboot: after esp_restart the old app is gone,
     * and the new image must find its own version in NVS to count as
     * 'applied' (that is what the next poll compares against). */
    applied_version_set(ver);
    ESP_LOGW(TAG, "applying %s — rebooting into %s", ver, target->label);
    vTaskDelay(pdMS_TO_TICKS(1000));
    esp_restart();
}

static void beacon_task(void *arg)
{
    for (;;) {
        /* The version lie: reads FW_VERSION from flash — attacker-
         * controlled flash. The serial console and the beacon agree;
         * the flash chip disagrees with both. Never ask the suspect. */
        ESP_LOGI(TAG, "beacon id=%s fw_ver=" FW_VERSION " -> %s",
                 DEVICE_ID, BEACON_URL);
        beacon_send();
        vTaskDelay(pdMS_TO_TICKS(CONFIG_DOORBELLINO_BEACON_INTERVAL_S * 1000));
    }
}

void app_main(void)
{
    wifi_init_blocking();   /* join the lab net before anything else */

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

    /* the visible layer: heartbeat / OTA strobe / implant double-flash */
    xTaskCreate(led_task, "led", 2048, NULL, 3, NULL);

    /* The implant gate: beacon ONLY if the running image carries the flash
     * slot payload. Honest firmware stays silent — the beacon is evidence of
     * compromise, not part of the product. Same rule as the virtual tier. */
    if (implant_active()) {
        ESP_LOGW(TAG, "flash slot payload present: beacon loop armed");
        xTaskCreate(beacon_task, "beacon", 8192, NULL, 5, NULL);
    } else {
        ESP_LOGI(TAG, "flash slot clean: beacon disabled");
    }

    for (;;) {
        ota_poll();
        vTaskDelay(pdMS_TO_TICKS(CONFIG_DOORBELLINO_OTA_POLL_S * 1000));
    }
}
