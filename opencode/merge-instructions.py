#!/usr/bin/env python3
"""Merge an opencode instruction file into the global opencode config.

Usage:
    merge-instructions.py CONFIG_PATH INSTRUCTIONS_PATH

Reads the opencode config at CONFIG_PATH (plain JSON) and ensures its
``instructions`` array contains INSTRUCTIONS_PATH (an absolute path). The write
is atomic (temp file + ``os.replace``), so a crash mid-write can never leave a
truncated config that opencode would refuse to load. A timestamped backup is
created only when a change is actually made; re-runs that change nothing are
no-ops and create no backup.

Exit codes:
    0   merged, created, or already up to date
    1   config exists but is unparseable, or I/O failed (original untouched)
    2   usage error
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import time
from pathlib import Path

SCHEMA_URL = "https://opencode.ai/config.json"


def _backup_path(config_path: Path) -> Path:
    """Return the timestamped, pid-suffixed backup path for the config file.

    Args:
        config_path: Path to the opencode config file.

    Returns:
        A sibling path like ``opencode.json.bak-20260817T103000-1234``.
    """
    stamp = time.strftime("%Y%m%dT%H%M%S")
    return config_path.with_name(f"{config_path.name}.bak-{stamp}-{os.getpid()}")


def _load_config(config_path: Path) -> dict | None:
    """Load the config file, returning None when it does not exist.

    Args:
        config_path: Path to the opencode config JSON file.

    Returns:
        The parsed config as a dict, or None if the file is absent.

    Raises:
        ValueError: When the file exists but is not valid JSON or does not
            contain a top-level JSON object.
    """
    if not config_path.exists():
        return None
    try:
        raw = config_path.read_text(encoding="utf-8-sig")
    except (UnicodeDecodeError, OSError) as exc:
        raise ValueError(f"cannot read file: {exc}") from exc
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"not valid JSON ({exc.lineno}:{exc.colno})") from exc
    if not isinstance(data, dict):
        raise ValueError("top level is not a JSON object")
    return data


def _dump_config(data: dict) -> str:
    """Serialize config with a stable 2-space indent and a trailing newline.

    Args:
        data: The config dict to serialize.

    Returns:
        The canonical JSON text for the config.
    """
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def _write_atomic(config_path: Path, data: dict, *, backup: bool) -> None:
    """Back up (optionally) then atomically replace the config file.

    Args:
        config_path: Path to the config file to write.
        data: The merged config dict to persist.
        backup: When True, copy the existing file to a timestamped backup
            before replacing it.

    Raises:
        OSError: When the directory cannot be created, the backup copy fails,
            or the atomic replace fails.
    """
    config_path.parent.mkdir(parents=True, exist_ok=True)
    if backup:
        shutil.copy2(config_path, _backup_path(config_path))
    tmp_path = config_path.with_name(f".{config_path.name}.tmp-{os.getpid()}")
    tmp_path.write_text(_dump_config(data), encoding="utf-8")
    os.replace(tmp_path, config_path)


def merge_instructions(config_path: Path, instructions_path: Path) -> bool:
    """Merge the instructions entry; return True when a change was made.

    Args:
        config_path: Path to the opencode config JSON file.
        instructions_path: Absolute path to the instruction file to register.

    Returns:
        True if the config was changed (and backed up); False on no-op.

    Raises:
        ValueError: When the config exists but is unparseable or has a
            non-list ``instructions`` field.
        OSError: When the config cannot be backed up or written.
    """
    target = str(instructions_path)
    current = _load_config(config_path)

    if current is None:
        _write_atomic(config_path, {"$schema": SCHEMA_URL, "instructions": [target]}, backup=False)
        return True

    instructions = current.get("instructions")
    if isinstance(instructions, list):
        if target in instructions:
            return False
        merged_instructions = [*instructions, target]
    elif instructions is None:
        merged_instructions = [target]
    else:
        raise ValueError("'instructions' field is not a list")

    merged = {**current, "instructions": merged_instructions}
    if _dump_config(merged) == _dump_config(current):
        return False

    _write_atomic(config_path, merged, backup=True)
    return True


def main(argv: list[str] | None = None) -> int:
    """Parse arguments, run the merge, and report the outcome.

    Args:
        argv: Command-line arguments (defaults to ``sys.argv[1:]``).

    Returns:
        The process exit code (0 success, 1 merge failure, 2 usage error).
    """
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) != 2:
        print("usage: merge-instructions.py CONFIG_PATH INSTRUCTIONS_PATH", file=sys.stderr)
        return 2

    config_path = Path(argv[0]).resolve()
    instructions_path = Path(argv[1])

    try:
        changed = merge_instructions(config_path, instructions_path)
    except ValueError as exc:
        print(f"merge-instructions: {config_path}: {exc}; file left untouched", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"merge-instructions: {config_path}: I/O error: {exc}", file=sys.stderr)
        return 1

    if changed:
        print(f"merge-instructions: registered {instructions_path} in {config_path}")
    else:
        print(f"merge-instructions: {config_path} already up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
