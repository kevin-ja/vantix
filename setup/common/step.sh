# Lo que carga cada paso. Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
#
# Un paso define tres funciones y termina con run_step:
#   review   solo lee; llama a `todo "qué falta"` por cada cosa pendiente
#   apply    configura lo pendiente
#   verify   comprueba el resultado (por defecto, repite review)
# Sale con 0 si quedó listo, 3 si falta algo (solo con check), 1 si falló y 130 si se canceló.
set -o pipefail

if [ -z "$SETUP_MODE" ] || [ -z "$ROOT" ]; then
  echo "Este paso lo corre setup/run.sh: usa make train-up, make inference-up o make monitoring-up." >&2
  exit 1
fi

COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$COMMON/ui.sh"
. "$COMMON/env.sh"
. "$COMMON/aws.sh"
. "$COMMON/terraform.sh"
. "$COMMON/github.sh"
. "$COMMON/server.sh"

have() { command -v "$1" >/dev/null 2>&1; }
sha256_of() { if have shasum; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }

TODO=()
todo() { TODO+=("$1"); err "$1"; }

verify() { review; }

# Lo ya instalado debe verse aunque la terminal no se haya reabierto.
use_path() {
  if ! command -v brew >/dev/null 2>&1; then
    if   [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ];    then eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi
  if [ -x "$HOME/.local/bin/terraform" ]; then export PATH="$HOME/.local/bin:$PATH"; fi
}

run_step() {
  WORK="$(mktemp -d)" || die "No se pudo crear una carpeta temporal."
  LOG="$WORK/log"
  : > "$LOG"
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  use_path
  use_profile
  TODO=()
  review
  if [ ${#TODO[@]} -eq 0 ]; then exit 0; fi
  if [ "$SETUP_MODE" = "check" ]; then exit 3; fi
  apply
  TODO=()
  verify
  if [ ${#TODO[@]} -gt 0 ]; then die "No quedó como se esperaba (ver arriba)."; fi
  exit 0
}
