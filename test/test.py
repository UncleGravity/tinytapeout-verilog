"""
Cocotb test for Tiny Tapeout MNIST Wrapper

Tests the complete wrapper with parallel streaming protocol (Option B):
- Loads 4 pixels per cycle (16 cycles total)
- Verifies inference completes correctly
- Checks timing (~3,940 cycles)
"""

from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

# Path to test vectors
VECTOR_DIR = Path(__file__).parent / "test_vectors" / "vectors"


def load_test_vector(test_idx):
    """Load a test vector (just pixels and expected output)."""
    # Load input pixels
    input_file = VECTOR_DIR / f"test_{test_idx:03d}_input.txt"
    pixels = []
    with open(input_file, "r") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                pixels.append(int(line))
    assert len(pixels) == 64, f"Expected 64 pixels, got {len(pixels)}"

    # Load expected output
    output_file = VECTOR_DIR / f"test_{test_idx:03d}_output.txt"
    with open(output_file, "r") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                expected = int(line)
                break

    # Load metadata
    metadata_file = VECTOR_DIR / f"test_{test_idx:03d}_metadata.txt"
    metadata = {}
    with open(metadata_file, "r") as f:
        for line in f:
            line = line.strip()
            if ":" in line:
                key, value = line.split(":", 1)
                metadata[key.strip()] = value.strip()

    return pixels, expected, metadata


async def stream_pixels_parallel(dut, pixels):
    """
    Stream 64 pixels using parallel protocol (4 pixels per cycle).

    Args:
        dut: Device under test
        pixels: List of 64 pixel values (2-bit each, 0-3)

    Returns:
        Number of cycles used for streaming
    """
    assert len(pixels) == 64, "Must provide exactly 64 pixels"

    cycles = 0

    # Stream 16 cycles of 4 pixels each
    for i in range(16):
        # Pack 4 pixels into ui_in[7:0]
        pixel_0 = pixels[i * 4 + 0]
        pixel_1 = pixels[i * 4 + 1]
        pixel_2 = pixels[i * 4 + 2]
        pixel_3 = pixels[i * 4 + 3]

        ui_in_value = (pixel_3 << 6) | (pixel_2 << 4) | (pixel_1 << 2) | pixel_0
        dut.ui_in.value = ui_in_value

        await RisingEdge(dut.clk)
        cycles += 1

    return cycles


@cocotb.test()
async def test_wrapper_single_inference(dut):
    """Test wrapper with a single inference (detailed logging)."""

    dut._log.info("=" * 80)
    dut._log.info("TT Wrapper - Single Inference Test (Parallel Streaming)")
    dut._log.info("=" * 80)

    # Start clock
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    # Load test vector
    pixels, expected, metadata = load_test_vector(0)

    dut._log.info(f"Test Vector: 0")
    dut._log.info(f"True Label: {metadata.get('True label', '?')}")
    dut._log.info(f"Expected Prediction: {expected}")

    # Reset
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 2)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    cycle_count = 0

    # Set first 4 pixels on ui_in BEFORE asserting start
    pixel_0 = pixels[0]
    pixel_1 = pixels[1]
    pixel_2 = pixels[2]
    pixel_3 = pixels[3]
    ui_in_value = (pixel_3 << 6) | (pixel_2 << 4) | (pixel_1 << 2) | pixel_0
    dut.ui_in.value = ui_in_value

    # Assert start signal (pixels stay on ui_in)
    dut._log.info("Starting inference (asserting start with first pixels ready)...")
    dut.uio_in.value = 0x01  # start = 1
    await RisingEdge(dut.clk)
    cycle_count += 1

    # MNIST enters LOAD_PIXELS this cycle and will latch first 4 pixels
    # DON'T change ui_in yet - MNIST needs another cycle to read them
    await RisingEdge(dut.clk)
    cycle_count += 1

    # Now stream remaining pixels (15 more cycles, 4 pixels each)
    dut._log.info("Streaming remaining 60 pixels (15 cycles, 4 pixels/cycle)...")
    for i in range(1, 16):
        pixel_0 = pixels[i * 4 + 0]
        pixel_1 = pixels[i * 4 + 1]
        pixel_2 = pixels[i * 4 + 2]
        pixel_3 = pixels[i * 4 + 3]
        ui_in_value = (pixel_3 << 6) | (pixel_2 << 4) | (pixel_1 << 2) | pixel_0
        dut.ui_in.value = ui_in_value
        await RisingEdge(dut.clk)
        cycle_count += 1

    # Wait for done signal
    dut._log.info("Waiting for computation to complete...")
    max_cycles = 5000
    while dut.uo_out.value[4] != 1 and cycle_count < max_cycles:  # Check done bit
        await RisingEdge(dut.clk)
        cycle_count += 1

        if cycle_count % 500 == 0:
            dut._log.info(f"  Cycle {cycle_count}: Still computing...")

    if cycle_count >= max_cycles:
        dut._log.error(f"TIMEOUT: No done signal after {max_cycles} cycles")
        assert False, "Inference timed out"

    # Read result
    uo_out_val = int(dut.uo_out.value)
    result = uo_out_val & 0x0F  # Lower 4 bits = prediction
    done = bool(uo_out_val & 0x10)  # Bit 4 = done
    busy = bool(uo_out_val & 0x20)  # Bit 5 = busy

    dut._log.info("Inference complete!")
    dut._log.info(f"Total Cycles: {cycle_count}")
    dut._log.info(f"Expected:     {expected}")
    dut._log.info(f"Got:          {result}")
    dut._log.info(f"Done signal:  {done}")
    dut._log.info(f"Busy signal:  {busy}")

    if result == expected:
        dut._log.info("✓ PASS")
    else:
        dut._log.error("✗ FAIL - Mismatch!")
        assert False, f"Expected {expected}, got {result}"

    # Clear start
    dut.uio_in.value = 0x00
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_wrapper_multiple_inferences(dut):
    """Test wrapper with multiple inferences."""

    dut._log.info("=" * 80)
    dut._log.info("TT Wrapper - Multiple Inference Test (10 vectors)")
    dut._log.info("=" * 80)

    # Start clock
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    num_vectors = 10
    num_pass = 0
    num_fail = 0
    failures = []
    cycle_counts = []

    for test_idx in range(num_vectors):
        # Load test vector
        pixels, expected, metadata = load_test_vector(test_idx)

        # Reset
        dut.ena.value = 1
        dut.ui_in.value = 0
        dut.uio_in.value = 0
        dut.rst_n.value = 0
        await ClockCycles(dut.clk, 2)
        dut.rst_n.value = 1
        await RisingEdge(dut.clk)

        cycle_count = 0

        # Set first 4 pixels on ui_in BEFORE asserting start
        pixel_0 = pixels[0]
        pixel_1 = pixels[1]
        pixel_2 = pixels[2]
        pixel_3 = pixels[3]
        ui_in_value = (pixel_3 << 6) | (pixel_2 << 4) | (pixel_1 << 2) | pixel_0
        dut.ui_in.value = ui_in_value

        # Start inference
        dut.uio_in.value = 0x01
        await RisingEdge(dut.clk)
        cycle_count += 1

        # Hold first pixels for MNIST to latch
        await RisingEdge(dut.clk)
        cycle_count += 1

        # Stream remaining pixels
        for i in range(1, 16):
            pixel_0 = pixels[i * 4 + 0]
            pixel_1 = pixels[i * 4 + 1]
            pixel_2 = pixels[i * 4 + 2]
            pixel_3 = pixels[i * 4 + 3]
            ui_in_value = (pixel_3 << 6) | (pixel_2 << 4) | (pixel_1 << 2) | pixel_0
            dut.ui_in.value = ui_in_value
            await RisingEdge(dut.clk)
            cycle_count += 1

        # Wait for done
        max_cycles = 5000
        while dut.uo_out.value[4] != 1 and cycle_count < max_cycles:
            await RisingEdge(dut.clk)
            cycle_count += 1

        if cycle_count >= max_cycles:
            dut._log.error(f"Test {test_idx}: TIMEOUT")
            num_fail += 1
            failures.append(
                {
                    "idx": test_idx,
                    "expected": expected,
                    "got": "TIMEOUT",
                    "cycles": cycle_count,
                }
            )
            continue

        # Check result
        result = int(dut.uo_out.value) & 0x0F
        cycle_counts.append(cycle_count)

        if result == expected:
            num_pass += 1
            status = "✓"
        else:
            num_fail += 1
            status = "✗"
            failures.append(
                {
                    "idx": test_idx,
                    "expected": expected,
                    "got": result,
                    "cycles": cycle_count,
                }
            )

        true_label = metadata.get("True label", "?")
        dut._log.info(
            f"{status} Test {test_idx:2d}: Label={true_label}, "
            f"Expected={expected}, Got={result}, Cycles={cycle_count}"
        )

        # Clear start
        dut.uio_in.value = 0x00
        await RisingEdge(dut.clk)

    # Summary
    if cycle_counts:
        avg_cycles = sum(cycle_counts) / len(cycle_counts)
        min_cycles = min(cycle_counts)
        max_cycles = max(cycle_counts)
    else:
        avg_cycles = min_cycles = max_cycles = 0

    dut._log.info("=" * 80)
    dut._log.info(
        f"RESULTS: {num_pass}/{num_vectors} tests passed ({100 * num_pass / num_vectors:.1f}%)"
    )
    if cycle_counts:
        dut._log.info(
            f"Cycle Stats: Min={min_cycles}, Max={max_cycles}, Avg={avg_cycles:.1f}"
        )
    dut._log.info("=" * 80)

    if num_fail > 0:
        dut._log.error("")
        dut._log.error(f"FAILURES: {num_fail} tests failed")
        for f in failures:
            dut._log.error(
                f"Test {f['idx']:2d}: Expected {f['expected']}, Got {f['got']}"
            )
        assert False, f"{num_fail}/{num_vectors} tests failed"
    else:
        dut._log.info("✓ ALL TESTS PASSED!")
