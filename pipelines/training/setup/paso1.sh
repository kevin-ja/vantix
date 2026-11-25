#!/usr/bin/env bash
# Paso 1 · Instalar las herramientas (ver pipelines/training/README.md). Solo macOS.
#
#   bash pipelines/training/setup/paso1.sh
#
# 1. Muestra qué herramientas faltan o tienen una versión que no sirve.
# 2. Pregunta (y/n). Sin un "y" no instala nada.
# 3. Instala o actualiza solo lo listado (Homebrew) y vuelve a comprobar todo.
#
# Compatible con bash 3.2, el que trae macOS: sin arrays asociativos ni mapfile, y sin `set -u`
# (en bash 3.2 falla al expandir un array vacío).
set -o pipefail

TERRAFORM_VERSION="1.15.8"   # exacta: la exige mlflow_server/infra/versions.tf
GH_MIN="2.40.0"              # `gh variable set --env`
MAKE_MIN="3.81"              # la que trae macOS
BIN="$HOME/.local/bin"       # aquí va terraform
TOOLS=(git make aws terraform docker uv gh)

# --- salida -------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; OFF=""
fi
title() { printf '\n%s%s%s\n' "$BOLD" "$*" "$OFF"; }
ok()    { printf '%s✔%s %s\n' "$GREEN" "$OFF" "$*"; }
warn()  { printf '%s!%s %s\n' "$YELLOW" "$OFF" "$*"; }
err()   { printf '%s✘%s %s\n' "$RED" "$OFF" "$*" >&2; }
die()   { err "$*"; exit 1; }

# confirm "pregunta" -> 0 si responde y, 1 si responde n
confirm() {
  local answer
  while true; do
    printf '%s%s [y/n]: %s' "$BOLD" "$1" "$OFF"
    read -r answer || return 1
    case "$answer" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *)   echo "Responde y o n." ;;
    esac
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

# Primer número de versión de un texto (stdin).
first_version() { grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1; }

# version_ge A B -> 0 si A >= B
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); max = (n > m) ? n : m
    for (i = 1; i <= max; i++) {
      if (x[i] + 0 > y[i] + 0) exit 0
      if (x[i] + 0 < y[i] + 0) exit 1
    }
    exit 0 }'
}

# --- sistema ------------------------------------------------------------------
ARCH=""   # amd64 | arm64

check_system() {
  if [ "$(uname -s)" != "Darwin" ]; then
    die "Este script es solo para macOS. En otro sistema, instala a mano las herramientas del Paso 1 del README."
  fi
  if [ "$(id -u)" -eq 0 ]; then
    die "Córrelo sin sudo: Homebrew no funciona como root."
  fi
  if [ ! -t 0 ]; then
    die "Córrelo en una terminal interactiva: necesita preguntarte antes de instalar."
  fi
  # sysctl y no uname: una terminal bajo Rosetta dice x86_64 aunque la Mac sea Apple Silicon.
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then ARCH="arm64"; else ARCH="amd64"; fi
}

# --- comprobaciones -----------------------------------------------------------
# check <herramienta> llena: STATUS (ok | falta | version), FOUND (versión encontrada), NEED (requisito).
STATUS=""; FOUND=""; NEED=""

label() {
  case "$1" in
    git)  echo "Git" ;;             make)   echo "Make" ;;
    brew) echo "Homebrew" ;;        aws)    echo "AWS CLI" ;;
    uv)   echo "uv" ;;              docker) echo "Docker + buildx" ;;
    gh)   echo "GitHub CLI" ;;      terraform) echo "Terraform" ;;
  esac
}

# Sin las Command Line Tools, el git y el make de /usr/bin son de relleno: solo abren una ventana.
usable() {
  local path
  path="$(command -v "$1" 2>/dev/null)" || return 1
  if ! xcode-select -p >/dev/null 2>&1; then
    case "$path" in /usr/bin/git|/usr/bin/make) return 1 ;; esac
  fi
  return 0
}

check() {
  local tool="$1" out
  STATUS="falta"; FOUND=""; NEED=""
  case "$tool" in
    aws)       NEED="2.x" ;;
    terraform) NEED="$TERRAFORM_VERSION exacta" ;;
    docker)    NEED="con buildx" ;;
    gh)        NEED=">= $GH_MIN" ;;
    make)      NEED=">= $MAKE_MIN" ;;
    *)         NEED="cualquiera" ;;
  esac

  usable "$tool" || return 0
  case "$tool" in
    terraform) out="$(terraform version 2>&1)" || return 0 ;;
    *)         out="$("$tool" --version 2>&1)" || return 0 ;;
  esac
  FOUND="$(printf '%s\n' "$out" | first_version)"
  STATUS="ok"

  case "$tool" in
    aws)       version_ge "${FOUND:-0}" 2           || STATUS="version" ;;
    terraform) [ "$FOUND" = "$TERRAFORM_VERSION" ]  || STATUS="version" ;;
    gh)        version_ge "${FOUND:-0}" "$GH_MIN"   || STATUS="version" ;;
    make)      version_ge "${FOUND:-0}" "$MAKE_MIN" || STATUS="version" ;;
    docker)    docker buildx version >/dev/null 2>&1 || { STATUS="version"; FOUND="$FOUND sin buildx"; } ;;
  esac
  return 0
}

print_check() {
  case "$STATUS" in
    ok)      ok   "$(label "$1")  $FOUND" ;;
    version) warn "$(label "$1")  $FOUND (se necesita: $NEED)" ;;
    falta)   err  "$(label "$1")  falta (se necesita: $NEED)" ;;
  esac
}

# Revisa TOOLS y deja en PLAN lo que hay que instalar o actualizar.
PLAN=()
check_all() {
  local tool brew_pending=0
  PLAN=()
  if ! have brew; then brew_pending=1; fi
  for tool in "${TOOLS[@]}"; do
    check "$tool"
    print_check "$tool" 2>&1
    if [ "$STATUS" = "ok" ]; then continue; fi
    # Homebrew solo se instala si algo lo necesita, justo antes de lo primero que lo usa.
    case "$tool" in
      aws|docker|uv|gh)
        if [ "$brew_pending" -eq 1 ]; then PLAN+=("brew"); brew_pending=0; fi ;;
    esac
    PLAN+=("$tool")
  done
}

# --- instaladores -------------------------------------------------------------
# Devuelven 0 = listo, 1 = falló, 2 = falta algo a mano.
TMP=""

download() { curl -fL --retry 3 --progress-bar -o "$2" "$1"; }

brew_install() {
  if brew list --formula "$1" >/dev/null 2>&1; then brew upgrade "$1"; else brew install "$1"; fi
}

# Deja una línea al final del archivo de arranque de la terminal, una sola vez.
RC_CHANGED=""
persist_line() {
  local rc
  case "$(basename "${SHELL:-zsh}")" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bash_profile" ;;
    *)    warn "Agrega esta línea al arranque de tu terminal: $1"; return 0 ;;
  esac
  if grep -qF "$1" "$rc" 2>/dev/null; then return 0; fi
  printf '\n# Vantix (paso1.sh)\n%s\n' "$1" >> "$rc" || return 1
  RC_CHANGED="$rc"
}

# Git y Make vienen en las Command Line Tools de Apple.
install_command_line_tools() {
  if xcode-select -p >/dev/null 2>&1; then return 0; fi
  xcode-select --install
  echo "Se abrió una ventana de macOS: acepta la instalación y espera a que termine."
  printf 'Pulsa Enter cuando haya terminado: '
  read -r _ || return 1
  xcode-select -p >/dev/null 2>&1
}

install_git()  { install_command_line_tools; }
install_make() { install_command_line_tools; }

install_brew() {
  download https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$TMP/brew.sh" || return 1
  /bin/bash "$TMP/brew.sh" || return 1
  local brew_bin="/usr/local/bin/brew"
  if [ -x /opt/homebrew/bin/brew ]; then brew_bin="/opt/homebrew/bin/brew"; fi
  eval "$("$brew_bin" shellenv)" || return 1
  persist_line "eval \"\$($brew_bin shellenv)\""
}

install_aws() { brew_install awscli; }
install_uv()  { brew_install uv; }
install_gh()  { brew_install gh; }

# Homebrew no permite fijar la versión: se baja la exacta, con SHA-256 verificado, a ~/.local/bin.
# shellcheck disable=SC2016  # $HOME y $PATH se escriben literales en el archivo de arranque
install_terraform() {
  local zip base expected actual
  zip="terraform_${TERRAFORM_VERSION}_darwin_${ARCH}.zip"
  base="https://releases.hashicorp.com/terraform/$TERRAFORM_VERSION"
  download "$base/$zip" "$TMP/$zip" || return 1
  download "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS" "$TMP/tf.sums" || return 1
  expected="$(awk -v f="$zip" '$2 == f {print $1}' "$TMP/tf.sums")"
  actual="$(shasum -a 256 "$TMP/$zip" | awk '{print $1}')"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    err "El SHA-256 de Terraform no coincide: no se instala."
    return 1
  fi
  unzip -q -o "$TMP/$zip" terraform -d "$TMP/tf" || return 1
  mkdir -p "$BIN" || return 1
  if [ -e "$BIN/terraform" ] || [ -L "$BIN/terraform" ]; then
    mv "$BIN/terraform" "$BIN/terraform.anterior.$(date +%Y%m%d%H%M%S)" || return 1
  fi
  install -m 755 "$TMP/tf/terraform" "$BIN/terraform" || return 1
  export PATH="$BIN:$PATH"
  persist_line 'export PATH="$HOME/.local/bin:$PATH"'
}

install_docker() {
  if [ ! -d /Applications/Docker.app ]; then brew install --cask docker-desktop || return 1; fi
  warn "Abre Docker Desktop, acepta su licencia y vuelve a correr este script."
  return 2
}

# --- avisos finales (no instalan nada) ----------------------------------------
final_notes() {
  if have docker && ! docker info >/dev/null 2>&1; then
    warn "Docker está instalado pero no responde: abre Docker Desktop antes de levantar MLflow."
  fi
  if [ -n "$RC_CHANGED" ]; then
    warn "Abre una terminal nueva para usar los cambios de $RC_CHANGED."
  fi
}

# --- flujo --------------------------------------------------------------------
main() {
  local tool i total rc failed=0 manual=0

  check_system
  title "Sistema detectado: macOS $(sw_vers -productVersion) ($ARCH)"

  # Lo ya instalado debe verse aunque la terminal no se haya reabierto.
  if ! have brew; then
    if   [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ];    then eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi
  if [ -x "$BIN/terraform" ]; then export PATH="$BIN:$PATH"; fi

  title "Revisando herramientas"
  check_all
  total=${#PLAN[@]}
  if [ "$total" -eq 0 ]; then
    title "Todo listo: no falta nada."
    final_notes
    exit 0
  fi

  title "Dependencias por instalar o actualizar ($total)"
  for tool in "${PLAN[@]}"; do
    check "$tool"
    if [ "$STATUS" = "version" ]; then
      echo "  - $(label "$tool"): actualizar ($FOUND → $NEED)"
    else
      echo "  - $(label "$tool"): instalar ($NEED)"
    fi
    if [ "$tool" = "terraform" ]; then
      echo "      en $BIN, que pasa a ser el primero del PATH; no borra otras versiones"
    fi
  done
  echo
  if ! confirm "¿Proceder con la instalación?"; then echo "No se instaló nada."; exit 1; fi

  TMP="$(mktemp -d)" || die "No se pudo crear una carpeta temporal."
  trap 'rm -rf "$TMP"' EXIT

  i=0
  for tool in "${PLAN[@]}"; do
    i=$((i + 1))
    title "[$i/$total] $(label "$tool")"
    "install_$tool"
    rc=$?
    hash -r
    case "$rc" in
      0) ok "$(label "$tool"): terminado" ;;
      2) warn "$(label "$tool"): falta un paso a mano (ver arriba)"; manual=1 ;;
      *) err "$(label "$tool"): falló (ver el error arriba)"; failed=1 ;;
    esac
  done

  title "Comprobación final"
  check_all
  final_notes
  if [ ${#PLAN[@]} -eq 0 ]; then
    title "Todo listo. Puedes seguir con el siguiente paso del README."
    exit 0
  fi
  echo
  if [ "$failed" -eq 0 ] && [ "$manual" -eq 1 ]; then
    warn "Quedan pasos a mano. Cuando los termines, vuelve a correr este script."
  else
    err "Algunas herramientas no quedaron listas. Corrige el error y vuelve a correr este script: solo intentará las que faltan."
  fi
  exit 1
}

main "$@"
