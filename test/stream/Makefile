SIM ?= icarus
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../../src

VERILOG_SOURCES += $(PWD)/tb_stream.v
VERILOG_SOURCES += $(SRC_DIR)/ascon_round.v
VERILOG_SOURCES += $(SRC_DIR)/ascon_permutation.v
VERILOG_SOURCES += $(SRC_DIR)/cxof_stream_controller.v

TOPLEVEL = tb_stream
MODULE   = test_stream

include $(shell cocotb-config --makefiles)/Makefile.sim
