import cocotb
from cocotb.triggers import RisingEdge, Timer


KATS = [
    {"name": "Count=1: empty cs, empty msg", "cs": b"", "msg": b"",
     "expected": bytes.fromhex("4F50159EF70BB3DAD8807E034EAEBD44C4FA2CBBC8CF1F05511AB66CDCC52990")},
    {"name": "Count=2: 1B cs", "cs": bytes([0x10]), "msg": b"",
     "expected": bytes.fromhex("0C93A483E7D574D49FE52CCE03EE646117977D57A8AA57704AB4DAF44B501430")},
    {"name": "Count=3: 2B cs", "cs": bytes([0x10, 0x11]), "msg": b"",
     "expected": bytes.fromhex("D1106C7622E79FE955BD9D79E03B918E770FE0E0CDDDE28BEB924B02C5FC936B")},
    {"name": "Count=9: 8B cs", "cs": bytes(range(0x10, 0x18)), "msg": b"",
     "expected": bytes.fromhex("61324766441DD6C11E1736BAD1D2185820885ED76FE2CE537775A6E855EEAFD2")},
    {"name": "Count=100: msg=3B, cs=empty", "cs": b"", "msg": bytes([0x00, 0x01, 0x02]),
     "expected": bytes.fromhex("1093DA88C318F6D9F26E1A222DBC30016D03953EDFD9BA3D75D7D8451B9DF542")},
    {"name": "Count=50: msg=1B, cs=16B", "cs": bytes(range(0x10, 0x20)), "msg": bytes([0x00]),
     "expected": bytes.fromhex("2B024A542F34D07360EE5FC3AC5A5ADE3F144DE1959C7BBCF2664357A47C6F12")},
    {"name": "Count=500: msg=15B, cs=4B", "cs": bytes([0x10, 0x11, 0x12, 0x13]), "msg": bytes(range(0x00, 0x0F)),
     "expected": bytes.fromhex("FA0E8B98F0F30CC376879268A72FF602BA483F857FCAE88F7A3E66E6289A116C")},
    {"name": "Count=1000: msg=30B, cs=9B", "cs": bytes(range(0x10, 0x19)), "msg": bytes(range(0x00, 0x1E)),
     "expected": bytes.fromhex("D3CB03D419D215D91733CEDBB709CA48BCAD775BD5321698F5F032B2B042D904")},
]


def pack_word_lsb(data: bytes) -> int:
    v = 0
    for i, b in enumerate(data[:8]):
        v |= b << (8 * i)
    return v


def make_words(data: bytes):
    return [pack_word_lsb(data[i:i + 8]) for i in range(0, len(data), 8)]


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.reset_engine.value = 0
    dut.cs_length.value = 0
    dut.msg_length.value = 0
    dut.out_length.value = 0
    dut.chain_enable.value = 0
    dut.chain_count.value = 1
    dut.in_word.value = 0
    dut.in_word_valid.value = 0
    dut.out_ready.value = 1
    await Timer(100, unit="ns")
    dut.rst_n.value = 1
    await Timer(100, unit="ns")


async def run_kat(dut, kat):
    await reset_dut(dut)

    cs_words = make_words(kat["cs"])
    msg_words = make_words(kat["msg"])
    cs_i = 0
    msg_i = 0
    got = bytearray()

    dut.cs_length.value = len(kat["cs"])
    dut.msg_length.value = len(kat["msg"])
    dut.out_length.value = 32
    dut.chain_enable.value = 0
    dut.chain_count.value = 1
    dut.in_word_valid.value = 0
    dut.in_word.value = 0
    dut.out_ready.value = 1

    await RisingEdge(dut.clk)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for _ in range(20000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")  # let DUT outputs settle before sampling ready/valid

        if int(dut.out_valid.value) == 1:
            got.append(int(dut.out_byte.value) & 0xFF)

        if int(dut.done.value) == 1:
            break

        # Drive at most one word for the next clock edge.
        dut.in_word_valid.value = 0

        if int(dut.in_word_ready.value) == 1:
            kind = int(dut.in_word_kind.value)

            if kind == 0:
                if cs_i >= len(cs_words):
                    raise AssertionError(
                        f"DUT requested too many CS words: cs_i={cs_i}, len={len(cs_words)}"
                    )
                dut.in_word.value = cs_words[cs_i]
                cs_i += 1
            else:
                if msg_i >= len(msg_words):
                    raise AssertionError(
                        f"DUT requested too many MSG words: msg_i={msg_i}, len={len(msg_words)}"
                    )
                dut.in_word.value = msg_words[msg_i]
                msg_i += 1

            dut.in_word_valid.value = 1
    else:
        raise TimeoutError("stream controller timeout")

    dut.in_word_valid.value = 0
    return bytes(got), kat["expected"]


@cocotb.test()
async def test_stream_all_kats(dut):
    failures = 0
    for kat in KATS:
        got, expected = await run_kat(dut, kat)
        ok = got == expected
        dut._log.info(f"{'PASS' if ok else 'FAIL'}  {kat['name']}")
        dut._log.info(f"   got:  {got.hex().upper()}")
        dut._log.info(f"   want: {expected.hex().upper()}")
        if not ok:
            failures += 1

    assert failures == 0, f"{failures} stream KAT(s) failed"
    dut._log.info(f"All {len(KATS)} stream KATs passed")
