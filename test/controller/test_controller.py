"""Test KAT vectors covering empty/short/full CS and non-empty messages."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


def bytes_to_lsb_int(data: bytes) -> int:
    result = 0
    for i, b in enumerate(data):
        result |= (b << (8 * i))
    return result


# Vectors from LWC_CXOF_KAT_128_512.txt (first 32 bytes of MD)
KATS = [
    # original 4 (empty msg, various cs)
    {"name": "Count=1: empty cs, empty msg", "cs": b"", "msg": b"",
     "expected": bytes.fromhex("4F50159EF70BB3DAD8807E034EAEBD44C4FA2CBBC8CF1F05511AB66CDCC52990")},
    {"name": "Count=2: 1B cs",  "cs": bytes([0x10]), "msg": b"",
     "expected": bytes.fromhex("0C93A483E7D574D49FE52CCE03EE646117977D57A8AA57704AB4DAF44B501430")},
    {"name": "Count=3: 2B cs",  "cs": bytes([0x10, 0x11]), "msg": b"",
     "expected": bytes.fromhex("D1106C7622E79FE955BD9D79E03B918E770FE0E0CDDDE28BEB924B02C5FC936B")},
    {"name": "Count=9: 8B cs",  "cs": bytes(range(0x10, 0x18)), "msg": b"",
     "expected": bytes.fromhex("61324766441DD6C11E1736BAD1D2185820885ED76FE2CE537775A6E855EEAFD2")},
    # non-empty msg
    {"name": "Count=100: msg=3B, cs=empty",
     "cs": b"",
     "msg": bytes([0x00, 0x01, 0x02]),
     "expected": bytes.fromhex("1093DA88C318F6D9F26E1A222DBC30016D03953EDFD9BA3D75D7D8451B9DF542")},
    {"name": "Count=50: msg=1B, cs=16B (2 full blocks)",
     "cs":  bytes(range(0x10, 0x20)),
     "msg": bytes([0x00]),
     "expected": bytes.fromhex("2B024A542F34D07360EE5FC3AC5A5ADE3F144DE1959C7BBCF2664357A47C6F12")},
    {"name": "Count=500: msg=15B (1 full + 7B final), cs=4B",
     "cs":  bytes([0x10, 0x11, 0x12, 0x13]),
     "msg": bytes(range(0x00, 0x0F)),
     "expected": bytes.fromhex("FA0E8B98F0F30CC376879268A72FF602BA483F857FCAE88F7A3E66E6289A116C")},
    {"name": "Count=1000: msg=30B, cs=9B",
     "cs":  bytes(range(0x10, 0x19)),
     "msg": bytes(range(0x00, 0x1E)),
     "expected": bytes.fromhex("D3CB03D419D215D91733CEDBB709CA48BCAD775BD5321698F5F032B2B042D904")},
]


async def run_kat(dut, kat):
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.reset_engine.value = 0
    dut.cs_data.value = 0
    dut.cs_length.value = 0
    dut.msg_data.value = 0
    dut.msg_length.value = 0
    dut.out_length.value = 0
    dut.chain_enable.value = 0
    dut.chain_count.value = 1
    await Timer(100, units="ns")
    dut.rst_n.value = 1
    await Timer(100, units="ns")

    dut.cs_data.value    = bytes_to_lsb_int(kat["cs"])
    dut.cs_length.value  = len(kat["cs"])
    dut.msg_data.value   = bytes_to_lsb_int(kat["msg"])
    dut.msg_length.value = len(kat["msg"])
    dut.out_length.value = 32
    dut.chain_enable.value = 0
    dut.chain_count.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for _ in range(100000):
        await RisingEdge(dut.clk)
        if int(dut.done.value) == 1:
            break
    else:
        raise TimeoutError("done not asserted")

    rd = int(dut.result_data.value)
    got = bytes((rd >> (8 * i)) & 0xFF for i in range(32))
    return got, kat["expected"]


@cocotb.test()
async def test_all_kats(dut):
    cocotb.start_soon(Clock(dut.clk, 20, units="ns").start())

    failures = 0
    for kat in KATS:
        got, expected = await run_kat(dut, kat)
        match = (got == expected)
        status = "PASS" if match else "FAIL"
        dut._log.info(f"{status}  {kat['name']}")
        dut._log.info(f"   got:  {got.hex().upper()}")
        dut._log.info(f"   want: {expected.hex().upper()}")
        if not match:
            failures += 1

    assert failures == 0, f"{failures} KAT(s) failed"
    dut._log.info(f"All {len(KATS)} KATs passed")
