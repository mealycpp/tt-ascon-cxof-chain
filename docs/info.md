# ASCON-CXOF Hash Chain Accelerator

## What this chip does

This is a hardware accelerator for **ASCON-CXOF**, the Customizable Extendable
Output Function standardized in NIST SP 800-232 (August 2025). ASCON is a
lightweight cryptographic permutation designed for constrained devices.

The chip is intended as a **security peripheral for post-quantum cryptographic
workloads** on embedded systems, particularly flight controllers and edge
devices. ASCON-CXOF is a building block for hash-based PQC signature schemes
like SLH-DSA, LMS, and XMSS, where Merkle tree traversal and WOTS+ chains
require repeated hashing.

## How to test it

The chip speaks a simple UART-based protocol at 115200 baud, 8-N-1. Connect
a host (PYNQ-Z2, USB-UART adapter, microcontroller) to the chip's UART pins
and send framed commands.

**Frame format (host → chip):**
```
[0xAA][LEN][CMD][PAYLOAD...][CRC_LO][CRC_HI][0x55]
```

**Frame format (chip → host):**
```
[0xAA][LEN][STATUS][PAYLOAD...][CRC_LO][CRC_HI][0x55]
```

CRC is CRC16-CCITT (poly 0x1021, init 0xFFFF) computed over LEN+CMD+PAYLOAD.

**Quick start:**
1. Send `[0xAA][0x00][0x01][CRC_LO][CRC_HI][0x55]` (PING) to verify chip is alive.
2. Configure CS_LENGTH, MSG_LENGTH, OUT_LENGTH registers (addresses 0x02-0x05).
3. Load customization string at addresses 0x10-0x2F (32 bytes).
4. Load message at addresses 0x30-0x4F (32 bytes).
5. Send START command (0x30).
6. Poll STATUS until done bit set.
7. Read 32-byte result from addresses 0x50-0x6F.

A complete C reference driver is provided in the `host/` directory of the
project repository.

## External hardware

- UART connection at 115200 baud, 8-N-1 (TX/RX pins)
- 3.3V logic levels (Tiny Tapeout standard)
- 25 MHz clock (or whatever the demo board provides; chip uses Tiny Tapeout's
  default clock)

## Pin assignments

**Inputs (ui_in):**
- ui[0]: UART RX (data from host)
- ui[1]: External clock enable (currently unused — reserved for future)
- ui[2]: External clock input (currently unused — reserved for future)

**Outputs (uo_out):**
- uo[0]: UART TX (data to host)
- uo[1]: Done IRQ (high when result ready)
- uo[2]: Busy (high during computation)
- uo[3]: Error (protocol or CRC error)
- uo[4-5]: FSM state debug bits
- uo[6]: Heartbeat (~3 Hz blinky for visible activity)
- uo[7]: RX active (high during UART frame reception)

## Limitations

- Maximum customization string length: 32 bytes
- Maximum message length: 32 bytes
- Maximum output length: 32 bytes
- ASCON-CXOF128 parameters only (not the larger CXOF256 variant)

These limits keep the design within 3 tiles. Future shuttles may expand them.

## What's next (post-tape-out roadmap)

- KAT validation against NIST reference vectors
- Side-channel evaluation using ChipWhisperer
- Custom PMOD-form-factor PCB for PYNQ-Z2 integration
- Future ASCON-Hash and Haraka variants on subsequent shuttles
