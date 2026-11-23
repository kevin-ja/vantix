"""Verifies the downloaded dataset: SHA-256 checksum + the same validation the training pipeline runs.

    python scripts/check_data.py data/data.parquet        # expects data/data.parquet.sha256 next to it

Exit code 0 = ready to upload (make upload-data); 1 = something is wrong (the message says what).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pipelines.common.io import read_raw, sha256_file  # noqa: E402
from pipelines.common.validate import DataValidationError, validate  # noqa: E402


def fail(msg: str) -> None:
    sys.stdout.flush()
    print(f"\n✘ DATA CHECK FAILED: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("path")
    path = Path(p.parse_args().path)
    sha_path = path.with_name(path.name + ".sha256")

    if not path.is_file():
        fail(f"{path} not found. Run: make get-data")
    if not sha_path.is_file():
        fail(f"{sha_path} not found (needed to verify the download). Run: make get-data")

    print(f"Checking {path} ...")
    expected = sha_path.read_text().split()[0] if sha_path.read_text().strip() else ""
    actual = sha256_file(path)
    if actual != expected:
        fail(f"checksum mismatch\n  expected {expected}\n  got      {actual}\n"
             "The file is corrupt or incomplete. Run: make get-data")
    print("  ✔ checksum (SHA-256) OK")

    try:
        df = read_raw(path)
    except Exception as e:  # noqa: BLE001 — cualquier error de lectura se reporta tal cual
        fail(f"cannot read {path}: {type(e).__name__}: {e}")
    try:
        validate(df)
    except DataValidationError as e:
        fail(f"the data does not pass the pipeline validation:\n  {e}")
    print("  ✔ schema and validation rules OK (same checks as the training pipeline)")

    print(f"\n✔ DATA OK: {len(df):,} rows · {df['UserName'].nunique():,} users · "
          f"{df['TransDate'].min():%Y-%m-%d} → {df['TransDate'].max():%Y-%m-%d}")
    print("Next step: make upload-data INGEST_DATE=2025-04-30")


if __name__ == "__main__":
    main()
