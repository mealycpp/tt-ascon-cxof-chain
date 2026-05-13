/*
 * test_chain.c — simple host-side test for the ASCON-CXOF chip.
 *
 * Usage:
 *     ./test_chain /dev/ttyUSB0
 *
 * Runs a ping, gets version, performs one CXOF computation, prints output.
 */

#include "chip_driver.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void print_hex(const char *label, const uint8_t *data, size_t len)
{
    printf("%s (%zu bytes): ", label, len);
    for (size_t i = 0; i < len; i++) printf("%02x", data[i]);
    printf("\n");
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <serial-device> [baud]\n", argv[0]);
        return 1;
    }
    const char *dev = argv[1];
    int baud = (argc >= 3) ? atoi(argv[2]) : 115200;

    chip_t chip;
    if (chip_open(&chip, dev, baud) != 0) {
        fprintf(stderr, "failed to open %s\n", dev);
        return 1;
    }
    printf("opened %s at %d baud\n", dev, baud);

    /* PING */
    if (chip_ping(&chip) != 0) { fprintf(stderr, "PING failed\n"); chip_close(&chip); return 1; }
    printf("PING OK\n");

    /* VERSION */
    uint8_t ver, cid;
    if (chip_get_version(&chip, &ver, &cid) != 0) { fprintf(stderr, "GET_VERSION failed\n"); chip_close(&chip); return 1; }
    printf("version=0x%02x chip_id=0x%02x\n", ver, cid);

    /* Run a CXOF computation */
    uint8_t cs[]  = "demo";
    uint8_t msg[] = "hello world";
    uint8_t out[32];
    memset(out, 0, sizeof(out));

    print_hex("CS", cs, sizeof(cs) - 1);
    print_hex("MSG", msg, sizeof(msg) - 1);

    int r = chip_compute(&chip, cs, sizeof(cs) - 1, msg, sizeof(msg) - 1, out, 16);
    if (r != 0) {
        fprintf(stderr, "chip_compute failed: %d\n", r);
        chip_close(&chip);
        return 1;
    }
    print_hex("OUT", out, 16);

    chip_close(&chip);
    return 0;
}
