SIM ?= icarus
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../../src

VERILOG_SOURCES += $(PWD)/tb_controller.v
VERILOG_SOURCES += $(SRC_DIR)/ascon_round.v
VERILOG_SOURCES += $(SRC_DIR)/ascon_permutation.v
VERILOG_SOURCES += $(SRC_DIR)/cxof_controller.v

TOPLEVEL = tb_controller
MODULE   = test_controller

include $(shell cocotb-config --makefiles)/Makefile.sim
