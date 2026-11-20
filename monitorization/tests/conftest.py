"""Rutas: monitoring (monitorization/src) y pipelines.common (raíz del repo), igual que en la imagen."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "monitorization" / "src"), str(ROOT)]
