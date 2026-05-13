# cocotb makefile for ASCON-CXOF testbench
# Run: make
# Then view waves: gtkwave tb.vcd

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../src

VERILOG_SOURCES += $(PWD)/tb.v
VERILOG_SOURCES += $(SRC_DIR)/project.v
VERILOG_SOURCES += $(SRC_DIR)/ascon_cxof_top.v
VERILOG_SOURCES += $(SRC_DIR)/ascon_round.v
VERILOG_SOURCES += $(SRC_DIR)/ascon_permutation.v
VERILOG_SOURCES += $(SRC_DIR)/cxof_controller.v
VERILOG_SOURCES += $(SRC_DIR)/baud_gen.v
VERILOG_SOURCES += $(SRC_DIR)/uart_rx.v
VERILOG_SOURCES += $(SRC_DIR)/uart_tx.v
VERILOG_SOURCES += $(SRC_DIR)/crc16_ccitt.v
VERILOG_SOURCES += $(SRC_DIR)/register_file.v
VERILOG_SOURCES += $(SRC_DIR)/protocol_parser.v

TOPLEVEL = tb
MODULE   = test

include $(shell cocotb-config --makefiles)/Makefile.sim
