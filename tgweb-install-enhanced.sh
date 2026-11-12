#!/usr/bin/env bash
# Enhanced launcher: downloads the pinned upstream installer, verifies it,
# applies the secret-format and read-only config-report additions, then runs it.
set -Eeuo pipefail
umask 077
SOURCE_URL="https://raw.githubusercontent.com/RSaenko/tgproxy/main/tgweb-install.sh"
EXPECTED_BLOB="94b41ea97723fe2b63c7c5710f95a94ae0cb5aae"
TMP_DIR="$(mktemp -d /tmp/tgweb-install.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 "$SOURCE_URL" -o "$TMP_DIR/upstream.sh"

python3 - "$TMP_DIR/upstream.sh" "$TMP_DIR/enhanced.sh" "$EXPECTED_BLOB" <<'PY'
import hashlib, pathlib, sys
src_path, out_path, expected = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
src = src_path.read_bytes()
actual = hashlib.sha1(b"blob " + str(len(src)).encode() + b"\0" + src).hexdigest()
if actual != expected:
    raise SystemExit(f"Upstream source changed: expected blob {expected}, got {actual}")
text = src.decode("utf-8")

def patch(old, new, label):
    global text
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"Patch failed ({label}): expected one match, got {n}")
    text = text.replace(old, new, 1)

patch('SECRET_ARG=""\nBASE_PATH_ARG=""',
      'SECRET_ARG=""\nSECRET_PREFIX_MODE="plain"\nBASE_PATH_ARG=""', "secret mode variable")
patch('  --secret 32hex            MTProxy-секрет (32 hex)\n',
      '  --secret SECRET           32 hex или dd + 32 hex\n  --secret-prefix MODE       plain или dd (формат генерации)\n  config [--output PATH]     Показать текущие настройки и ссылки\n',
      "help")
patch('''  local choice
  echo
  echo "Секрет MTProxy — 32 hex (16 байт), можно с префиксом dd."
  while :; do
    read -r -p "Сгенерировать? [Y] / ввести свой [n]: " choice
    choice="${choice:-Y}"
    if [[ "$choice" =~ ^[YyДд] ]]; then
      SECRET_ARG="$(openssl rand -hex 16)"
      info "Секрет: $SECRET_ARG"
      return 0
    fi''',
'''  local choice format_choice
  echo
  echo "Секрет MTProxy — 32 hex (16 байт), можно с префиксом dd."
  read -r -p "Формат секрета: [1] обычный  [2] dd-префикс: " format_choice
  local default_choice=1
  [[ "$SECRET_PREFIX_MODE" == "dd" ]] && default_choice=2
  case "${format_choice:-$default_choice}" in
    1) SECRET_PREFIX_MODE="plain" ;;
    2) SECRET_PREFIX_MODE="dd" ;;
    *) die "Выбери 1 или 2" ;;
  esac
  while :; do
    read -r -p "Сгенерировать? [Y] / ввести свой [n]: " choice
    choice="${choice:-Y}"
    if [[ "$choice" =~ ^[YyДд] ]]; then
      SECRET_ARG="$(openssl rand -hex 16)"
      [[ "$SECRET_PREFIX_MODE" == "dd" ]] && SECRET_ARG="dd${SECRET_ARG}"
      info "Секрет: $SECRET_ARG"
      return 0
    fi''', "interactive secret prompt")
patch('      --secret)          SECRET_ARG="$2";    shift 2 ;;',
      '      --secret)          [[ $# -ge 2 ]] || die "--secret требует значение"; SECRET_ARG="$2"; shift 2 ;;\n      --secret-prefix)   [[ $# -ge 2 ]] || die "--secret-prefix требует plain|dd"; SECRET_PREFIX_MODE="$2"; shift 2 ;;',
      "secret CLI")
patch('''  if [[ -n "$SECRET_ARG" ]]; then
    validate_secret "$SECRET_ARG" >/dev/null || die "невалидный --secret"
  fi''',
'''  [[ "$SECRET_PREFIX_MODE" == "plain" || "$SECRET_PREFIX_MODE" == "dd" ]] || die "--secret-prefix: допустимо plain или dd"
  if [[ -n "$SECRET_ARG" ]]; then
    validate_secret "$SECRET_ARG" >/dev/null || die "невалидный --secret"
  fi''', "secret mode validation")
patch('''    [[ $need_admin -eq 0 ]] || die "--admin-port обязателен в non-interactive"
    return 0''',
'''    [[ $need_admin -eq 0 ]] || die "--admin-port обязателен в non-interactive"
    if [[ -z "$SECRET_ARG" ]]; then
      SECRET_ARG="$(openssl rand -hex 16)"
      [[ "$SECRET_PREFIX_MODE" == "dd" ]] && SECRET_ARG="dd${SECRET_ARG}"
    fi
    validate_secret "$SECRET_ARG" >/dev/null || die "невалидный секрет"
    return 0''', "noninteractive secret")

config_fn = r'''
run_config() {
  local cfg=/etc/tproxy-server/config.json profiles=/etc/tproxy-server/profiles.json
  local envf=/etc/mtproxy/mtproxy.env host="" base="" relay="" admin="" public_dir=""
  local backend="" secret="" workers="" maxconn="" nat="" proxy_secret="" server="" link="" output=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) [[ $# -ge 2 ]] || die "--output требует путь"; output="$2"; shift 2 ;;
      *) die "Неизвестная опция config: $1" ;;
    esac
  done
  if [[ -r "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    host="$(jq -r '.public_hostname // empty' "$cfg")"
    base="$(jq -r '.base_path // empty' "$cfg")"
    relay="$(jq -r '.listen // empty' "$cfg")"
    admin="$(jq -r '.admin_listen // empty' "$cfg")"
    public_dir="$(jq -r '.public_dir // empty' "$cfg")"
  fi
  if [[ -r "$profiles" ]] && command -v jq >/dev/null 2>&1; then
    secret="$(jq -r '.profiles[0].secret // empty' "$profiles")"
    backend="$(jq -r '.profiles[0].backend // empty' "$profiles")"
  fi
  if [[ -r "$envf" ]]; then
    workers="$(sed -n 's/^MTPROXY_WORKERS=//p' "$envf" | head -n1)"
    maxconn="$(sed -n 's/^MTPROXY_MAX_CONNECTIONS=//p' "$envf" | head -n1)"
    nat="$(sed -n 's/^MTPROXY_NAT_ARGS=//p' "$envf" | head -n1)"
  fi
  if [[ -n "$host" && -n "$secret" ]]; then
    BASE_PATH_ARG="$base"; SECRET_ARG="$secret"
    proxy_secret="$(web_proxy_secret)"
    server="$host"; [[ -n "$base" ]] && server="$host/$base"
    link="https://t.me/webproxy?server=${server//\//%2F}&secret=$proxy_secret"
  fi
  local report
  report="$(cat <<EOF
==================== ТЕКУЩАЯ КОНФИГУРАЦИЯ ====================
Домен                  : ${host:-<не задан>}
Base path              : ${base:-<root / не задан>}
Relay listen           : ${relay:-<не задан>}
Admin listen           : ${admin:-<не задан>}
MTProxy backend        : ${backend:-<не задан>}
Публичный каталог      : ${public_dir:-<не задан>}
Каталог сайта          : ${public_dir:-$SITE_DIR_DEFAULT}
Конфигурация relay     : $cfg
Профили                : $profiles
Переменные MTProxy     : $envf
Workers                : ${workers:-<не задан>}
Max connections        : ${maxconn:-<не задан>}
NAT args               : ${nat:-<не задан>}
Секрет клиента         : ${secret:-<не задан>}
Формат секрета         : $(if [[ "$secret" == dd* ]]; then echo "dd + 32 hex"; elif [[ -n "$secret" ]]; then echo "32 hex"; else echo "<не задан>"; fi)

Слушающие TCP-порты:
$(ss -lntp 2>/dev/null || true)

Состояние служб:
$(for s in mtproxy tproxy-firewall tproxy-server refresh-mtproxy-config.timer caddy; do
  printf '  %-28s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
done)

Ссылки подключения:
${link:-<не удалось сформировать: проверь config.json и profiles.json>}
==============================================================
EOF
)"
  if [[ -n "$output" ]]; then
    install -m 0600 /dev/null "$output"
    printf '%s\n' "$report" > "$output"
    echo "Конфигурация сохранена: $output (0600)"
  else
    printf '%s\n' "$report"
  fi
}
'''
patch('run_install() {\n  require_root', config_fn + '\nrun_install() {\n  require_root', "config report")
patch('''  echo "  5) Выход"
  echo
  local choice
  read -r -p "Выбор [1-5]: " choice
  case "$choice" in''',
'''  echo "  5) Просмотреть текущую конфигурацию"
  echo "  6) Выход"
  echo
  local choice
  read -r -p "Выбор [1-6]: " choice
  case "$choice" in''', "menu text")
patch('    5) exit 0 ;;\n    *) die "Неверный выбор" ;;',
      '    5) MODE=config ;;\n    6) exit 0 ;;\n    *) die "Неверный выбор" ;;', "menu routing")
patch('      purge)     parse_uninstall_args "$@" ;;\n      -h|--help|help) usage ;;\n      *) die "Unknown mode: $MODE (install|update|uninstall|purge)" ;;',
      '      purge)     parse_uninstall_args "$@" ;;\n      config)    : ;;\n      -h|--help|help) usage ;;\n      *) die "Unknown mode: $MODE (install|update|uninstall|purge|config)" ;;', "config mode")
patch('    purge)     run_purge ;;\n  esac',
      '    purge)     run_purge ;;\n    config)    require_root; run_config "$@" ;;\n  esac', "config dispatch")
out_path.write_text(text, encoding="utf-8")
PY

chmod 0755 "$TMP_DIR/enhanced.sh"
set +e
bash "$TMP_DIR/enhanced.sh" "$@"
status=$?
rm -rf "$TMP_DIR"
trap - EXIT
exit "$status"