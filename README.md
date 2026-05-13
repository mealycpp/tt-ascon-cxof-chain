# tt_um_ascon_cxof

**ASCON-CXOF hash chain accelerator** for Tiny Tapeout SKY130 shuttle.
ChipFoundry CI2605 MPW.

Implements **NIST SP 800-232 ASCON-CXOF128** as a hardware accelerator with
a UART-framed protocol. Designed as a security peripheral for post-quantum
cryptographic workloads on flight controllers and embedded systems.

## Repository layout

```
.
├── info.yaml                # Tiny Tapeout metadata + pinout
├── README.md                # this file
├── docs/info.md             # chip description rendered by Tiny Tapeout
├── src/                     # RTL — what gets synthesized to silicon
│   ├── project.v            # Tiny Tapeout wrapper (tt_um_ascon_cxof)
│   ├── ascon_cxof_top.v     # main top — wires subblocks together
│   ├── ascon_round.v        # single ASCON-p round (combinational)
│   ├── ascon_permutation.v  # multi-round permutation engine
│   ├── cxof_controller.v    # CXOF mode FSM (init/absorb/squeeze)
│   ├── uart_rx.v            # UART receiver, 16x oversampling
│   ├── uart_tx.v            # UART transmitter
│   ├── baud_gen.v           # baud-rate tick generator
│   ├── crc16_ccitt.v        # CRC16-CCITT for protocol integrity
│   ├── register_file.v      # register bank exposed to host
│   └── protocol_parser.v    # UART framing FSM
├── test/                    # verification — cocotb + Icarus Verilog
│   ├── tb.v                 # testbench top
│   ├── test.py              # cocotb tests
│   ├── Makefile             # build rules
│   └── README.md
└── host/                    # C driver for host-side communication
    ├── chip_driver.h
    ├── chip_driver.c
    ├── test_chain.c
    └── Makefile
```

## How to build

The GitHub Action (`.github/workflows/`) automatically runs LibreLane and
produces a GDS when you push to this repo. That's the ground truth.

For local simulation:
```bash
cd test
make
```

For host driver (when silicon arrives):
```bash
cd host
make
./test_chain /dev/ttyUSB0
```

## Status

Initial submission for Tiny Tapeout SKY 26a (ChipFoundry shuttle).

## License

Apache 2.0
