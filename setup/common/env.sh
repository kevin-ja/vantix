# Lee y valida .env. Solo configuración, nunca credenciales. El archivo no se ejecuta: se lee línea por línea y solo
# se aceptan las claves de ENV_KEYS. Compatible con bash 3.2.

ENV_KEYS="SSO_START_URL SSO_REGION ACCOUNT_ID ROLE_NAME PROFILE GITHUB_REPO INGEST_DATE ALERT_EMAIL"
ENV_PROBLEMS=()

env_matches() { printf '%s\n' "$1" | grep -E "$2" >/dev/null; }

# Una fecha que exista en el calendario. Sin Python: todavía puede no estar instalado.
env_date() {
  local y m d last
  env_matches "$1" '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || return 1
  y=$((10#${1:0:4})); m=$((10#${1:5:2})); d=$((10#${1:8:2}))
  case "$m" in
    1|3|5|7|8|10|12) last=31 ;;
    4|6|9|11) last=30 ;;
    2) if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then last=29; else last=28; fi ;;
    *) return 1 ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$last" ]
}

# env_valid <clave> <valor> -> 0 si sirve; si no, escribe el motivo.
env_valid() {
  case "$1" in
    SSO_START_URL) env_matches "$2" '^https://[A-Za-z0-9._/-]+$' || { echo "debe ser una URL https://…"; return 1; } ;;
    SSO_REGION)    env_matches "$2" '^[a-z]{2}(-[a-z]+)+-[0-9]+$' || { echo "debe ser una región, p. ej. us-east-1"; return 1; } ;;
    ACCOUNT_ID)    env_matches "$2" '^[0-9]{12}$' || { echo "debe tener 12 dígitos"; return 1; } ;;
    ROLE_NAME)     env_matches "$2" '^[A-Za-z0-9+=,.@_-]+$' || { echo "no es un nombre de rol válido"; return 1; } ;;
    PROFILE)       env_matches "$2" '^[A-Za-z0-9._-]+$' || { echo "solo letras, números, punto, guion y guion bajo"; return 1; } ;;
    GITHUB_REPO)   env_matches "$2" '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' || { echo "debe tener la forma usuario/repo"; return 1; } ;;
    INGEST_DATE)   env_date "$2" || { echo "debe ser una fecha real, p. ej. 2025-04-30"; return 1; } ;;
    ALERT_EMAIL)   env_matches "$2" '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' || { echo "no es un correo válido"; return 1; } ;;
  esac
}

env_problem() { ENV_PROBLEMS+=("$(printf '%-16s %s' "$1" "$2")"); }

# env_load <archivo> <claves obligatorias…> -> exporta las claves. Si hay problemas los deja todos en ENV_PROBLEMS.
env_load() {
  local file="$1" line key value reason n=0 seen=" "
  shift
  ENV_PROBLEMS=()
  # Manda el archivo: lo que hubiera en la terminal no cuenta.
  for key in $ENV_KEYS; do unset "$key"; done
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$line" in ''|'#'*) continue ;; esac
    key="$(printf '%s\n' "$line" | sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*$/\1/p')"
    if [ -z "$key" ]; then env_problem "línea $n" "debe tener la forma CLAVE=valor"; continue; fi
    # Primero las credenciales: nunca se guarda ni se muestra su valor.
    if env_matches "$key" '^(AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)|.*(PASSWORD|SECRET|TOKEN|PRIVATE_KEY).*)$'; then
      env_problem "$key" "es una credencial: bórrala de .env (el acceso es con inicio de sesión en el navegador)"
      continue
    fi
    case " $ENV_KEYS " in
      *" $key "*) ;;
      *) env_problem "$key" "no se reconoce (ver .env.example)"; continue ;;
    esac
    case "$seen" in *" $key "*) env_problem "$key" "está repetida"; continue ;; esac
    seen="$seen$key "
    value="$(printf '%s\n' "${line#*=}" | sed -E -e 's/^[[:space:]]+//' -e "s/^\"(.*)\"\$/\\1/" -e "s/^'(.*)'\$/\\1/")"
    # El portal suele copiarse con "#" o "/" al final.
    if [ "$key" = "SSO_START_URL" ]; then value="$(printf '%s' "$value" | sed -e 's/[#/]*$//')"; fi
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$file"
  for key in "$@"; do
    value="${!key}"
    case "$value" in
      ''|*'<'*'>'*) env_problem "$key" "falta" ;;
      *) reason="$(env_valid "$key" "$value")" || env_problem "$key" "$reason" ;;
    esac
  done
  [ ${#ENV_PROBLEMS[@]} -eq 0 ]
}
