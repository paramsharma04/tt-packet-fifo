# SPDX-FileCopyrightText: (c) 2026 Param Sharma
# SPDX-License-Identifier: Apache-2.0

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

# uio_in bit positions
WR_EN = 0
RD_EN = 1
SOP = 2
EOP = 3
PKT_ERR = 4

# uio_out bit positions
FULL = 5
EMPTY = 6
DROP = 7

DEPTH = 8


def ctrl(wr=0, rd=0, sop=0, eop=0, err=0):
    """Pack the control signals into a uio_in value."""
    return (
        (wr << WR_EN)
        | (rd << RD_EN)
        | (sop << SOP)
        | (eop << EOP)
        | (err << PKT_ERR)
    )


async def reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def write_word(dut, data, sop=0, eop=0, err=0):
    """Drive one word into the FIFO."""
    dut.ui_in.value = data
    dut.uio_in.value = ctrl(wr=1, sop=sop, eop=eop, err=err)
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0
    await RisingEdge(dut.clk)


async def write_packet(dut, words, err=0):
    """Drive a whole packet. err marks it bad on the final word."""
    n = len(words)
    for i, w in enumerate(words):
        await write_word(
            dut,
            w,
            sop=1 if i == 0 else 0,
            eop=1 if i == n - 1 else 0,
            err=err if i == n - 1 else 0,
        )


async def read_word(dut):
    """Pop one word and return it."""
    dut.uio_in.value = ctrl(rd=1)
    await RisingEdge(dut.clk)
    val = int(dut.uo_out.value)
    dut.uio_in.value = 0
    await RisingEdge(dut.clk)
    return val


def status(dut):
    s = int(dut.uio_out.value)
    return {
        "full": (s >> FULL) & 1,
        "empty": (s >> EMPTY) & 1,
        "drop": (s >> DROP) & 1,
    }


async def drain(dut):
    """Read everything the FIFO is willing to give."""
    out = []
    while not status(dut)["empty"]:
        out.append(await read_word(dut))
        if len(out) > 4 * DEPTH:
            raise AssertionError("FIFO never went empty - pointer bug")
    return out


@cocotb.test()
async def test_reset(dut):
    """FIFO comes out of reset empty."""
    dut._log.info("reset")
    cocotb.start_soon(Clock(dut.clk, 100, unit="ns").start())
    await reset(dut)

    assert status(dut)["empty"] == 1, "should be empty after reset"
    assert status(dut)["full"] == 0, "should not be full after reset"


@cocotb.test()
async def test_good_packet_commits(dut):
    """A clean packet becomes visible only once EOP arrives."""
    cocotb.start_soon(Clock(dut.clk, 100, unit="ns").start())
    await reset(dut)

    pkt = [0xA1, 0xA2, 0xA3]

    # partial packet must stay invisible
    await write_word(dut, pkt[0], sop=1)
    await write_word(dut, pkt[1])
    assert status(dut)["empty"] == 1, "partial packet leaked to the reader"

    await write_word(dut, pkt[2], eop=1)
    assert status(dut)["empty"] == 0, "packet not committed on EOP"

    got = await drain(dut)
    assert got == pkt, f"expected {pkt}, got {got}"


@cocotb.test()
async def test_bad_packet_dropped(dut):
    """A packet flagged bad at EOP is discarded whole."""
    cocotb.start_soon(Clock(dut.clk, 100, unit="ns").start())
    await reset(dut)

    await write_packet(dut, [0xB1, 0xB2, 0xB3], err=1)

    assert status(dut)["empty"] == 1, "bad packet was committed"
    assert status(dut)["drop"] == 1, "drop flag not raised"


@cocotb.test()
async def test_recovery_after_drop(dut):
    """A good packet after a dropped one is unaffected."""
    cocotb.start_soon(Clock(dut.clk, 100, unit="ns").start())
    await reset(dut)

    await write_packet(dut, [0xB1, 0xB2, 0xB3], err=1)
    await write_packet(dut, [0xC1, 0xC2])

    assert status(dut)["drop"] == 0, "drop flag not cleared by a good packet"
    got = await drain(dut)
    assert got == [0xC1, 0xC2], f"expected [0xC1, 0xC2], got {got}"


@cocotb.test()
async def test_single_word_packet(dut):
    """SOP and EOP on the same word."""
    cocotb.start_soon(Clock(dut.clk, 100, unit="ns").start())
    await reset(dut)

    await write_word(dut, 0xD1, sop=1, eop=1)

    assert status(dut)["empty"] == 0, "single-word packet not committed"
    got = await drain(dut)
    assert got == [0xD1], f"expected [0xD1], got {got}"


@cocotb.test()
async def test_oversized_packet_dropped(dut):
    """A packet larger than the buffer is dropped, not truncated."""
    cocotb.start_soon(Clock(dut.clk, 100, unit="ns").start())
    await reset(dut)

    await write_packet(dut, [0xE0 + i for i in range(DEPTH + 2)])

    assert status(dut)["empty"] == 1, "oversized packet was partially committed"
    assert status(dut)["drop"] == 1, "drop flag not raised on overflow"

    # and the FIFO still works afterwards
    await write_word(dut, 0xF1, sop=1, eop=1)
    got = await drain(dut)
    assert got == [0xF1], f"FIFO broken after overflow: got {got}"


@cocotb.test()
async def test_random_packets(dut):
    """Constrained-random packets checked against a reference model.

    Packets are randomly sized and randomly marked bad. The model tracks
    what a correct FIFO would expose; anything the DUT hands back must
    match, and no fragment of a dropped packet may ever appear.
    """
    cocotb.start_soon(Clock(dut.clk, 100, unit="ns").start())
    await reset(dut)

    random.seed(42)
    expected = []
    n_sent = n_dropped = 0

    for _ in range(40):
        length = random.randint(1, DEPTH + 2)
        bad = random.random() < 0.3
        words = [random.randint(0, 255) for _ in range(length)]

        await write_packet(dut, words, err=1 if bad else 0)
        n_sent += 1

        # the model: a packet survives only if it is clean and it fits
        if bad or length > DEPTH:
            n_dropped += 1
        else:
            expected = words  # committed packet is read out immediately below

        got = await drain(dut)
        want = [] if (bad or length > DEPTH) else words
        assert got == want, (
            f"len={length} bad={bad}: expected {want}, got {got}"
        )

    dut._log.info(f"{n_sent} packets sent, {n_dropped} correctly dropped")
    assert n_dropped > 0, "random seed produced no bad packets - test is weak"
 
