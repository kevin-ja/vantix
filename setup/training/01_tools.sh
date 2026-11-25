# Paso: Herramientas
#
# Revisa las herramientas y sus versiones; instala o actualiza solo lo que falte (Homebrew), y antes pregunta.
# En otro sistema que no sea macOS solo revisa.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

GH_MIN="2.40.0"              # `gh variable set --env`
MAKE_MIN="3.81"              # la que trae macOS
BIN="$HOME/.local/bin"       # aquí va terraform
TOOLS=(git make aws terraform docker uv gh)
SYSTEM_NAME="$(uname -s)"

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
  if [ "$SYSTEM_NAME" = "Darwin" ] && ! xcode-select -p >/dev/null 2>&1; then
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

# Revisa TOOLS y deja en PLAN lo que hay que instalar o actualizar.
PLAN=()
review() {
  local tool brew_pending=0
  PLAN=()
  if ! have brew; then brew_pending=1; fi
  for tool in "${TOOLS[@]}"; do
    check "$tool"
    case "$STATUS" in
      ok)      ok   "$(label "$tool")  $FOUND"; continue ;;
      version) todo "$(label "$tool")  $FOUND (se necesita: $NEED)" ;;
      falta)   todo "$(label "$tool")  falta (se necesita: $NEED)" ;;
    esac
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
  printf '\n# Vantix (setup)\n%s\n' "$1" >> "$rc" || return 1
  RC_CHANGED="$rc"
}

# Git y Make vienen en las Command Line Tools de Apple.
install_command_line_tools() {
  if xcode-select -p >/dev/null 2>&1; then return 0; fi
  xcode-select --install
  info "Se abrió una ventana de macOS: acepta la instalación y espera a que termine."
  printf '  Pulsa Enter cuando haya terminado: '
  read -r _ || return 1
  xcode-select -p >/dev/null 2>&1
}

install_git()  { install_command_line_tools; }
install_make() { install_command_line_tools; }

install_brew() {
  download https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$WORK/brew.sh" || return 1
  /bin/bash "$WORK/brew.sh" || return 1
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
  local zip base expected actual arch="amd64"
  # sysctl y no uname: una terminal bajo Rosetta dice x86_64 aunque la Mac sea Apple Silicon.
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then arch="arm64"; fi
  zip="terraform_${TERRAFORM_VERSION}_darwin_${arch}.zip"
  base="https://releases.hashicorp.com/terraform/$TERRAFORM_VERSION"
  download "$base/$zip" "$WORK/$zip" || return 1
  download "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS" "$WORK/tf.sums" || return 1
  expected="$(awk -v f="$zip" '$2 == f {print $1}' "$WORK/tf.sums")"
  actual="$(sha256_of "$WORK/$zip")"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    err "El SHA-256 de Terraform no coincide: no se instala."
    return 1
  fi
  unzip -q -o "$WORK/$zip" terraform -d "$WORK/tf" || return 1
  mkdir -p "$BIN" || return 1
  if [ -e "$BIN/terraform" ] || [ -L "$BIN/terraform" ]; then
    mv "$BIN/terraform" "$BIN/terraform.anterior.$(date +%Y%m%d%H%M%S)" || return 1
  fi
  install -m 755 "$WORK/tf/terraform" "$BIN/terraform" || return 1
  export PATH="$BIN:$PATH"
  persist_line 'export PATH="$HOME/.local/bin:$PATH"'
}

install_docker() {
  if [ ! -d /Applications/Docker.app ]; then brew install --cask docker-desktop || return 1; fi
  warn "Abre Docker Desktop, acepta su licencia y vuelve a correr: $SETUP_COMMAND"
  return 2
}

apply() {
  local tool i=0 rc failed=0 manual=0
  if [ "$SYSTEM_NAME" != "Darwin" ]; then
    die "Solo se instalan solas en macOS: instala a mano lo que falta (Paso 1 de pipelines/training/README.md) y vuelve a correr $SETUP_COMMAND"
  fi
  echo
  echo "  Se instalará o actualizará en tu máquina (${#PLAN[@]}):"
  for tool in "${PLAN[@]}"; do
    if [ "$tool" = "brew" ]; then FOUND=""; NEED="gestor de paquetes"; else check "$tool"; fi
    echo "    - $(label "$tool") ${FOUND:+$FOUND → }($NEED)"
    if [ "$tool" = "terraform" ]; then echo "        en $BIN, que pasa a ser el primero del PATH; no borra otras versiones"; fi
  done
  echo
  confirm "¿Proceder con la instalación?" || die "No se instaló nada."
  for tool in "${PLAN[@]}"; do
    i=$((i + 1))
    info "[$i/${#PLAN[@]}] $(label "$tool")"
    "install_$tool"
    rc=$?
    hash -r
    case "$rc" in
      0) ok "$(label "$tool"): terminado" ;;
      2) manual=1 ;;
      *) err "$(label "$tool"): falló (ver el error arriba)"; failed=1 ;;
    esac
  done
  if [ -n "$RC_CHANGED" ]; then warn "Abre una terminal nueva para usar los cambios de $RC_CHANGED."; fi
  if [ "$failed" -eq 1 ]; then die "Algunas herramientas no quedaron listas. Al repetir solo se intentan las que faltan."; fi
  if [ "$manual" -eq 1 ]; then die "Queda un paso a mano (ver arriba)."; fi
}

run_step
