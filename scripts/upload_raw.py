"""Lee el dato crudo (Parquet o CSV), lo escribe como Parquet (tipos explícitos) y lo sube a
s3://<bucket>/raw/ingest_date=<fecha>/.

    python scripts/upload_raw.py --input data/data.parquet --bucket <bucket> --ingest-date 2025-04-30

La ruta es inmutable: si ya existe, falla (usa otra fecha de ingesta).
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import boto3  # noqa: E402

from pipelines.common.io import read_raw, sha256_file  # noqa: E402


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--input", "--csv", dest="input", required=True, help="Parquet o CSV")
    p.add_argument("--bucket", required=True)
    p.add_argument("--ingest-date", required=True)
    a = p.parse_args()

    s3 = boto3.Session(profile_name=os.environ.get("AWS_PROFILE")).client("s3")
    key = f"raw/ingest_date={a.ingest_date}/data.parquet"
    if s3.list_objects_v2(Bucket=a.bucket, Prefix=key).get("KeyCount", 0):
        raise SystemExit(f"s3://{a.bucket}/{key} ya existe: las rutas de raw no se sobrescriben")

    df = read_raw(a.input)
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "data.parquet"
        df.to_parquet(path, index=False)
        digest = sha256_file(path)
        s3.upload_file(str(path), a.bucket, key, ExtraArgs={"Metadata": {"sha256": digest}})
    print(f"{len(df):,} filas -> s3://{a.bucket}/{key} (sha256 {digest[:12]}…)")


if __name__ == "__main__":
    main()
