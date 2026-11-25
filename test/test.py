# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    dut._log.info("Reset")

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0

    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    dut._log.info("Test project behavior")

    dut.ui_in.value = 0b00000100  # Lanzar/reiniciar
    await ClockCycles(dut.clk, 2)

    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 20)

    output = dut.uo_out.value
    dut._log.info(f"uo_out = 0b{int(output):08b}")

    assert output.is_resolvable
    assert len(output) == 8
