"""Contrato del directorio models/champion/ entre promote (escribe) e inferencia (lee)."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import joblib

PREPROCESSOR_FILE = "preprocessor.pkl"
MODEL_FILE = "model.pkl"
SEGMENT_MAP_FILE = "segment_map.json"
MANIFEST_FILE = "manifest.json"
CHAMPION_FILES = (PREPROCESSOR_FILE, MODEL_FILE, SEGMENT_MAP_FILE, MANIFEST_FILE)


@dataclass
class Champion:
    preprocessor: object
    model: object
    segment_map: dict[int, str]
    manifest: dict


def load_champion(local_dir: str | Path) -> Champion:
    d = Path(local_dir)
    missing = [f for f in CHAMPION_FILES if not (d / f).is_file()]
    if missing:
        raise FileNotFoundError(f"Faltan artefactos del champion en {d}: {missing}")

    manifest = json.loads((d / MANIFEST_FILE).read_text())
    segment_map = {int(c): name for c, name in json.loads((d / SEGMENT_MAP_FILE).read_text()).items()}
    model = joblib.load(d / MODEL_FILE)

    k = int(manifest["k"])
    if getattr(model, "n_clusters", None) != k or sorted(segment_map) != list(range(k)):
        raise ValueError(f"Artefactos inconsistentes: manifest k={k}, modelo "
                         f"{getattr(model, 'n_clusters', None)}, segment_map {sorted(segment_map)}")
    return Champion(joblib.load(d / PREPROCESSOR_FILE), model, segment_map, manifest)
