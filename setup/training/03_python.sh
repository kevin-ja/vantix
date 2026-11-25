# Paso: Entorno de Python
#
# Crea .venv/ con Python 3.11 e instala requirements-dev.txt. Si ya existe, solo completa lo que falte.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

PYTHON_VERSION="3.11"
VENV="$ROOT/.venv"
PY="$VENV/bin/python"
REQS="$ROOT/requirements-dev.txt"

python_version() { "$PY" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null; }

# Las librerías están al día si uv no cambiaría nada. Deja el detalle en $LOG.
libs_ready() {
  spin "Comprobando las librerías" uv pip install --dry-run --python "$PY" -r "$REQS" \
    && grep "Would make no changes" "$LOG" >/dev/null
}

# Lo que usan los comandos de la guía (descargar, verificar y subir el dataset).
try_imports() { "$PY" -c 'import boto3, mlflow, pandas, pyarrow, sagemaker, sklearn'; }

DO_CREATE=0; DO_RECREATE=0; DO_LIBS=0
review() {
  local version
  DO_CREATE=0; DO_RECREATE=0; DO_LIBS=0
  have uv || die "Falta uv."
  if [ ! -e "$VENV" ] && [ ! -L "$VENV" ]; then
    todo "Entorno .venv: no existe"
    DO_CREATE=1; DO_LIBS=1
    return 0
  fi
  [ -f "$VENV/pyvenv.cfg" ] || die "$VENV existe, pero no es un entorno de Python. No se cambió nada: muévelo o bórralo."
  version="$(python_version)"
  case "$version" in
    "$PYTHON_VERSION".*) ok "Entorno .venv: Python $version" ;;
    *)
      todo "Entorno .venv: tiene Python ${version:-que no funciona} (se necesita $PYTHON_VERSION)"
      DO_RECREATE=1; DO_LIBS=1
      return 0 ;;
  esac
  if ! libs_ready; then todo "Librerías: faltan o tienen otra versión"; DO_LIBS=1; return 0; fi
  ok "Librerías: al día con requirements-dev.txt"
  spin "Cargando las librerías" try_imports || { show_log; die "Alguna librería no carga (ver el error arriba)."; }
  ok "Librerías: cargan sin errores"
}

apply() {
  if [ "$DO_RECREATE" -eq 1 ]; then
    warn "Hay que BORRAR $VENV y crearlo de nuevo con Python $PYTHON_VERSION."
    confirm "¿Borrarlo?" || die "No se cambió nada."
    rm -rf "$VENV" || die "No se pudo borrar $VENV."
    ok "Entorno anterior borrado"
  fi
  if [ "$((DO_CREATE + DO_RECREATE))" -gt 0 ]; then
    task "Creando el entorno (si no tienes Python $PYTHON_VERSION, uv lo descarga)" "Entorno .venv creado" \
      uv venv --python "$PYTHON_VERSION" "$VENV" || die "No se pudo crear el entorno (ver el error arriba)."
  fi
  if [ "$DO_LIBS" -eq 1 ]; then
    task "Instalando las librerías (la primera vez puede tardar unos minutos)" "Librerías instaladas" \
      uv pip install --python "$PY" -r "$REQS" || die "No se pudieron instalar (ver el error arriba)."
  fi
}

run_step
