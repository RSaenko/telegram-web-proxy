#!/usr/bin/env bash
# ============================================================================
#  tproxy-manager.sh — установка / обновление / удаление tproxy-server
#
#  Usage:
#    sudo ./tproxy-manager.sh                  # интерактивное меню
#    sudo ./tproxy-manager.sh install [опции]  # установка
#    sudo ./tproxy-manager.sh update  [опции]  # обновление (skip-tests, не трогает сайт)
#    sudo ./tproxy-manager.sh uninstall [--keep-caddy] [--yes]
#    sudo ./tproxy-manager.sh purge     [--yes]
# ============================================================================
set -Eeuo pipefail
trap 'echo "❌ ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR
umask 077

# ----------------------------- константы ------------------------------------
readonly REPO_URL="https://github.com/telegramdesktop/tproxy-server.git"
readonly UPSTREAM_COMMIT="c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8"
readonly REPO_DIR="/opt/tproxy-server"
readonly SITE_DIR_DEFAULT="/srv/tproxy-site"
readonly GO_FALLBACK_VERSION="1.26.5"
readonly GO_FALLBACK_SHA256="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
readonly CADDY_VERSION="2.11.4"
readonly CADDY_SHA512="8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9"
readonly DEFAULT_PORT=8080
readonly DEFAULT_ADMIN_PORT=8081
readonly PURGE_PACKAGES=(nftables git jq netcat-openbsd dnsutils build-essential qrencode)

# ----------------------------- переменные -----------------------------------
MODE=""
HOSTNAME_ARG=""
EMAIL_ARG=""
SECRET_ARG=""
SECRET_PREFIX_MODE="plain"
SECRET_PREFIX_MODE_SET=0
BASE_PATH_ARG=""
SITE_DIR="$SITE_DIR_DEFAULT"
INSTALL_SITE=1
WORKERS_ARG=""
MAXCONN_ARG=""
NONINTERACTIVE="${NONINTERACTIVE:-0}"
RELAY_PORT=""
ADMIN_PORT=""
SKIP_TESTS="${SKIP_TESTS:-0}"
KEEP_CADDY=0
ASSUME_YES=0
GO_BIN=""

# ----------------------------- утилиты --------------------------------------
die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "ℹ️  $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*" >&2; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./tproxy-manager.sh                          # интерактивное меню
  sudo ./tproxy-manager.sh install   [опции установки]
  sudo ./tproxy-manager.sh update    [опции установки]
  sudo ./tproxy-manager.sh uninstall [--keep-caddy] [--yes]
  sudo ./tproxy-manager.sh purge     [--yes]

Опции установки/обновления:
  --hostname FQDN           Домен
  --email EMAIL             Email для Let's Encrypt
  --secret SECRET           32 hex или dd + 32 hex
  --secret-prefix MODE       plain или dd (формат генерации)
  config [--output PATH]     Показать текущие настройки (секреты скрыты)
  status                     Состояние служб и слушающие порты
  diagnostics                Диагностика служб и конфигураций
  backup [ABSOLUTE_PATH]     Резервная копия конфигураций
  restore ABSOLUTE_PATH      Восстановить конфигурации из архива
  --base-path SLUG|none     Базовый путь (default: генерируется)
  --site-dir PATH           Каталог сайта (default: /srv/tproxy-site)
  --no-site                 Не устанавливать сайт
  --workers N               MTProxy workers (default: 1)
  --max-connections N       MTProxy max connections (default: 4096)
  --port N                  Порт relay (default: 8080)
  --admin-port N            Admin-порт relay (default: 8081)
  --skip-tests              Не запускать go test
  --non-interactive, -y     Ничего не спрашивать
EOF
  return 0
}

# ----------------------------- валидаторы -----------------------------------
validate_hostname() {
  local h="$1"
  if [[ -z "$h" ]]; then echo "пусто"; return 1; fi
  if [[ ! "$h" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || [[ "$h" != *.* ]]; then
    echo "hostname должен быть lowercase ASCII DNS с точкой"; return 1
  fi
  return 0
}

validate_email() {
  local e="$1"
  if [[ "$e" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then return 0
  else echo "некорректный email"; return 1; fi
}

validate_secret() {
  local s="$1"
  if [[ "$s" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]; then return 0
  else echo "секрет: 32 lowercase hex, опционально с префиксом dd"; return 1; fi
}

validate_port() {
  local p="$1"
  if ! [[ "$p" =~ ^[0-9]+$ ]]; then echo "порт должен быть числом"; return 1; fi
  if ! (( p >= 1024 && p <= 65535 )); then echo "порт должен быть 1024..65535"; return 1; fi
  return 0
}

validate_base_path() {
  local b="$1"
  if [[ "$b" == "none" ]]; then return 0; fi
  if [[ ! "$b" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]]; then
    echo "base path: сегменты [A-Za-z0-9][A-Za-z0-9_-]*, разделитель /"; return 1
  fi
  if (( ${#b} > 128 )); then echo "base path ≤ 128 символов"; return 1; fi
  return 0
}

# ----------------------------- занятость портов -----------------------------
port_in_use()  { ss -lntp "sport = :$1" 2>/dev/null | grep -q LISTEN; }
port_owner()   { ss -lntp "sport = :$1" 2>/dev/null | awk 'NR>1{print $NF}' | head -n1; }
find_free_port() {
  local base="$1" p
  for (( p=base; p<base+200; p++ )); do
    if ! port_in_use "$p"; then echo "$p"; return 0; fi
  done
  return 1
}

# ----------------------------- интерактив -----------------------------------
prompt_value() {
  local __var="$1" label="$2" validator="$3"
  local input err
  while :; do
    read -r -p "$label: " input || die "ввод прерван"
    if [[ -z "$input" ]]; then echo "  ⚠️  обязательно"; continue; fi
    if err="$("$validator" "$input")"; then
      printf -v "$__var" '%s' "$input"; return 0
    else
      echo "  ⚠️  $err — попробуй ещё раз"
    fi
  done
}

prompt_port() {
  local var="$1" label="$2" default="$3"
  local input err
  while :; do
    read -r -p "$label [$default]: " input || die "ввод прерван"
    input="${input:-$default}"
    if ! err="$(validate_port "$input")"; then
      echo "  ⚠️  $err"; continue
    fi
    if port_in_use "$input"; then
      local owner alt
      owner="$(port_owner "$input")"
      alt="$(find_free_port "$input" || true)"
      echo "  ⚠️  порт $input занят${owner:+ ($owner)}"
      if [[ -n "$alt" ]]; then echo "      свободный рядом: $alt"; fi
      continue
    fi
    printf -v "$var" '%s' "$input"; return 0
  done
}

confirm() {
  local q="$1" ans
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  read -r -p "$q [Y/n]: " ans || die "ввод прерван"
  ans="${ans:-Y}"
  if [[ "$ans" =~ ^[YyДд] ]]; then return 0; else return 1; fi
}

prompt_secret() {
  if [[ -n "$SECRET_ARG" ]]; then return 0; fi
  local choice format_choice
  echo
  echo "Секрет MTProxy — 32 hex (16 байт), можно с префиксом dd."
  if [[ "$SECRET_PREFIX_MODE_SET" -eq 0 ]]; then
    local default_choice=1
    [[ "$SECRET_PREFIX_MODE" == "dd" ]] && default_choice=2
    read -r -p "Формат секрета: [1] обычный  [2] dd-префикс: " format_choice
    case "${format_choice:-$default_choice}" in
      1) SECRET_PREFIX_MODE="plain" ;;
      2) SECRET_PREFIX_MODE="dd" ;;
      *) die "Выбери 1 или 2" ;;
    esac
  fi
  while :; do
    read -r -p "Сгенерировать? [Y] / ввести свой [n]: " choice
    choice="${choice:-Y}"
    if [[ "$choice" =~ ^[YyДд] ]]; then
      SECRET_ARG="$(openssl rand -hex 16)"
      [[ "$SECRET_PREFIX_MODE" == "dd" ]] && SECRET_ARG="dd${SECRET_ARG}"
      info "Секрет: $SECRET_ARG"
      return 0
    fi
    local s1 s2
    read -r -s -p "Секрет: " s1; echo
    read -r -s -p "Повтор: " s2; echo
    if [[ "$s1" != "$s2" ]]; then echo "  ⚠️  не совпало"; continue; fi
    if ! [[ "$s1" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]; then
      echo "  ⚠️  32 hex (опционально dd-префикс)"; continue
    fi
    SECRET_ARG="$s1"; return 0
  done
}

interactive_fill() {
  local need_host=0 need_email=0 need_port=0 need_admin=0
  [[ -z "$HOSTNAME_ARG" ]] && need_host=1
  [[ -z "$EMAIL_ARG"    ]] && need_email=1
  [[ -z "$RELAY_PORT"   ]] && need_port=1
  [[ -z "$ADMIN_PORT"   ]] && need_admin=1

  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ $need_host  -eq 0 ]] || die "--hostname обязателен в non-interactive"
    [[ $need_email -eq 0 ]] || die "--email обязателен в non-interactive"
    [[ $need_port  -eq 0 ]] || die "--port обязателен в non-interactive"
    [[ $need_admin -eq 0 ]] || die "--admin-port обязателен в non-interactive"
    if [[ -z "$SECRET_ARG" ]]; then
      SECRET_ARG="$(openssl rand -hex 16)"
      [[ "$SECRET_PREFIX_MODE" == "dd" ]] && SECRET_ARG="dd${SECRET_ARG}"
    fi
    validate_secret "$SECRET_ARG" >/dev/null || die "невалидный секрет"
    return 0
  fi

  echo
  echo "────────────────────────────────────────────"
  echo "  Установка/обновление tproxy-server"
  echo "────────────────────────────────────────────"

  if [[ $need_host -eq 1 ]]; then
    echo
    echo "Домен (A-запись уже должна указывать на сервер)"
    prompt_value HOSTNAME_ARG "Hostname" validate_hostname
  fi
  if [[ $need_email -eq 1 ]]; then
    echo
    echo "Email для Let's Encrypt"
    prompt_value EMAIL_ARG "Email" validate_email
  fi
  if [[ $need_port -eq 1 ]]; then
    echo
    echo "Порт relay tproxy-server (внутренний, ≥1024). Caddy → этот порт."
    prompt_port RELAY_PORT "Relay-порт" "$DEFAULT_PORT"
  fi
  if [[ $need_admin -eq 1 ]]; then
    echo
    echo "Admin-порт relay (healthz/readyz)"
    prompt_port ADMIN_PORT "Admin-порт" "$DEFAULT_ADMIN_PORT"
    [[ "$ADMIN_PORT" == "$RELAY_PORT" ]] && die "admin-порт совпадает с relay"
  fi
  prompt_secret

  echo
  echo "────────────────────────────────────────────"
  echo "  Hostname   : $HOSTNAME_ARG"
  echo "  Email      : $EMAIL_ARG"
  echo "  Секрет     : ${SECRET_ARG:0:8}…${SECRET_ARG: -4}"
  echo "  Relay-порт : $RELAY_PORT"
  echo "  Admin-порт : $ADMIN_PORT"
  echo "  Сайт       : $SITE_DIR ($([[ $INSTALL_SITE -eq 1 ]] && echo да || echo нет))"
  [[ -n "$WORKERS_ARG" ]] && echo "  Workers    : $WORKERS_ARG"
  [[ -n "$MAXCONN_ARG" ]] && echo "  Max conns  : $MAXCONN_ARG"
  echo "────────────────────────────────────────────"
  confirm "Начинаем?" || die "отменено"
}

# ----------------------------- парсер флагов --------------------------------
parse_install_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname)        HOSTNAME_ARG="$2";  shift 2 ;;
      --email)           EMAIL_ARG="$2";     shift 2 ;;
      --secret)          [[ $# -ge 2 ]] || die "--secret требует значение"; SECRET_ARG="$2"; shift 2 ;;
      --secret-prefix)   [[ $# -ge 2 ]] || die "--secret-prefix требует plain|dd"; SECRET_PREFIX_MODE="$2"; SECRET_PREFIX_MODE_SET=1; shift 2 ;;
      --base-path)       BASE_PATH_ARG="$2"; shift 2 ;;
      --site-dir)        SITE_DIR="$2";      shift 2 ;;
      --no-site)         INSTALL_SITE=0;     shift ;;
      --workers)         WORKERS_ARG="$2";   shift 2 ;;
      --max-connections) MAXCONN_ARG="$2";   shift 2 ;;
      --port)            RELAY_PORT="$2";    shift 2 ;;
      --admin-port)      ADMIN_PORT="$2";    shift 2 ;;
      --non-interactive|-y) NONINTERACTIVE=1; shift ;;
      --skip-tests)      SKIP_TESTS=1;       shift ;;
      *) die "Unknown arg: $1" ;;
    esac
  done
  if [[ -n "$HOSTNAME_ARG" ]]; then
    local e; e="$(validate_hostname "$HOSTNAME_ARG")" || die "hostname: $e"
  fi
  if [[ -n "$EMAIL_ARG" ]]; then
    validate_email "$EMAIL_ARG" >/dev/null || die "невалидный email"
  fi
  [[ "$SECRET_PREFIX_MODE" == "plain" || "$SECRET_PREFIX_MODE" == "dd" ]] || die "--secret-prefix: допустимо plain или dd"
  if [[ -n "$SECRET_ARG" ]]; then
    validate_secret "$SECRET_ARG" >/dev/null || die "невалидный --secret"
  fi
  if [[ -n "$BASE_PATH_ARG" ]]; then
    validate_base_path "$BASE_PATH_ARG" >/dev/null || die "невалидный --base-path"
  fi
  if [[ -n "$RELAY_PORT" ]]; then
    local e; e="$(validate_port "$RELAY_PORT")" || die "--port: $e"
  fi
  if [[ -n "$ADMIN_PORT" ]]; then
    local e; e="$(validate_port "$ADMIN_PORT")" || die "--admin-port: $e"
  fi
  if [[ -n "$RELAY_PORT" && -n "$ADMIN_PORT" && "$RELAY_PORT" == "$ADMIN_PORT" ]]; then
    die "relay и admin порты должны различаться"
  fi
  if [[ -n "$WORKERS_ARG" ]]; then
    [[ "$WORKERS_ARG" =~ ^[1-9][0-9]*$ ]] && (( WORKERS_ARG <= 256 )) || die "--workers 1..256"
  fi
  if [[ -n "$MAXCONN_ARG" ]]; then
    [[ "$MAXCONN_ARG" =~ ^[1-9][0-9]*$ ]] || die "--max-connections положительное"
  fi
}

parse_uninstall_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-caddy) KEEP_CADDY=1; shift ;;
      --yes|-y)     ASSUME_YES=1; shift ;;
      *) die "Unknown arg: $1" ;;
    esac
  done
}

# ----------------------------- системные проверки ---------------------------
require_root() { [[ $EUID -eq 0 ]] || die "Запусти через sudo/root"; }
check_arch()    { [[ "$(uname -m)" == "x86_64" ]] || die "Нужен x86_64"; ok "Архитектура: x86_64"; }

check_os() {
  [[ -r /etc/os-release ]] || die "Нет /etc/os-release"
  . /etc/os-release
  case "${ID:-}" in
    ubuntu) ok "OS: ${PRETTY_NAME:-Ubuntu}" ;;
    debian) ok "OS: ${PRETTY_NAME:-Debian}" ;;
    *) warn "Дистрибутив ${ID:-unknown} не проверен" ;;
  esac
}

# ============================================================================
#  УСТАНОВКА / ОБНОВЛЕНИЕ
# ============================================================================

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  info "apt update + базовые пакеты…"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl nftables openssl coreutils dnsutils netcat-openbsd jq git build-essential qrencode
  ok "Базовые пакеты установлены"
}

check_dns() {
  info "A-запись $HOSTNAME_ARG…"
  local ip
  ip="$(dig +short A "$HOSTNAME_ARG" @1.1.1.1 2>/dev/null | tail -n1)"
  [[ -n "$ip" ]] || die "A-запись для $HOSTNAME_ARG не резолвится"
  ok "A-запись $HOSTNAME_ARG → $ip"
}

fetch_repo() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    info "Получаю зафиксированную версию $UPSTREAM_COMMIT"
    git -C "$REPO_DIR" fetch --depth=1 origin "$UPSTREAM_COMMIT"
    git -C "$REPO_DIR" checkout --detach FETCH_HEAD
    git -C "$REPO_DIR" reset --hard "$UPSTREAM_COMMIT"
  else
    info "Клонирую $REPO_URL на зафиксированном commit $UPSTREAM_COMMIT"
    rm -rf "$REPO_DIR"
    install -d -m 0755 "$REPO_DIR"
    git -C "$REPO_DIR" init
    git -C "$REPO_DIR" remote add origin "$REPO_URL"
    git -C "$REPO_DIR" fetch --depth=1 origin "$UPSTREAM_COMMIT"
    git -C "$REPO_DIR" checkout --detach FETCH_HEAD
  fi
  local actual_commit
  actual_commit="$(git -C "$REPO_DIR" rev-parse HEAD)"
  [[ "$actual_commit" == "$UPSTREAM_COMMIT" ]] || die "Версия tproxy-server не совпадает с закреплённым commit"
  [[ -x "$REPO_DIR/deploy/install-mtproxy.sh" ]] || die "install-mtproxy.sh не найден"
  ok "Репозиторий: $(git -C "$REPO_DIR" rev-parse --short HEAD) (pinned)"
}

resolve_base_path() {
  if [[ "$BASE_PATH_ARG" == "none" ]]; then BASE_PATH_ARG=""; return 0; fi
  if [[ -n "$BASE_PATH_ARG" ]]; then return 0; fi
  if [[ -f /etc/tproxy-server/config.json ]]; then
    BASE_PATH_ARG="$(sed -n 's/.*"base_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      /etc/tproxy-server/config.json | head -n1)"
    if [[ -n "$BASE_PATH_ARG" ]]; then
      info "Сохраняю существующий base_path: $BASE_PATH_ARG"
    fi
    return 0
  fi
  command -v base32 >/dev/null || die "base32 (coreutils) нужен для генерации base_path"
  BASE_PATH_ARG="$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z')"
  info "Сгенерирован base_path: $BASE_PATH_ARG"
}

install_caddy() {
  if command -v caddy >/dev/null 2>&1 && caddy version 2>/dev/null | grep -q "v${CADDY_VERSION}"; then
    ok "Caddy ${CADDY_VERSION} уже установлен"
  else
    info "Ставлю Caddy ${CADDY_VERSION}…"
    local archive dir
    archive="$(mktemp /tmp/caddy.XXXXXX.tar.gz)"
    dir="$(mktemp -d /tmp/caddy.XXXXXX)"
    trap 'rm -f "$archive"; rm -rf "$dir"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --output "$archive" \
      "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz"
    test "$(sha512sum "$archive" | awk '{print $1}')" = "$CADDY_SHA512" \
      || die "Caddy checksum mismatch"
    tar -C "$dir" -xzf "$archive"
    install -m 0755 "$dir/caddy" /usr/local/bin/caddy
    rm -f "$archive"; rm -rf "$dir"
    trap - EXIT
    ok "Caddy установлен"
  fi
  if ! id caddy >/dev/null 2>&1; then
    useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
  fi
  install -d -o root -g caddy -m 0750 /etc/caddy
  install -d -o caddy -g caddy -m 0750 /var/lib/caddy
}

install_mtproxy_backend() {
  info "Собираю официальный MTProxy…"
  "$REPO_DIR/deploy/install-mtproxy.sh"
  ok "MTProxy собран"
}

ensure_go() {
  if command -v go >/dev/null 2>&1; then
    local minor
    minor="$(go env GOVERSION | sed -E 's/^go1\.([0-9]+).*/\1/')"
    if [[ "$minor" =~ ^[0-9]+$ ]] && (( minor >= 20 )); then
      GO_BIN="$(command -v go)"
      ok "Go: $(go version)"
      return 0
    fi
  fi
  info "Ставлю Go ${GO_FALLBACK_VERSION}…"
  local archive dir
  archive="$(mktemp /tmp/go.XXXXXX.tar.gz)"
  dir="$(mktemp -d /tmp/go.XXXXXX)"
  trap 'rm -f "$archive"; rm -rf "$dir"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$archive" "https://go.dev/dl/go${GO_FALLBACK_VERSION}.linux-amd64.tar.gz"
  test "$(sha256sum "$archive" | awk '{print $1}')" = "$GO_FALLBACK_SHA256" \
    || die "Go checksum mismatch"
  tar -C "$dir" -xzf "$archive"
  if [[ -e "/opt/go${GO_FALLBACK_VERSION}" ]]; then rm -rf "$dir/go"; else
    mv "$dir/go" "/opt/go${GO_FALLBACK_VERSION}"
  fi
  rm -f "$archive"; rm -rf "$dir"; trap - EXIT
  GO_BIN="/opt/go${GO_FALLBACK_VERSION}/bin/go"
  ok "Go: $("$GO_BIN" version)"
}

build_tproxy() {
  info "Собираю tproxy-server…"
  cd "$REPO_DIR"
  if [[ "$SKIP_TESTS" -ne 1 ]]; then
    info "  go test ./…"
    "$GO_BIN" test ./... || die "go test упал"
  else
    warn "  go test пропущен (--skip-tests)"
  fi
  "$GO_BIN" build -trimpath -ldflags='-s -w' -o /usr/local/bin/tproxy-server ./cmd/tproxy-server
  chown root:root /usr/local/bin/tproxy-server
  chmod 0755 /usr/local/bin/tproxy-server
  cd - >/dev/null
  ok "tproxy-server собран"
}

install_stub_site() {
  if [[ "$INSTALL_SITE" -ne 1 ]]; then info "Сайт пропущен (--no-site)"; return 0; fi
  if [[ -f "$SITE_DIR/index.html" ]]; then
    info "Сайт уже есть в $SITE_DIR — не трогаю"
    : # Существующий сайт и его права не изменяем
    : # Не меняем права пользовательского содержимого

    ok "Существующий сайт сохранён без изменений"
    return 0
  fi
  info "Ставлю сайт-заглушку в $SITE_DIR…"
  mkdir -p "$SITE_DIR/assets"

  cat > "$SITE_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Vibe Studio — код в потоке</title>
<meta name="description" content="Инструменты для тех, кто пишет код в потоке: быстрый фидбек, живые прототипы, ноль трения.">
<link rel="stylesheet" href="/assets/styles.css">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
</head>
<body>
<div class="bg-orb orb-a"></div>
<div class="bg-orb orb-b"></div>

<header class="nav">
  <a class="brand" href="/"><span class="brand-mark">◆</span> Vibe<span class="brand-dim">Studio</span></a>
  <nav><a href="/about.html">Манифест</a><a href="/privacy.html">Приватность</a></nav>
</header>

<main class="hero">
  <p class="kicker">v0.1 · private beta</p>
  <h1>Код в&nbsp;потоке.<br><span class="grad">Без трения.</span></h1>
  <p class="lead">Мы делаем инструменты для вайбкодинга: пишешь мысль —&nbsp;получаешь работающий прототип. Никаких душных настроек, только ритм и&nbsp;фидбек.</p>

  <div class="cta-row">
    <a class="btn btn-primary" href="/about.html">Читать манифест →</a>
    <a class="btn btn-ghost" href="#features">Что внутри</a>
  </div>

  <section id="features" class="cards">
    <article class="card"><div class="card-icon">⚡</div><h3>Мгновенный фидбек</h3><p>Изменения видны сразу, без пересборки вселенной. Пиши —&nbsp;и смотри, как оживает.</p></article>
    <article class="card"><div class="card-icon">🧠</div><h3>Память контекста</h3><p>Студия помнит, что ты делал пять минут назад. Никаких «напомни, о чём мы».</p></article>
    <article class="card"><div class="card-icon">🎛️</div><h3>Один пульт</h3><p>Модели, промпты, диффы — в одном месте. Переключайся, не теряя нить.</p></article>
    <article class="card"><div class="card-icon">🌊</div><h3>Поток важнее</h3><p>Меньше кликов, больше мысли. Интерфейс уходит с дороги, когда ты в ритме.</p></article>
  </section>

  <section class="quote">
    <blockquote>«Вайбкодинг — это когда код пишется сам, а&nbsp;ты только задаёшь настроение.»</blockquote>
    <cite>— из внутреннего манифеста</cite>
  </section>

  <section class="status">
    <h2>Статус студии</h2>
    <ul>
      <li><span class="dot ok"></span> Шлюз студии — в норме</li>
      <li><span class="dot ok"></span> Синхронизация контекста — активна</li>
      <li><span class="dot warn"></span> Публичный бета-доступ — по инвайтам</li>
    </ul>
  </section>
</main>

<footer><p>© <span id="y"></span> Vibe Studio. Сделано в потоке.</p></footer>
<script>document.getElementById('y').textContent=new Date().getFullYear();</script>
</body>
</html>
HTML

  cat > "$SITE_DIR/about.html" <<'HTML'
<!doctype html>
<html lang="ru">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Манифест — Vibe Studio</title>
<link rel="stylesheet" href="/assets/styles.css">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"></head>
<body>
<div class="bg-orb orb-a"></div><div class="bg-orb orb-b"></div>
<header class="nav"><a class="brand" href="/"><span class="brand-mark">◆</span> Vibe<span class="brand-dim">Studio</span></a>
<nav><a href="/">Главная</a><a href="/privacy.html">Приватность</a></nav></header>
<main class="page">
  <p class="kicker">manifesto</p>
  <h1>Мы верим в&nbsp;код, который пишется в&nbsp;потоке</h1>
  <p>Инструменты не должны требовать, чтобы ты сначала выучил их философию. Они должны подхватывать твою мысль и&nbsp;превращать её в&nbsp;работающий прототип.</p>
  <h2>Три принципа</h2>
  <ol class="principles">
    <li><strong>Меньше церемоний.</strong> Ноль конфигов перед первой строкой.</li>
    <li><strong>Фидбек быстрее мысли.</strong> Между «придумал» и&nbsp;«увидел» — секунды.</li>
    <li><strong>Состояние потока — приоритет.</strong> Всё, что мешает, уходит с&nbsp;дороги.</li>
  </ol>
  <p class="muted">Мы в&nbsp;закрытой бете. Если хочешь попробовать —&nbsp;следи за&nbsp;анонсами.</p>
</main>
<footer><p>© <span id="y"></span> Vibe Studio</p></footer>
<script>document.getElementById('y').textContent=new Date().getFullYear();</script>
</body></html>
HTML

  cat > "$SITE_DIR/privacy.html" <<'HTML'
<!doctype html>
<html lang="ru">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Приватность — Vibe Studio</title>
<link rel="stylesheet" href="/assets/styles.css">
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"></head>
<body>
<div class="bg-orb orb-a"></div><div class="bg-orb orb-b"></div>
<header class="nav"><a class="brand" href="/"><span class="brand-mark">◆</span> Vibe<span class="brand-dim">Studio</span></a>
<nav><a href="/">Главная</a><a href="/about.html">Манифест</a></nav></header>
<main class="page">
  <p class="kicker">privacy</p>
  <h1>Приватность</h1>
  <p>Мы не собираем персональные данные посетителей сайта. Серверные журналы содержат только агрегированные метрики без URL и&nbsp;заголовков.</p>
  <p>Если у&nbsp;тебя есть вопросы —&nbsp;пиши: <a href="mailto:hello@example.com">hello@example.com</a>.</p>
  <p class="muted">Обновлено: ноябрь 2026.</p>
</main>
<footer><p>© <span id="y"></span> Vibe Studio</p></footer>
<script>document.getElementById('y').textContent=new Date().getFullYear();</script>
</body></html>
HTML

  cat > "$SITE_DIR/assets/styles.css" <<'CSS'
:root{--bg:#07080f;--bg2:#0e1122;--panel:#121730;--fg:#eef1fb;--muted:#8f9ac4;--acc:#7cf0c0;--acc2:#7aa8ff;--acc3:#c78cff;--border:#1e2547;--radius:18px;--max:1040px}
*{box-sizing:border-box}
html,body{margin:0;height:100%}
body{font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Ubuntu,sans-serif;background:var(--bg);color:var(--fg);line-height:1.6;display:flex;flex-direction:column;min-height:100vh;position:relative;overflow-x:hidden}
a{color:var(--acc2);text-decoration:none}
a:hover{text-decoration:underline}
.bg-orb{position:fixed;border-radius:50%;filter:blur(90px);opacity:.45;z-index:0;pointer-events:none}
.orb-a{width:520px;height:520px;background:radial-gradient(circle,var(--acc2),transparent 70%);top:-200px;right:-120px}
.orb-b{width:480px;height:480px;background:radial-gradient(circle,var(--acc3),transparent 70%);bottom:-220px;left:-160px}
.nav{position:relative;z-index:1;display:flex;align-items:center;justify-content:space-between;max-width:var(--max);margin:0 auto;padding:22px 20px;width:100%}
.brand{font-weight:800;letter-spacing:.2px;color:var(--fg);font-size:1.15rem}
.brand-mark{color:var(--acc);margin-right:4px}
.brand-dim{color:var(--muted);font-weight:600}
.nav nav a{color:var(--muted);margin-left:20px;font-size:.95rem}
.nav nav a:hover{color:var(--fg)}
.hero{position:relative;z-index:1;max-width:var(--max);margin:32px auto 80px;padding:0 20px;flex:1;text-align:center}
.kicker{display:inline-block;font-size:.8rem;letter-spacing:.18em;text-transform:uppercase;color:var(--acc);border:1px solid var(--border);border-radius:999px;padding:6px 14px;margin:0 0 22px;background:rgba(124,240,192,.06)}
.hero h1{font-size:clamp(2.2rem,6vw,4rem);line-height:1.05;margin:0 0 22px;font-weight:800;letter-spacing:-.02em}
.grad{background:linear-gradient(90deg,var(--acc),var(--acc2) 45%,var(--acc3));-webkit-background-clip:text;background-clip:text;color:transparent}
.lead{color:var(--muted);font-size:1.12rem;max-width:620px;margin:0 auto 34px}
.cta-row{display:flex;gap:12px;justify-content:center;flex-wrap:wrap;margin-bottom:56px}
.btn{display:inline-block;padding:12px 22px;border-radius:12px;font-weight:600;font-size:.98rem;transition:transform .15s ease,box-shadow .15s ease,background .15s ease;border:1px solid transparent}
.btn-primary{background:linear-gradient(135deg,var(--acc),var(--acc2));color:#04121a;box-shadow:0 10px 24px rgba(122,168,255,.28)}
.btn-primary:hover{transform:translateY(-2px);box-shadow:0 14px 30px rgba(122,168,255,.38);text-decoration:none}
.btn-ghost{color:var(--fg);border-color:var(--border);background:rgba(255,255,255,.02)}
.btn-ghost:hover{background:rgba(255,255,255,.06);text-decoration:none}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:16px;text-align:left;margin:0 0 64px}
.card{background:linear-gradient(180deg,var(--panel),var(--bg2));border:1px solid var(--border);border-radius:var(--radius);padding:22px;transition:transform .18s ease,border-color .18s ease}
.card:hover{transform:translateY(-4px);border-color:var(--acc2)}
.card-icon{width:38px;height:38px;border-radius:10px;display:flex;align-items:center;justify-content:center;background:rgba(122,168,255,.12);border:1px solid var(--border);margin-bottom:14px;font-size:1.1rem}
.card h3{margin:0 0 8px;font-size:1.05rem;letter-spacing:-.01em}
.card p{margin:0;color:var(--muted);font-size:.95rem}
.quote{border:1px solid var(--border);border-radius:var(--radius);background:linear-gradient(180deg,rgba(122,168,255,.06),transparent);padding:28px 24px;margin:0 0 64px}
.quote blockquote{margin:0 0 10px;font-size:1.25rem;line-height:1.4;font-weight:600;background:linear-gradient(90deg,var(--acc),var(--acc3));-webkit-background-clip:text;background-clip:text;color:transparent}
.quote cite{color:var(--muted);font-style:normal;font-size:.9rem}
.status{text-align:left;max-width:520px;margin:0 auto}
.status h2{font-size:1.05rem;margin:0 0 12px;letter-spacing:.02em;text-transform:uppercase;color:var(--muted)}
.status ul{list-style:none;margin:0;padding:0;display:grid;gap:8px}
.status li{display:flex;align-items:center;color:var(--fg);font-size:.98rem}
.dot{width:9px;height:9px;border-radius:50%;margin-right:10px;flex:0 0 auto}
.dot.ok{background:var(--acc);box-shadow:0 0 10px var(--acc)}
.dot.warn{background:#ffcf6e;box-shadow:0 0 10px #ffcf6e}
.page{position:relative;z-index:1;max-width:760px;margin:32px auto 80px;padding:0 20px;flex:1;width:100%}
.page h1{font-size:clamp(1.8rem,4vw,2.6rem);line-height:1.15;margin:0 0 18px;letter-spacing:-.02em}
.page h2{font-size:1.2rem;margin:28px 0 12px}
.page p{color:var(--muted)}
.page .muted{color:var(--muted);font-size:.92rem}
.principles{margin:0 0 20px;padding-left:1.2em;color:var(--muted)}
.principles li{margin-bottom:10px}
.principles strong{color:var(--fg)}
footer{position:relative;z-index:1;border-top:1px solid var(--border);padding:24px;text-align:center;color:var(--muted);font-size:.9rem;margin-top:auto}
CSS

  cat > "$SITE_DIR/assets/favicon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
<defs><linearGradient id="g" x1="0" x2="1" y1="0" y2="1">
<stop offset="0" stop-color="#7cf0c0"/><stop offset=".5" stop-color="#7aa8ff"/><stop offset="1" stop-color="#c78cff"/>
</linearGradient></defs>
<rect width="64" height="64" rx="16" fill="#07080f"/>
<path d="M32 12 L52 32 L32 52 L12 32 Z" fill="none" stroke="url(#g)" stroke-width="4" stroke-linejoin="round"/>
<circle cx="32" cy="32" r="5" fill="url(#g)"/>
</svg>
SVG

  chown root:root "$SITE_DIR" "$SITE_DIR/index.html"
  chmod 0755 "$SITE_DIR"
  chmod 0644 "$SITE_DIR/index.html"
  ok "Сайт-заглушка установлен в $SITE_DIR"
}

ensure_tproxy_user() {
  if ! id tproxy >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
  fi
}

write_configs() {
  install -d -o root -g tproxy -m 0750 /etc/tproxy-server
  bash "$REPO_DIR/deploy/ensure-token-key.sh"

  cat > /etc/tproxy-server/config.json <<EOF
{
  "public_hostname": "$HOSTNAME_ARG",
  "base_path": "$BASE_PATH_ARG",
  "listen": "127.0.0.1:$RELAY_PORT",
  "admin_listen": "127.0.0.1:$ADMIN_PORT",
  "public_dir": "$SITE_DIR",
  "static_routes": "exact",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}
EOF

  cat > /etc/tproxy-server/profiles.json <<EOF
{"profiles":[{"name":"default","secret":"$SECRET_ARG","backend":"127.0.0.1:2398"}]}
EOF
  chown root:tproxy /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json
  chmod 0640 /etc/tproxy-server/config.json
  chmod 0400 /etc/tproxy-server/profiles.json
  ok "config.json и profiles.json записаны (порты $RELAY_PORT / $ADMIN_PORT)"
}

write_mtproxy_env() {
  local backend_secret="$SECRET_ARG"
  if [[ "$backend_secret" == dd* ]] && (( ${#backend_secret} == 34 )); then
    backend_secret="${backend_secret:2}"
  fi

  local local_address="" public_address="" mtproxy_nat_args=""
  local_address="$(ip -4 route get 149.154.175.50 2>/dev/null |
    sed -n 's/.*[[:space:]]src[[:space:]]\+\([0-9.]\+\).*/\1/p' | head -n1)" || true

  local probe candidate
  for probe in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
    candidate="$(curl --fail --silent --show-error --location --ipv4 --max-time 15 \
      --proto '=https' --proto-redir '=https' --tlsv1.2 "$probe" 2>/dev/null |
      tr -d '[:space:]')" || continue
    if [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      public_address="$candidate"; break
    fi
  done
  if [[ -z "$public_address" ]]; then
    public_address="$(getent ahostsv4 "$HOSTNAME_ARG" 2>/dev/null | awk 'NR==1 {print $1}')" || true
  fi

  if [[ -n "$local_address" && -n "$public_address" && "$local_address" != "$public_address" ]]; then
    mtproxy_nat_args="--nat-info $local_address:$public_address"
    info "NAT: $local_address → $public_address, использую --nat-info"
  elif [[ "$local_address" =~ ^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) && -z "$mtproxy_nat_args" ]]; then
    warn "локальный IP $local_address приватный, публичный не определён."
    warn "Если MTProxy будет молчать — задай MTPROXY_NAT_ARGS в /etc/mtproxy/mtproxy.env"
  fi

  mkdir -p /etc/mtproxy
  cat > /etc/mtproxy/mtproxy.env <<EOF
MTPROXY_SECRET=$backend_secret
MTPROXY_WORKERS=${WORKERS_ARG:-1}
MTPROXY_MAX_CONNECTIONS=${MAXCONN_ARG:-4096}
MTPROXY_NAT_ARGS=$mtproxy_nat_args
EOF
  chown root:mtproxy /etc/mtproxy/mtproxy.env
  chmod 0640 /etc/mtproxy/mtproxy.env
  ok "mtproxy.env записан"
}

install_units() {
  local src dst
  local -A units=(
    ["$REPO_DIR/deploy/tproxy-server.service"]="/etc/systemd/system/tproxy-server.service"
    ["$REPO_DIR/deploy/mtproxy.service"]="/etc/systemd/system/mtproxy.service"
    ["$REPO_DIR/deploy/tproxy-firewall.service"]="/etc/systemd/system/tproxy-firewall.service"
    ["$REPO_DIR/deploy/refresh-mtproxy-config.service"]="/etc/systemd/system/refresh-mtproxy-config.service"
    ["$REPO_DIR/deploy/refresh-mtproxy-config.timer"]="/etc/systemd/system/refresh-mtproxy-config.timer"
  )
  for src in "${!units[@]}"; do
    dst="${units[$src]}"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      info "  юнит без изменений: $(basename "$dst")"
    else
      [[ -f "$dst" ]] && cp -a "$dst" "${dst}.bak.$(date +%s)"
      install -m 0644 "$src" "$dst"
      info "  юнит обновлён: $(basename "$dst")"
    fi
  done
  install -m 0644 "$REPO_DIR/deploy/firewall.nft" /etc/tproxy-server/firewall.nft 2>/dev/null || true
  install -m 0755 "$REPO_DIR/deploy/refresh-mtproxy-config.sh" /usr/local/sbin/refresh-mtproxy-config 2>/dev/null || true
  ok "systemd units синхронизированы"
}

install_caddyfile() {
  if [[ -e /etc/caddy/Caddyfile ]] && ! cmp -s /etc/caddy/Caddyfile "$REPO_DIR/deploy/Caddyfile"; then
    cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-tproxy.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0644 "$REPO_DIR/deploy/Caddyfile" /etc/caddy/Caddyfile
  sed -i -E "s#(reverse_proxy[[:space:]]+127\.0\.0\.1:)[0-9]+#\1${RELAY_PORT}#g" /etc/caddy/Caddyfile
  ok "Caddyfile установлен (reverse_proxy → 127.0.0.1:$RELAY_PORT)"

  if [[ -e /etc/systemd/system/caddy.service ]] && \
     ! cmp -s /etc/systemd/system/caddy.service "$REPO_DIR/deploy/caddy.service"; then
    cp -a /etc/systemd/system/caddy.service \
      "/etc/systemd/system/caddy.service.before-tproxy.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0644 "$REPO_DIR/deploy/caddy.service" /etc/systemd/system/caddy.service
  install -d -m 0755 /etc/systemd/system/caddy.service.d
  cat > /etc/systemd/system/caddy.service.d/tproxy.conf <<EOF
[Service]
Environment=TPROXY_HOSTNAME=$HOSTNAME_ARG
Environment=TPROXY_SITE_ROOT=$SITE_DIR
Environment=ACME_EMAIL=$EMAIL_ARG
EOF
  ok "caddy.service + drop-in установлены"
}

verify_site_permissions() {
  info "Проверяю права на $SITE_DIR…"
  local unreadable=0
  while IFS= read -r -d '' f; do
    if ! sudo -u tproxy test -r "$f"; then
      warn "tproxy не может прочитать: $f"
      unreadable=1
    fi
  done < <(find "$SITE_DIR" -type f -print0)
  if [[ $unreadable -eq 1 ]]; then
    die "tproxy не может читать сайт. Исправь права вручную; установщик не меняет права существующего сайта."
    :
    :
    :
  fi
  ok "Права на сайт в порядке"
}

validate_configs() {
  verify_site_permissions
  info "Валидация config.json…"
  /usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json \
    -profiles-file /etc/tproxy-server/profiles.json -check \
    || die "tproxy-server -check упал"
  info "Валидация Caddyfile…"
  TPROXY_HOSTNAME="$HOSTNAME_ARG" TPROXY_SITE_ROOT="$SITE_DIR" ACME_EMAIL="$EMAIL_ARG" \
    /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
    || die "caddy validate упал"
  ok "Конфиги валидны"
}

start_services() {
  systemctl daemon-reload
  systemctl enable tproxy-firewall.service 2>/dev/null || true
  systemctl enable mtproxy.service 2>/dev/null || true
  systemctl enable tproxy-server.service 2>/dev/null || true
  systemctl enable refresh-mtproxy-config.timer 2>/dev/null || true
  systemctl enable caddy.service 2>/dev/null || true

  systemctl is-active --quiet mtproxy || systemctl start mtproxy
  systemctl is-active --quiet tproxy-firewall || systemctl start tproxy-firewall
  systemctl is-active --quiet tproxy-server || systemctl start tproxy-server
  systemctl is-active --quiet caddy || systemctl start caddy

  ok "Сервисы проверены/запущены"
}

wait_ready() {
  local attempt
  info "Ждём readyz на 127.0.0.1:$ADMIN_PORT (до 30с)…"
  for (( attempt=0; attempt<30; attempt++ )); do
    if curl --fail --silent --output /dev/null "http://127.0.0.1:$ADMIN_PORT/readyz"; then
      ok "relay готов"
      return 0
    fi
    sleep 1
  done
  warn "readyz не ответил за 30с"
  echo
  echo "=== Диагностика ==="
  echo "--- tproxy-server ---"
  systemctl status tproxy-server --no-pager -l 2>/dev/null | head -20 || true
  journalctl -u tproxy-server -n 20 --no-pager 2>/dev/null || true
  echo "--- mtproxy ---"
  systemctl status mtproxy --no-pager -l 2>/dev/null | head -15 || true
  echo "--- порты ---"
  ss -lntp 2>/dev/null | grep -E ":2398|:$RELAY_PORT|:$ADMIN_PORT" || true
  echo "--- права сайта ---"
  ls -la "$SITE_DIR" 2>/dev/null || true
  return 1
}

web_proxy_secret() {
  if [[ -z "$BASE_PATH_ARG" ]]; then printf %s "$SECRET_ARG"; return; fi
  {
    printf '\x70'
    printf "$(printf %s "$SECRET_ARG" | sed 's/../\\x&/g')"
  } | base64 | tr '+/' '-_' | tr -d '=\n'
}

generate_proxy_qr() {
  local link="$1" qr_file="${2:-/etc/tproxy-server/proxy-qr.png}"
  command -v qrencode >/dev/null 2>&1 || die "qrencode не установлен"
  install -d -m 0750 /etc/tproxy-server
  qrencode -o "$qr_file" -t PNG -s 8 -m 2 "$link"
  chmod 0600 "$qr_file"
  chown root:root "$qr_file"
  ok "QR-код сохранён: $qr_file (права 0600)"
}

print_proxy_qr_terminal() {
  local link="$1"
  [[ -n "$link" ]] || return 0
  command -v qrencode >/dev/null 2>&1 || die "qrencode не установлен"
  echo
  echo "QR-код для подключения (отсканируй камерой телефона):"
  qrencode -t ANSIUTF8 -m 2 "$link"
  echo "PNG-файл QR-кода сохранён: /etc/tproxy-server/proxy-qr.png"
  echo
}

print_summary() {
  local client_address="$HOSTNAME_ARG"
  if [[ -n "$BASE_PATH_ARG" ]]; then
    client_address="$HOSTNAME_ARG/$BASE_PATH_ARG"
  fi
  local proxy_secret; proxy_secret="$(web_proxy_secret)"
  local proxy_link="https://t.me/webproxy?server=${client_address//\//%2F}&secret=$proxy_secret"
  : # QR-код не создаётся автоматически
  cat <<EOF

════════════════════════════════════════════════════════════════════
🎉  tproxy-server развёрнут
════════════════════════════════════════════════════════════════════
 Хостнейм:        $HOSTNAME_ARG
 Base path:       ${BASE_PATH_ARG:-<root>}
 Сайт:            https://$HOSTNAME_ARG/
 Relay-порт:      127.0.0.1:$RELAY_PORT
 Admin-порт:      127.0.0.1:$ADMIN_PORT

 Internal secret: $SECRET_ARG
 Proxy server:    $client_address
 Proxy secret:    $proxy_secret
 Proxy link:      $proxy_link
 QR image:        /etc/tproxy-server/proxy-qr.png

 Проверка:
   curl -fsS http://127.0.0.1:$ADMIN_PORT/healthz
   curl -fsS http://127.0.0.1:$ADMIN_PORT/readyz
   curl -fsS https://$HOSTNAME_ARG/

 Firewall — разрешить входящие TCP:
   • 80/tcp  — HTTP (редирект и ACME/Let's Encrypt)
   • 443/tcp — HTTPS (сайт и Web Proxy)

 Не открывать наружу:
   • $RELAY_PORT/tcp — relay слушает только 127.0.0.1
   • $ADMIN_PORT/tcp — admin/health слушает только 127.0.0.1
   • 2398/tcp и 8888/tcp — внутренние порты MTProxy,
     блокируются локальным firewall tproxy_backend.

 Правило относится и к firewall сервера, и к firewall
 провайдера/VPS (Security Group). UDP для этой конфигурации
 открывать не требуется.
════════════════════════════════════════════════════════════════════
EOF
  print_proxy_qr_terminal "$proxy_link"
}


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
    server="$host"; if [[ -n "$base" ]]; then server="$host/$base"; fi
    link="https://t.me/webproxy?server=${server//\//%2F}&secret=$proxy_secret"
    : # QR содержит секрет и не создаётся автоматически
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
QR-код (PNG)          : ${link:+/etc/tproxy-server/proxy-qr.png}
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
  : # QR-код не создаётся автоматически
}

load_existing_config() {
  local cfg=/etc/tproxy-server/config.json profiles=/etc/tproxy-server/profiles.json
  local envf=/etc/mtproxy/mtproxy.env dropin=/etc/systemd/system/caddy.service.d/tproxy.conf v
  [[ -r "$cfg" && -r "$profiles" && -r "$envf" ]] || die "Не найдена полная установленная конфигурация; сначала выполни config"
  command -v jq >/dev/null 2>&1 || die "Для чтения настроек нужен jq"
  v="$(jq -er '.public_hostname | select(type == "string" and length > 0)' "$cfg")" || die "Не удалось прочитать hostname"
  [[ -n "$HOSTNAME_ARG" ]] || HOSTNAME_ARG="$v"
  v="$(jq -r '.base_path // "none"' "$cfg")"; [[ -n "$BASE_PATH_ARG" ]] || BASE_PATH_ARG="$v"
  v="$(jq -r '.listen // "" | split(":")[-1]' "$cfg")"; [[ -n "$RELAY_PORT" ]] || RELAY_PORT="$v"
  v="$(jq -r '.admin_listen // "" | split(":")[-1]' "$cfg")"; [[ -n "$ADMIN_PORT" ]] || ADMIN_PORT="$v"
  v="$(jq -r '.public_dir // empty' "$cfg")"; [[ -n "$v" ]] && SITE_DIR="$v"
  v="$(jq -er '.profiles[0].secret | select(type == "string" and length > 0)' "$profiles")" || die "Не удалось прочитать секрет"
  [[ -n "$SECRET_ARG" ]] || SECRET_ARG="$v"
  if [[ "$SECRET_PREFIX_MODE_SET" -eq 0 ]]; then
    if [[ "$SECRET_ARG" == dd* ]]; then SECRET_PREFIX_MODE="dd"; else SECRET_PREFIX_MODE="plain"; fi
  fi
  v="$(sed -n 's/^MTPROXY_WORKERS=//p' "$envf" | head -n1)"; [[ -n "$WORKERS_ARG" ]] || WORKERS_ARG="${v:-1}"
  v="$(sed -n 's/^MTPROXY_MAX_CONNECTIONS=//p' "$envf" | head -n1)"; [[ -n "$MAXCONN_ARG" ]] || MAXCONN_ARG="${v:-4096}"
  if [[ -r "$dropin" ]]; then
    v="$(sed -n 's/^Environment=ACME_EMAIL=//p' "$dropin" | head -n1)"
    [[ -n "$EMAIL_ARG" ]] || EMAIL_ARG="$v"
  fi
  [[ -n "$EMAIL_ARG" ]] || die "Не удалось прочитать email из $dropin; укажи --email"
  validate_hostname "$HOSTNAME_ARG" >/dev/null || die "Некорректный текущий hostname"
  validate_email "$EMAIL_ARG" >/dev/null || die "Некорректный текущий email"
  validate_port "$RELAY_PORT" >/dev/null || die "Некорректный текущий relay-порт"
  validate_port "$ADMIN_PORT" >/dev/null || die "Некорректный текущий admin-порт"
  validate_secret "$SECRET_ARG" >/dev/null || die "Некорректный текущий секрет"
  validate_base_path "$BASE_PATH_ARG" >/dev/null || die "Некорректный текущий base_path"
}

prompt_update_value() {
  local var="$1" label="$2" current="$3" validator="$4" input err
  while :; do
    read -r -p "$label [$current] (Enter — оставить): " input || die "ввод прерван"
    input="${input:-$current}"
    if err="$("$validator" "$input")"; then printf -v "$var" '%s' "$input"; return 0; fi
    echo "  ⚠️  $err — попробуй ещё раз"
  done
}

prompt_update_port() {
  local var="$1" label="$2" current="$3" input err
  while :; do
    read -r -p "$label [$current] (Enter — оставить): " input || die "ввод прерван"
    input="${input:-$current}"
    if ! err="$(validate_port "$input")"; then echo "  ⚠️  $err"; continue; fi
    if [[ "$input" != "$current" ]] && port_in_use "$input"; then echo "  ⚠️  порт $input уже занят"; continue; fi
    printf -v "$var" '%s' "$input"; return 0
  done
}

prompt_update_secret() {
  local answer s1 s2
  read -r -p "Секрет MTProxy [текущий сохранится] (Enter — оставить, n — заменить): " answer || die "ввод прерван"
  [[ "$answer" =~ ^[Nn]$ ]] || return 0
  while :; do
    read -r -s -p "Новый секрет (Enter — сгенерировать): " s1 || die "ввод прерван"; echo
    if [[ -z "$s1" ]]; then
      SECRET_ARG="$(openssl rand -hex 16)"
      [[ "$SECRET_PREFIX_MODE" == "dd" ]] && SECRET_ARG="dd$SECRET_ARG"
      info "Сгенерирован новый секрет"; return 0
    fi
    read -r -s -p "Повторите секрет: " s2 || die "ввод прерван"; echo
    [[ "$s1" == "$s2" ]] || { echo "  ⚠️  секреты не совпадают"; continue; }
    validate_secret "$s1" >/dev/null || { echo "  ⚠️  Неверный формат секрета"; continue; }
    SECRET_ARG="$s1"; return 0
  done
}

interactive_update_fill() {
  load_existing_config
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ "$RELAY_PORT" != "$ADMIN_PORT" ]] || die "relay- и admin-порты должны различаться"
    return 0
  fi
  echo
  echo "────────────────────────────────────────────────────────────"
  echo "  Обновление tproxy-server"
  echo "  Текущие значения указаны в [квадратных скобках]."
  echo "  Enter — оставить без изменений."
  echo "────────────────────────────────────────────────────────────"
  prompt_update_value HOSTNAME_ARG "Домен" "$HOSTNAME_ARG" validate_hostname
  prompt_update_value EMAIL_ARG "Email Let's Encrypt" "$EMAIL_ARG" validate_email
  prompt_update_value BASE_PATH_ARG "Base path (none — корень)" "$BASE_PATH_ARG" validate_base_path
  prompt_update_port RELAY_PORT "Relay-порт" "$RELAY_PORT"
  prompt_update_port ADMIN_PORT "Admin-порт" "$ADMIN_PORT"
  [[ "$RELAY_PORT" != "$ADMIN_PORT" ]] || die "relay- и admin-порты должны различаться"
  prompt_update_secret

  local input
  while :; do
    read -r -p "MTProxy workers [$WORKERS_ARG] (Enter — оставить): " input || die "ввод прерван"
    input="${input:-$WORKERS_ARG}"
    if [[ "$input" =~ ^[1-9][0-9]*$ ]] && (( input <= 256 )); then WORKERS_ARG="$input"; break; fi
    echo "  ⚠️  workers должен быть числом от 1 до 256"
  done
  while :; do
    read -r -p "MTProxy max connections [$MAXCONN_ARG] (Enter — оставить): " input || die "ввод прерван"
    input="${input:-$MAXCONN_ARG}"
    if [[ "$input" =~ ^[1-9][0-9]*$ ]]; then MAXCONN_ARG="$input"; break; fi
    echo "  ⚠️  max connections должен быть положительным числом"
  done

  echo
  echo "Итоговые параметры:"
  echo "  Домен      : $HOSTNAME_ARG"
  echo "  Email      : $EMAIL_ARG"
  echo "  Base path  : $BASE_PATH_ARG"
  echo "  Relay port : $RELAY_PORT"
  echo "  Admin port : $ADMIN_PORT"
  echo "  Секрет     : сохранён / изменён (значение скрыто)"
  echo "  Workers    : $WORKERS_ARG"
  echo "  Max conns  : $MAXCONN_ARG"
  echo "  Каталог    : $SITE_DIR"
  confirm "Применить обновление?" || die "обновление отменено"
}

run_install() {
  require_root
  check_arch
  check_os
  if [[ "$MODE" == "update" ]]; then
    interactive_update_fill
  else
    interactive_fill
  fi
  install_deps
  check_dns
  fetch_repo
  resolve_base_path
  ensure_tproxy_user
  install_caddy
  install_mtproxy_backend
  ensure_go
  build_tproxy
  install_stub_site
  write_configs
  write_mtproxy_env
  install_units
  install_caddyfile
  validate_configs
  start_services
  wait_ready || die "relay не стал ready"
  print_summary
}

# ============================================================================
#  УДАЛЕНИЕ
# ============================================================================

run_uninstall() {
  require_root
  echo "════════════════════════════════════════════════════════════"
  echo "  Удаление tproxy-server"
  echo "════════════════════════════════════════════════════════════"
  echo "Будет удалено:"
  echo "  • сервисы: tproxy-server, mtproxy, tproxy-firewall, refresh-mtproxy-config"
  echo "  • каталоги: $REPO_DIR, /etc/tproxy-server, /etc/mtproxy; сайт $SITE_DIR сохраняется"
  echo "  • бинарники: /usr/local/bin/tproxy-server, /usr/local/bin/mtproxy"
  echo "  • nftables: inet tproxy_backend"
  echo "  • пользователи: tproxy, mtproxy"
  if [[ $KEEP_CADDY -eq 0 ]]; then
    echo "  • Caddy: будет спрошено отдельно"
  else
    echo "  • Caddy: НЕ будет удалён (--keep-caddy)"
  fi
  echo
  confirm "Продолжить?" || die "отменено"

  local svc
  for svc in tproxy-server mtproxy tproxy-firewall refresh-mtproxy-config.timer refresh-mtproxy-config.service; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/tproxy-server.service
  rm -f /etc/systemd/system/mtproxy.service
  rm -f /etc/systemd/system/tproxy-firewall.service
  rm -f /etc/systemd/system/refresh-mtproxy-config.service
  rm -f /etc/systemd/system/refresh-mtproxy-config.timer
  rm -rf /etc/systemd/system/tproxy-server.service.d
  rm -f /etc/systemd/system/caddy.service.d/tproxy.conf
  systemctl daemon-reload

  nft delete table inet tproxy_backend 2>/dev/null || true

  rm -rf "$REPO_DIR" /etc/tproxy-server /etc/mtproxy
  info "Каталог сайта $SITE_DIR сохранён."
  rm -f /usr/local/bin/tproxy-server /usr/local/bin/mtproxy
  rm -f /usr/local/sbin/refresh-mtproxy-config

  userdel -r tproxy 2>/dev/null || true
  userdel -r mtproxy 2>/dev/null || true

  if [[ $KEEP_CADDY -eq 0 ]]; then
    if confirm "Удалить Caddy?"; then
      systemctl stop caddy 2>/dev/null || true
      systemctl disable caddy 2>/dev/null || true
      rm -f /usr/local/bin/caddy
      rm -rf /etc/caddy /var/lib/caddy
      rm -f /etc/systemd/system/caddy.service
      systemctl daemon-reload
      userdel -r caddy 2>/dev/null || true
    fi
  fi

  ok "Удаление завершено"
}

run_purge() {
  run_uninstall
  echo
  echo "════════════════════════════════════════════════════════════"
  echo "  Удаление пакетов"
  echo "════════════════════════════════════════════════════════════"
  warn "Будут удалены: ${PURGE_PACKAGES[*]}"
  warn "Эти пакеты могут использоваться другими сервисами (Docker, firewall, git-репозитории)."
  confirm "Продолжить?" || die "отменено"

  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y --purge "${PURGE_PACKAGES[@]}" 2>/dev/null || true
  apt-get autoremove -y --purge 2>/dev/null || true
  ok "Пакеты удалены"
}

# ============================================================================
#  МЕНЮ
# ============================================================================

status_command() {
  local failed=0 svc
  for svc in mtproxy tproxy-firewall tproxy-server refresh-mtproxy-config.timer caddy; do
    printf '%-30s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"
    systemctl is-active --quiet "$svc" || failed=1
  done
  echo
  ss -lntp 2>/dev/null || true
  return "$failed"
}
diagnostics_command() {
  echo "=== Состояние служб ==="; status_command || true
  echo "=== Проверка конфигурации ==="
  if [[ -r /etc/tproxy-server/config.json && -r /etc/tproxy-server/profiles.json ]]; then
    jq empty /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json
    stat -c '%a %U:%G %n' /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json
  else warn "Конфигурация tproxy-server не найдена"; fi
  for svc in tproxy-server mtproxy tproxy-firewall caddy; do
    echo "--- $svc ---"; journalctl -u "$svc" -n 30 --no-pager 2>/dev/null || true
  done
}
backup_command() {
  local dest="${1:-/root/tproxy-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  [[ "$dest" = /* ]] || die "Путь backup должен быть абсолютным"
  install -d -m 0700 "$(dirname "$dest")"
  local items=()
  for p in etc/tproxy-server etc/mtproxy etc/caddy/Caddyfile etc/caddy/Caddyfile.d etc/systemd/system/tproxy-server.service etc/systemd/system/mtproxy.service etc/systemd/system/tproxy-firewall.service etc/systemd/system/refresh-mtproxy-config.service etc/systemd/system/refresh-mtproxy-config.timer etc/systemd/system/caddy.service.d/tproxy.conf; do
    [[ ! -e "/$p" ]] || items+=("$p")
  done
  (("${#items[@]}")) || die "Нет файлов конфигурации для резервирования"
  tar -C / -czpf "$dest" "${items[@]}"
  chmod 0600 "$dest"; ok "Резервная копия создана: $dest (0600)"
}
restore_command() {
  local archive="${1:-}"
  [[ -n "$archive" && -f "$archive" ]] || die "Укажи существующий архив: restore /absolute/path/backup.tar.gz"
  [[ "$archive" = /* ]] || die "Путь к архиву должен быть абсолютным"
  local entry
  while IFS= read -r entry; do
    [[ "$entry" != /* && "$entry" != *".."* ]] || die "Небезопасный путь в архиве: $entry"
  done < <(tar -tzf "$archive")
  confirm "Восстановить конфигурации из $archive? Текущие файлы будут перезаписаны." || die "восстановление отменено"
  tar -C / -xzpf "$archive"; systemctl daemon-reload
  ok "Конфигурации восстановлены. Проверь их и перезапусти службы вручную."
}
show_menu() {
  echo
  echo "════════════════════════════════════════════════════════════"
  echo "  tproxy-manager — что делаем?"
  echo "════════════════════════════════════════════════════════════"
  echo "  1) Установить tproxy-server"
  echo "  2) Обновить (без пересоздания существующих сервисов)"
  echo "  3) Удалить tproxy-server (Caddy оставить)"
  echo "  4) Удалить всё, включая пакеты"
  echo "  5) Просмотреть текущую конфигурацию"
  echo "  6) Выход"
  echo
  local choice
  read -r -p "Выбор [1-6]: " choice
  case "$choice" in
    1) MODE=install ;;
    2) MODE=update; SKIP_TESTS=1 ;;
    3) MODE=uninstall; KEEP_CADDY=1 ;;
    4) MODE=purge ;;
    5) MODE=config ;;
    6) exit 0 ;;
    *) die "Неверный выбор" ;;
  esac
}

# ============================================================================
#  MAIN
# ============================================================================

main() {
  if [[ $# -eq 0 ]]; then
    show_menu
  else
    MODE="$1"; shift
    case "$MODE" in
      install)   parse_install_args "$@" ;;
      update)    SKIP_TESTS=1; parse_install_args "$@" ;;
      uninstall) parse_uninstall_args "$@" ;;
      purge)     parse_uninstall_args "$@" ;;
      config|status|diagnostics|backup|restore) : ;;
      -h|--help|help) usage; exit 0 ;;
      *) die "Unknown mode: $MODE (install|update|uninstall|purge|config)" ;;
    esac
  fi

  case "$MODE" in
    install)   run_install ;;
    update)    run_install ;;
    uninstall) run_uninstall ;;
    purge)     run_purge ;;
    config)      require_root; run_config "$@" ;;
    status)      require_root; status_command ;;
    diagnostics) require_root; diagnostics_command ;;
    backup)      require_root; backup_command "$@" ;;
    restore)     require_root; restore_command "$@" ;;
  esac
}

main "$@"
