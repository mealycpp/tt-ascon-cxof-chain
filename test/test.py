"""
cocotb testbench for ASCON-CXOF chip.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

SOF = 0xAA
EOF_BYTE = 0x55

CMD_PING        = 0x01
CMD_GET_VERSION = 0x02
CMD_WRITE_REG   = 0x10
CMD_READ_REG    = 0x11
CMD_START       = 0x30
CMD_RESET_ENG   = 0x31
CMD_GET_STATUS  = 0x40

ST_OK = 0x00

CLOCK_PERIOD_NS = 20
BAUD_DIV = 434
BIT_PERIOD_NS = CLOCK_PERIOD_NS * BAUD_DIV


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def build_frame(cmd: int, payload: bytes = b"") -> bytes:
    body = bytes([len(payload), cmd]) + payload
    crc = crc16_ccitt(body)
    return bytes([SOF]) + body + bytes([crc & 0xFF, (crc >> 8) & 0xFF, EOF_BYTE])


async def uart_send_byte(dut, byte: int):
    dut.ui_in.value = (int(dut.ui_in.value) & 0xFE)
    await Timer(BIT_PERIOD_NS, units="ns")
    for i in range(8):
        bit = (byte >> i) & 1
        dut.ui_in.value = (int(dut.ui_in.value) & 0xFE) | bit
        await Timer(BIT_PERIOD_NS, units="ns")
    dut.ui_in.value = (int(dut.ui_in.value) & 0xFE) | 1
    await Timer(BIT_PERIOD_NS, units="ns")


async def uart_send_frame(dut, frame: bytes):
    for b in frame:
        await uart_send_byte(dut, b)


async def uart_recv_byte(dut, timeout_ns=20_000_000):
    """Wait for a UART byte on tx (uo_out[0]) and return it.

    Strict falling-edge detection: explicitly wait until tx is observed HIGH,
    then wait for the next time it goes LOW. This avoids latching onto a
    start bit that's already in flight when this function is entered.
    """
    t0 = 0

    # Phase 1: ensure tx is high (line is idle)
    while True:
        tx = (int(dut.uo_out.value) >> 0) & 1
        if tx == 1:
            break
        await Timer(CLOCK_PERIOD_NS, units="ns")
        t0 += CLOCK_PERIOD_NS
        if t0 > timeout_ns:
            raise TimeoutError("uart_recv_byte: line never went high before next byte")

    # Phase 2: wait for falling edge (next start bit)
    while True:
        await Timer(CLOCK_PERIOD_NS, units="ns")
        t0 += CLOCK_PERIOD_NS
        tx = (int(dut.uo_out.value) >> 0) & 1
        if tx == 0:
            break
        if t0 > timeout_ns:
            raise TimeoutError("uart_recv_byte timeout waiting for start bit")

    # Mid-way through start bit (we polled one CLOCK_PERIOD_NS past the edge).
    # Wait one full bit period to land at the midpoint of bit 0.
    await Timer(BIT_PERIOD_NS, units="ns")
    byte = 0
    for i in range(8):
        tx = (int(dut.uo_out.value) >> 0) & 1
        byte |= (tx << i)
        await Timer(BIT_PERIOD_NS, units="ns")
    return byte


async def uart_recv_frame(dut):
    sof = await uart_recv_byte(dut)
    assert sof == SOF, f"expected SOF, got {sof:02x}"
    length = await uart_recv_byte(dut)
    status = await uart_recv_byte(dut)
    payload = bytes([await uart_recv_byte(dut) for _ in range(length - 1)])
    crc_lo = await uart_recv_byte(dut)
    crc_hi = await uart_recv_byte(dut)
    eof = await uart_recv_byte(dut)
    assert eof == EOF_BYTE, f"expected EOF, got {eof:02x}"
    expected_crc = crc16_ccitt(bytes([length, status]) + payload)
    actual_crc = crc_lo | (crc_hi << 8)
    assert expected_crc == actual_crc, f"CRC mismatch: got {actual_crc:04x}, expected {expected_crc:04x}"
    return status, payload


@cocotb.test()
async def test_ping(dut):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 1
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await Timer(200, units="ns")
    dut.rst_n.value = 1
    await Timer(200, units="ns")

    await uart_send_frame(dut, build_frame(CMD_PING))
    status, payload = await uart_recv_frame(dut)
    assert status == ST_OK
    assert payload == b""
    dut._log.info("PING passed")


@cocotb.test()
async def test_get_version(dut):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 1
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await Timer(200, units="ns")
    dut.rst_n.value = 1
    await Timer(200, units="ns")

    await uart_send_frame(dut, build_frame(CMD_GET_VERSION))
    status, payload = await uart_recv_frame(dut)
    assert status == ST_OK
    assert len(payload) == 2
    dut._log.info(f"version={payload[0]:02x} chip_id={payload[1]:02x}")
    assert payload[0] == 0x01
    assert payload[1] == 0xAC


@cocotb.test()
async def test_write_read_register(dut):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 1
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await Timer(200, units="ns")
    dut.rst_n.value = 1
    await Timer(200, units="ns")

    await uart_send_frame(dut, build_frame(CMD_WRITE_REG, bytes([0x02, 0x10])))
    status, _ = await uart_recv_frame(dut)
    assert status == ST_OK

    await uart_send_frame(dut, build_frame(CMD_READ_REG, bytes([0x02])))
    status, payload = await uart_recv_frame(dut)
    assert status == ST_OK
    assert payload[0] == 0x10
    dut._log.info("write/read register passed")


@cocotb.test()
async def test_minimal_cxof(dut):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 1
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await Timer(200, units="ns")
    dut.rst_n.value = 1
    await Timer(200, units="ns")

    await uart_send_frame(dut, build_frame(CMD_WRITE_REG, bytes([0x02, 0x00])))
    await uart_recv_frame(dut)
    await uart_send_frame(dut, build_frame(CMD_WRITE_REG, bytes([0x03, 0x04])))
    await uart_recv_frame(dut)
    await uart_send_frame(dut, build_frame(CMD_WRITE_REG, bytes([0x04, 0x10])))
    await uart_recv_frame(dut)
    await uart_send_frame(dut, build_frame(CMD_WRITE_REG, bytes([0x05, 0x00])))
    await uart_recv_frame(dut)
    for i, b in enumerate(b"abcd"):
        await uart_send_frame(dut, build_frame(CMD_WRITE_REG, bytes([0x30 + i, b])))
        await uart_recv_frame(dut)

    await uart_send_frame(dut, build_frame(CMD_START))
    await uart_recv_frame(dut)

    for _ in range(2000):
        await uart_send_frame(dut, build_frame(CMD_GET_STATUS))
        status, payload = await uart_recv_frame(dut)
        if payload[0] & 0x01:
            dut._log.info(f"engine done; status byte = {payload[0]:02x}")
            return
    raise TimeoutError("engine never set done bit")
