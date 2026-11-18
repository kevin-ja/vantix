"""Lectura del dato crudo y hashing para versionar datos."""
from __future__ import annotations

import hashlib
from pathlib import Path

import pandas as pd

RAW_DTYPES = {
    "TransId": "int64",
    "UserName": "string",
    "CurrencyStr": "string",
    "Actual_Stake": "float64",
    "Odds": "float64",
    "BetType": "int64",
    "Betteam": "string",
    "Status": "string",
    "Winlost": "float64",
    "ActualRate": "float64",
    "LiveIndicator": "boolean",
    "BetGameTime": "string",
    "MatchId": "int64",
    "SportId": "int64",
    "LeagueId": "int64",
    "WebId": "string",
    "MaxBet": "float64",
}
RAW_DATES = ["TransDate", "Winlostdate"]


def resolve_input(path: str | Path) -> Path:
    """Acepta un archivo o un directorio con un único .parquet/.csv (como monta SageMaker)."""
    p = Path(path)
    if p.is_file():
        return p
    files = sorted(list(p.glob("*.parquet")) + list(p.glob("*.csv")))
    if len(files) != 1:
        raise ValueError(f"Se esperaba un único .parquet o .csv en {p}, hay {len(files)}")
    return files[0]


def read_raw(path: str | Path) -> pd.DataFrame:
    """Lee el dato crudo (Parquet o CSV) con tipos explícitos."""
    p = resolve_input(path)
    if p.suffix == ".parquet":
        return pd.read_parquet(p)
    return pd.read_csv(p, dtype=RAW_DTYPES, parse_dates=RAW_DATES)


def sha256_file(path: str | Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()
