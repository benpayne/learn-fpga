"""Test list for the PAL/GAL 68k bridge.

Re-exports the per-test functions from `bridge_68k_tb.py` *except*
`test_irq_passthrough`.  In the PAL/GAL build the bridge has no IRQ
logic — interrupt aggregation is the host-side interrupt controller's
job (see bus-design/docs/backplane.md).
"""
from bridge_68k_tb import (
    test_reset_clean,
    test_byte_write_read_even,
    test_byte_write_read_odd,
    test_word_write_read,
    test_byte_pair_alignment,
    test_multiple_addresses,
)
