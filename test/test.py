"""ASCON-CXOF tests, robust UART recv via prolonged-idle wait."""

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


def _tx(dut):
    return int(dut.uo_out.value) & 1


async def _wait_extended_idle(dut, idle_clocks=5):
    """Wait until tx has been HIGH for `idle_clocks` consecutive cycles."""
    high_streak = 0
    for _ in range(2_000_000):
        await Timer(CLOCK_PERIOD_NS, units="ns")
        if _tx(dut) == 1:
            high_streak += 1
            if high_streak >= idle_clocks:
                return
        else:
            high_streak = 0
    raise TimeoutError("tx never sustained idle high")


async def uart_recv_byte(dut, wait_idle_first=True):
    """Receive one UART byte.

    If wait_idle_first is True, first ensure tx has been idle high for a few
    clocks (covers the case where we just finished sending and the chip is
    about to start responding).  Then poll for falling edge.  Then sample
    mid-bit for each of 8 data bits.
    """
    if wait_idle_first:
        # Brief idle check; if tx is already low (chip already responding)
        # this returns quickly via the timeout, then we still catch the edge.
        try:
            await _wait_extended_idle(dut, idle_clocks=3)
        except TimeoutError:
            pass

    # Poll for falling edge
    for _ in range(2_000_000):
        await Timer(CLOCK_PERIOD_NS, units="ns")
        if _tx(dut) == 0:
            break
    else:
        raise TimeoutError("no falling edge")

    # We may have detected the falling edge up to CLOCK_PERIOD_NS late.
    # Wait one full bit period to reach mid-bit-0.
    await Timer(BIT_PERIOD_NS, units="ns")
    byte = 0
    for i in range(8):
        byte |= (_tx(dut) << i)
        if i < 7:
            await Timer(BIT_PERIOD_NS, units="ns")
    return byte


async def uart_recv_frame(dut):
    sof = await uart_recv_byte(dut, wait_idle_first=True)
    assert sof == SOF, f"expected SOF, got {sof:02x}"
    # subsequent bytes follow immediately, no extended idle between them
    length = await uart_recv_byte(dut, wait_idle_first=False)
    status = await uart_recv_byte(dut, wait_idle_first=False)
    payload = bytes([await uart_recv_byte(dut, wait_idle_first=False)
                     for _ in range(length - 1)])
    crc_lo = await uart_recv_byte(dut, wait_idle_first=False)
    crc_hi = await uart_recv_byte(dut, wait_idle_first=False)
    eof = await uart_recv_byte(dut, wait_idle_first=False)
    assert eof == EOF_BYTE, f"expected EOF, got {eof:02x}"
    expected_crc = crc16_ccitt(bytes([length, status]) + payload)
    actual_crc = crc_lo | (crc_hi << 8)
    assert expected_crc == actual_crc, f"CRC mismatch"
    return status, payload


async def _setup(dut):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, units="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 1
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await Timer(200, units="ns")
    dut.rst_n.value = 1
    await Timer(200, units="ns")


@cocotb.test()
async def test_ping(dut):
    await _setup(dut)
    await uart_send_frame(dut, build_frame(CMD_PING))
    status, payload = await uart_recv_frame(dut)
    assert status == ST_OK
    assert payload == b""
