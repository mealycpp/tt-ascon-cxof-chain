/*
 * Host C driver for ASCON-CXOF chip.
 *
 * Talks over UART (serial port) using the protocol defined in
 * src/protocol_parser.v.
 *
 * Usage on PYNQ-Z2 or any Linux host with a serial port:
 *
 *     #include "chip_driver.h"
 *     chip_t chip;
 *     chip_open(&chip, "/dev/ttyUSB0", 115200);
 *     chip_ping(&chip);
 *     chip_compute(&chip, cs, cs_len, msg, msg_len, output, out_len);
 *     chip_close(&chip);
 */

#ifndef ASCON_CHIP_DRIVER_H
#define ASCON_CHIP_DRIVER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int fd;
} chip_t;

/* Protocol command codes - must match RTL */
#define CHIP_CMD_PING        0x01
#define CHIP_CMD_GET_VERSION 0x02
#define CHIP_CMD_WRITE_REG   0x10
#define CHIP_CMD_READ_REG    0x11
#define CHIP_CMD_START       0x30
#define CHIP_CMD_RESET_ENG   0x31
#define CHIP_CMD_GET_STATUS  0x40

/* Status codes returned by the chip */
#define CHIP_ST_OK           0x00
#define CHIP_ST_BAD_CRC      0x01
#define CHIP_ST_BAD_FRAME    0x02
#define CHIP_ST_BAD_CMD      0x03
#define CHIP_ST_BUSY         0x04
#define CHIP_ST_ENGINE_ERR   0x05

/* Driver error codes (negative for failure) */
#define CHIP_ERR_OPEN      -1
#define CHIP_ERR_WRITE     -2
#define CHIP_ERR_READ      -3
#define CHIP_ERR_TIMEOUT   -4
#define CHIP_ERR_BAD_FRAME -5
#define CHIP_ERR_BAD_CRC   -6
#define CHIP_ERR_STATUS    -7

/* Open serial port at given baud rate (typically 115200). */
int chip_open(chip_t *chip, const char *device, int baud);

/* Close serial port. */
void chip_close(chip_t *chip);

/* Send PING, expect OK reply. Returns 0 on success. */
int chip_ping(chip_t *chip);

/* Read version and chip ID. */
int chip_get_version(chip_t *chip, uint8_t *version, uint8_t *chip_id);

/* Write one byte to a register address. */
int chip_write_reg(chip_t *chip, uint8_t addr, uint8_t value);

/* Read one byte from a register address. */
int chip_read_reg(chip_t *chip, uint8_t addr, uint8_t *value);

/* Get status byte. bit0=done, bit1=busy, bit2=error, bit3=result_valid. */
int chip_get_status(chip_t *chip, uint8_t *status);

/* High-level: run an ASCON-CXOF computation.
 *   cs:        customization string (max 32 bytes; pass NULL if cs_len = 0)
 *   cs_len:    bytes in cs
 *   msg:       message input (max 32 bytes; pass NULL if msg_len = 0)
 *   msg_len:   bytes in msg
 *   output:    buffer to receive the output
 *   out_len:   requested output length (max 32 in this implementation)
 * Returns 0 on success, negative on error.
 */
int chip_compute(chip_t *chip,
                 const uint8_t *cs, size_t cs_len,
                 const uint8_t *msg, size_t msg_len,
                 uint8_t *output, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif /* ASCON_CHIP_DRIVER_H */
