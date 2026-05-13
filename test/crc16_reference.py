"""
Golden reference for CRC16-CCITT.

Used to validate that the chip's CRC implementation matches the host's.
If these two disagree, the protocol cannot function.

This is also the byte-level reference for constructing test frames.
"""


def crc16_ccitt(data: bytes) -> int:
    """CRC16-CCITT: poly=0x1021, init=0xFFFF, no reflect, no xorout.

    Verified test vectors:
        crc16_ccitt(b'') = 0xFFFF
        crc16_ccitt(b'A') = 0xB915
        crc16_ccitt(b'123456789') = 0x29B1
    """
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


if __name__ == "__main__":
    # Sanity checks
    assert crc16_ccitt(b'') == 0xFFFF, "empty case"
    assert crc16_ccitt(b'A') == 0xB915, "single byte"
    assert crc16_ccitt(b'123456789') == 0x29B1, "standard test vector"
    print("CRC16-CCITT reference: all sanity checks pass")
    print(f"  empty       -> 0x{crc16_ccitt(b''):04X}")
    print(f"  'A'         -> 0x{crc16_ccitt(b'A'):04X}")
    print(f"  '123456789' -> 0x{crc16_ccitt(b'123456789'):04X}")
