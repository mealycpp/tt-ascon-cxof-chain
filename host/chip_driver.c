/*
 * Host driver implementation for ASCON-CXOF chip.
 * Linux serial-port based; compatible with PYNQ, laptop USB-UART, embedded Linux.
 */

#define _DEFAULT_SOURCE   /* expose usleep() from <unistd.h> under -std=c11 */

#include "chip_driver.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <errno.h>
#include <sys/select.h>

#define SOF      0xAA
#define EOF_BYTE 0x55
#define MAX_PAYLOAD 64

/* ===== CRC16-CCITT (must match RTL) ===== */
static uint16_t crc16_ccitt(const uint8_t *data, size_t len)
{
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= ((uint16_t)data[i]) << 8;
        for (int j = 0; j < 8; j++) {
            if (crc & 0x8000)
                crc = (crc << 1) ^ 0x1021;
            else
                crc <<= 1;
        }
    }
    return crc;
}

/* ===== Low-level serial I/O ===== */

static int set_baud(int fd, int baud)
{
    struct termios tio;
    if (tcgetattr(fd, &tio) != 0) return -1;
    speed_t s;
    switch (baud) {
        case 9600:    s = B9600;    break;
        case 19200:   s = B19200;   break;
        case 38400:   s = B38400;   break;
        case 57600:   s = B57600;   break;
        case 115200:  s = B115200;  break;
        case 230400:  s = B230400;  break;
        case 460800:  s = B460800;  break;
        case 921600:  s = B921600;  break;
        default: return -1;
    }
    cfsetispeed(&tio, s);
    cfsetospeed(&tio, s);
    /* 8N1, raw */
    tio.c_cflag &= ~(PARENB | CSTOPB | CSIZE);
    tio.c_cflag |= CS8 | CLOCAL | CREAD;
    tio.c_iflag = 0;
    tio.c_oflag = 0;
    tio.c_lflag = 0;
    tio.c_cc[VMIN]  = 0;
    tio.c_cc[VTIME] = 0;
    return tcsetattr(fd, TCSANOW, &tio);
}

static int read_byte_timeout(int fd, uint8_t *byte, int timeout_ms)
{
    fd_set rfds;
    struct timeval tv;
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    tv.tv_sec  = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    int r = select(fd + 1, &rfds, NULL, NULL, &tv);
    if (r <= 0) return CHIP_ERR_TIMEOUT;
    if (read(fd, byte, 1) != 1) return CHIP_ERR_READ;
    return 0;
}

/* ===== Framing ===== */

static int send_frame(chip_t *chip, uint8_t cmd, const uint8_t *payload, size_t payload_len)
{
    if (payload_len > MAX_PAYLOAD) return CHIP_ERR_WRITE;
    uint8_t buf[4 + MAX_PAYLOAD];
    buf[0] = SOF;
    buf[1] = (uint8_t)payload_len;
    buf[2] = cmd;
    if (payload_len > 0 && payload != NULL) {
        memcpy(buf + 3, payload, payload_len);
    }
    uint16_t crc = crc16_ccitt(buf + 1, payload_len + 2);  /* over LEN + CMD + payload */
    buf[3 + payload_len + 0] = crc & 0xFF;
    buf[3 + payload_len + 1] = (crc >> 8) & 0xFF;
    buf[3 + payload_len + 2] = EOF_BYTE;
    size_t total = 6 + payload_len;
    ssize_t w = write(chip->fd, buf, total);
    if (w != (ssize_t)total) return CHIP_ERR_WRITE;
    return 0;
}

static int recv_frame(chip_t *chip, uint8_t *status_out, uint8_t *payload_out, size_t *payload_len_out)
{
    uint8_t b;
    int r;

    /* SOF */
    do {
        r = read_byte_timeout(chip->fd, &b, 1000);
        if (r != 0) return r;
    } while (b != SOF);

    /* LEN */
    r = read_byte_timeout(chip->fd, &b, 100); if (r) return r;
    uint8_t len = b;
    if (len < 1 || len > MAX_PAYLOAD + 1) return CHIP_ERR_BAD_FRAME;

    /* STATUS */
    r = read_byte_timeout(chip->fd, &b, 100); if (r) return r;
    uint8_t status = b;

    /* PAYLOAD */
    size_t payload_n = len - 1;
    uint8_t payload[MAX_PAYLOAD];
    for (size_t i = 0; i < payload_n; i++) {
        r = read_byte_timeout(chip->fd, &payload[i], 100); if (r) return r;
    }

    /* CRC LO/HI */
    uint8_t crc_lo, crc_hi;
    r = read_byte_timeout(chip->fd, &crc_lo, 100); if (r) return r;
    r = read_byte_timeout(chip->fd, &crc_hi, 100); if (r) return r;

    /* EOF */
    r = read_byte_timeout(chip->fd, &b, 100); if (r) return r;
    if (b != EOF_BYTE) return CHIP_ERR_BAD_FRAME;

    /* verify CRC over LEN + STATUS + PAYLOAD */
    uint8_t crc_input[2 + MAX_PAYLOAD];
    crc_input[0] = len;
    crc_input[1] = status;
    memcpy(crc_input + 2, payload, payload_n);
    uint16_t expected = crc16_ccitt(crc_input, 2 + payload_n);
    uint16_t got = crc_lo | ((uint16_t)crc_hi << 8);
    if (expected != got) return CHIP_ERR_BAD_CRC;

    *status_out = status;
    if (payload_out && payload_n > 0) memcpy(payload_out, payload, payload_n);
    if (payload_len_out) *payload_len_out = payload_n;
    return 0;
}

/* ===== Public API ===== */

int chip_open(chip_t *chip, const char *device, int baud)
{
    chip->fd = open(device, O_RDWR | O_NOCTTY);
    if (chip->fd < 0) return CHIP_ERR_OPEN;
    if (set_baud(chip->fd, baud) != 0) {
        close(chip->fd);
        chip->fd = -1;
        return CHIP_ERR_OPEN;
    }
    /* flush any stale bytes */
    tcflush(chip->fd, TCIOFLUSH);
    return 0;
}

void chip_close(chip_t *chip)
{
    if (chip->fd >= 0) close(chip->fd);
    chip->fd = -1;
}

int chip_ping(chip_t *chip)
{
    int r = send_frame(chip, CHIP_CMD_PING, NULL, 0);
    if (r) return r;
    uint8_t status, payload[MAX_PAYLOAD];
    size_t plen;
    r = recv_frame(chip, &status, payload, &plen);
    if (r) return r;
    if (status != CHIP_ST_OK) return CHIP_ERR_STATUS;
    return 0;
}

int chip_get_version(chip_t *chip, uint8_t *version, uint8_t *chip_id)
{
    int r = send_frame(chip, CHIP_CMD_GET_VERSION, NULL, 0);
    if (r) return r;
    uint8_t status, payload[MAX_PAYLOAD];
    size_t plen;
    r = recv_frame(chip, &status, payload, &plen);
    if (r) return r;
    if (status != CHIP_ST_OK || plen != 2) return CHIP_ERR_STATUS;
    if (version) *version = payload[0];
    if (chip_id) *chip_id = payload[1];
    return 0;
}

int chip_write_reg(chip_t *chip, uint8_t addr, uint8_t value)
{
    uint8_t p[2] = {addr, value};
    int r = send_frame(chip, CHIP_CMD_WRITE_REG, p, 2);
    if (r) return r;
    uint8_t status, payload[MAX_PAYLOAD];
    size_t plen;
    r = recv_frame(chip, &status, payload, &plen);
    if (r) return r;
    if (status != CHIP_ST_OK) return CHIP_ERR_STATUS;
    return 0;
}

int chip_read_reg(chip_t *chip, uint8_t addr, uint8_t *value)
{
    int r = send_frame(chip, CHIP_CMD_READ_REG, &addr, 1);
    if (r) return r;
    uint8_t status, payload[MAX_PAYLOAD];
    size_t plen;
    r = recv_frame(chip, &status, payload, &plen);
    if (r) return r;
    if (status != CHIP_ST_OK || plen < 1) return CHIP_ERR_STATUS;
    *value = payload[0];
    return 0;
}

int chip_get_status(chip_t *chip, uint8_t *status_out)
{
    int r = send_frame(chip, CHIP_CMD_GET_STATUS, NULL, 0);
    if (r) return r;
    uint8_t status, payload[MAX_PAYLOAD];
    size_t plen;
    r = recv_frame(chip, &status, payload, &plen);
    if (r) return r;
    if (status != CHIP_ST_OK || plen < 1) return CHIP_ERR_STATUS;
    *status_out = payload[0];
    return 0;
}

int chip_compute(chip_t *chip,
                 const uint8_t *cs, size_t cs_len,
                 const uint8_t *msg, size_t msg_len,
                 uint8_t *output, size_t out_len)
{
    int r;
    if (cs_len > 32 || msg_len > 32 || out_len > 32)
        return CHIP_ERR_WRITE;

    /* set CS_LENGTH, MSG_LENGTH, OUT_LENGTH */
    r = chip_write_reg(chip, 0x02, (uint8_t)cs_len);    if (r) return r;
    r = chip_write_reg(chip, 0x03, (uint8_t)msg_len);   if (r) return r;
    r = chip_write_reg(chip, 0x04, (uint8_t)(out_len & 0xFF)); if (r) return r;
    r = chip_write_reg(chip, 0x05, (uint8_t)((out_len >> 8) & 0xFF)); if (r) return r;

    /* load CS bytes at 0x10..0x2F */
    for (size_t i = 0; i < cs_len; i++) {
        r = chip_write_reg(chip, 0x10 + i, cs[i]); if (r) return r;
    }
    /* load MSG bytes at 0x30..0x4F */
    for (size_t i = 0; i < msg_len; i++) {
        r = chip_write_reg(chip, 0x30 + i, msg[i]); if (r) return r;
    }

    /* START */
    r = send_frame(chip, CHIP_CMD_START, NULL, 0); if (r) return r;
    uint8_t status, payload[MAX_PAYLOAD];
    size_t plen;
    r = recv_frame(chip, &status, payload, &plen);
    if (r) return r;
    if (status != CHIP_ST_OK) return CHIP_ERR_STATUS;

    /* poll status until done (bit 0). Timeout after ~1000 polls. */
    for (int i = 0; i < 1000; i++) {
        uint8_t s;
        r = chip_get_status(chip, &s); if (r) return r;
        if (s & 0x01) break;
        usleep(1000);  /* 1 ms between polls */
        if (i == 999) return CHIP_ERR_TIMEOUT;
    }

    /* read out_len bytes from result region 0x50..0x6F */
    for (size_t i = 0; i < out_len; i++) {
        r = chip_read_reg(chip, 0x50 + i, &output[i]); if (r) return r;
    }
    return 0;
}
