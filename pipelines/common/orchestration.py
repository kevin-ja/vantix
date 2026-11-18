"""Helpers de los pipeline_sagemaker.py (se ejecutan en local, nunca dentro de los jobs)."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SKLEARN_VERSION = "1.4-2"              # contenedor oficial de SageMaker (scikit-learn 1.4.2)
PROCESSING_INSTANCE = "ml.t3.xlarge"   # cuota disponible: 2

ENTRY_SHIM = "from {module} import main\n\nif __name__ == '__main__':\n    main()\n"


def env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Falta la variable de entorno {name} (usa los targets del Makefile)")
    return value


def git_commit() -> str:
    try:
        sha = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=REPO, text=True,
                                      stderr=subprocess.DEVNULL).strip()
        dirty = subprocess.call(["git", "diff", "--quiet"], cwd=REPO, stderr=subprocess.DEVNULL) != 0
        return f"{sha}-dirty" if dirty else sha
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "nogit"


def stage_source(requirements: Path, entries: dict[str, str]) -> str:
    """Directorio con el paquete `pipelines/`, requirements.txt y un entrypoint por job.

    entries: {"prepare_entry.py": "pipelines.training.steps.prepare", ...}
    """
    stage = Path(tempfile.mkdtemp(prefix="vantix-src-"))
    shutil.copytree(REPO / "pipelines", stage / "pipelines",
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copy(requirements, stage / "requirements.txt")
    for filename, module in entries.items():
        (stage / filename).write_text(ENTRY_SHIM.format(module=module))
    return str(stage)
