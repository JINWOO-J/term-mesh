#!/usr/bin/env python3
"""
Regression test: terminal drop-target overlay should animate on initial show.

This exercises the focused terminal's drop-overlay code path via debug socket
commands (no Accessibility/TCC/sudo required).

Usage:
    python3 tests_v2/test_terminal_drop_overlay_animation_probe.py
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def _parse_bounds(bounds: str) -> tuple[float, float]:
    parts = bounds.split("x", 1)
    if len(parts) != 2:
        raise termmeshError(f"Unexpected bounds format: {bounds}")
    return float(parts[0]), float(parts[1])


def main() -> int:
    with termmesh() as client:
        client.activate_app()
        workspace_id = client.new_workspace()
        try:
            client.select_workspace(workspace_id)
            time.sleep(0.25)

            deferred = client._call("debug.terminal.drop_overlay_probe", {"mode": "deferred"}) or {}
            direct = client._call("debug.terminal.drop_overlay_probe", {"mode": "direct"}) or {}

            bounds_str = deferred.get("bounds", "0x0")
            width, height = _parse_bounds(bounds_str)
            if width <= 2 or height <= 2:
                raise termmeshError(
                    f"Focused terminal bounds too small for overlay probe: {width}x{height}"
                )

            if not deferred.get("animated"):
                raise termmeshError(
                    "Deferred drop-overlay show did not animate. "
                    f"response={deferred}"
                )
            if not direct.get("animated"):
                raise termmeshError(
                    "Direct drop-overlay show did not animate. "
                    f"response={direct}"
                )
        finally:
            try:
                client.close_workspace(workspace_id)
            except Exception:
                # Keep the test focused on overlay behavior; cleanup best-effort.
                pass

    print("PASS: terminal drop overlay animates for deferred and direct show paths")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
