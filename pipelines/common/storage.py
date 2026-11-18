"""Rutas locales o s3:// con la misma interfaz (local para pruebas, S3 en SageMaker).

boto3 se importa solo cuando la ruta es s3://, así los tests locales no lo necesitan.
"""
from __future__ import annotations

import os
import re
import shutil
from pathlib import Path


def is_s3(uri: str) -> bool:
    return str(uri).startswith("s3://")


def join(base: str, *parts: str) -> str:
    if is_s3(base):
        return "/".join([base.rstrip("/"), *(p.strip("/") for p in parts)])
    return str(Path(base).joinpath(*parts))


def _split(uri: str) -> tuple[str, str]:
    bucket, _, key = uri[len("s3://"):].partition("/")
    return bucket, key


def _s3():
    import boto3
    return boto3.Session(profile_name=os.environ.get("AWS_PROFILE") or None).client("s3")


def list_children(uri: str) -> list[str]:
    """Nombres de los "subdirectorios" directos de uri."""
    if not is_s3(uri):
        p = Path(uri)
        return sorted(c.name for c in p.iterdir() if c.is_dir()) if p.is_dir() else []
    bucket, key = _split(uri)
    prefix = key.rstrip("/") + "/"
    names = []
    for page in _s3().get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix, Delimiter="/"):
        names += [cp["Prefix"][len(prefix):].rstrip("/") for cp in page.get("CommonPrefixes", [])]
    return sorted(names)


def latest_partition(uri: str, key: str) -> str:
    """Mayor valor de una partición `key=valor` bajo uri (las fechas ISO ordenan como texto)."""
    pat = re.compile(rf"^{re.escape(key)}=(.+)$")
    values = sorted(m.group(1) for c in list_children(uri) if (m := pat.match(c)))
    if not values:
        raise FileNotFoundError(f"No hay particiones {key}=… en {uri}")
    return values[-1]


def download_dir(uri: str, dest: str | Path) -> Path:
    """Copia todos los archivos bajo uri a dest (sin recursión de subdirectorios)."""
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    if not is_s3(uri):
        src = Path(uri)
        files = [f for f in src.iterdir() if f.is_file()] if src.is_dir() else []
        for f in files:
            shutil.copy(f, dest / f.name)
    else:
        bucket, key = _split(uri)
        prefix = key.rstrip("/") + "/"
        s3 = _s3()
        files = []
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix, Delimiter="/"):
            for obj in page.get("Contents", []):
                name = obj["Key"][len(prefix):]
                if name:
                    s3.download_file(bucket, obj["Key"], str(dest / name))
                    files.append(name)
    if not files:
        raise FileNotFoundError(f"No hay archivos en {uri}")
    return dest


def upload_file(local: str | Path, uri: str) -> None:
    if is_s3(uri):
        bucket, key = _split(uri)
        _s3().upload_file(str(local), bucket, key)
    else:
        Path(uri).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(local, uri)
