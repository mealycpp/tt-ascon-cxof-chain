# Testbench

Cocotb + Icarus Verilog. This is what the Tiny Tapeout CI runs and what you
run locally for fast iteration.

## Setup

```bash
sudo apt install iverilog gtkwave
pip3 install cocotb pytest
```

## Run

```bash
cd test
make
```

This builds the simulation, runs all tests in `test.py`, and writes `tb.vcd`.

## View waveforms

```bash
gtkwave tb.vcd
```

## Tests in test.py

- `test_ping`: chip responds to PING command (sanity check)
- `test_get_version`: chip returns version byte and chip ID
- `test_write_read_register`: write a register, read it back
- `test_minimal_cxof`: load a small input, START the CXOF engine, poll until done

## What's NOT tested yet (TODO before silicon)

- **KAT validation against the NIST SP 800-232 reference vectors.** The CXOF
  output must match the reference Python implementation. The current chip
  uses placeholder values for the IV and domain separator that need to be
  verified against the spec. See `golden/` for the reference.

- **Edge cases**: cs_length=0 with msg_length>0, msg_length=0 with cs_length>0,
  out_length > 32 (should saturate at 32 in this implementation), padding
  edge cases when message is exact multiple of 8 bytes.

- **Protocol robustness**: malformed frames, CRC errors, unknown commands,
  oversized payloads — all should return error status without locking up.

For tomorrow's tape-out, the priority order is:
1. `test_ping` and `test_write_read_register` must pass (basic protocol)
2. `test_minimal_cxof` must not lock up (engine completes)
3. KAT validation can be deferred to a future shuttle if needed —
   first silicon proves the architecture; second silicon fixes any
   crypto-correctness bugs found in post-silicon testing.

## Debugging tips

If a test hangs, the most likely cause is:
- UART baud divisor mismatch (check BAUD_DIV in info.yaml, ascon_cxof_top.v,
  and test.py all agree)
- CRC mismatch between RTL and Python reference (test_crc16_ccitt.py can
  cross-check)
- FSM stuck in a state — open tb.vcd in GTKWave and trace the FSM signals
