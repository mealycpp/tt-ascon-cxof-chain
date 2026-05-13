# Host-side C driver and test program for ASCON-CXOF chip.
# Builds on any Linux box (PYNQ, laptop, embedded Linux).

CC      ?= gcc
CFLAGS  := -O2 -Wall -Wextra -std=c11
LDFLAGS :=

all: test_chain

test_chain: test_chain.o chip_driver.o
	$(CC) -o $@ $^ $(LDFLAGS)

%.o: %.c chip_driver.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o test_chain

.PHONY: all clean
