#!/usr/bin/env bash
# =============================================================================
#  lib.sh — общие функции для всех скриптов V100-UnityMCP-ComifyUI
# =============================================================================
if [[ -n "${__LIB_SH_LOADED:-}" ]]; then return 0; fi
__LIB_SH_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/config.env"
LOG_DIR="$ROOT_DIR/logs"
PID_DIR="$ROOT_DIR/pids"

# --- цвета (только если вывод в TTY) ---
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RST=""
fi

log()  { echo "${C_BLUE}[$(date +%H:%M:%S)]${C_RST} $*"; }
ok()   { echo "${C_GREEN}[$(date +%H:%M:%S)] OK${C_RST} $*"; }
warn() { echo "${C_YELLOW}[$(date +%H:%M:%S)] WARN${C_RST} $*"; }
die()  { echo "${C_RED}[$(date +%H:%M:%S)] ОШИБКА:${C_RST} $*" >&2; exit 1; }

# Загрузка config.env (создаёт logs/ и pids/)
load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "не найден конфиг: $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  mkdir -p "$LOG_DIR" "$PID_DIR"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "не найдена команда: $1"
}

# Жив ли процесс из pid-файла?
pid_running() {
  local pidfile="$1" pid
  [[ -f "$pidfile" ]] || return 1
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Остановить процесс по pid-файлу (SIGTERM, потом SIGKILL)
stop_pidfile() {
  local name="$1" pidfile="$PID_DIR/$1.pid" pid
  if pid_running "$pidfile"; then
    pid="$(cat "$pidfile")"
    log "Останавливаю $name (pid $pid)..."
    kill -TERM "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      warn "$name не остановился за 30 c — SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
    ok "$name остановлен"
  else
    rm -f "$pidfile"
    log "$name не запущен"
  fi
}

# Дождаться HTTP 200: wait_http <url> <timeout_s> <name>
wait_http() {
  local url="$1" timeout="${2:-300}" name="${3:-service}" i
  for ((i = 0; i <= timeout; i += 5)); do
    if curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; then
      ok "$name готов: $url"
      return 0
    fi
    sleep 5
  done
  warn "$name не ответил на $url за ${timeout} с"
  return 1
}

# Дождаться TCP-порта: wait_tcp <host> <port> <timeout_s> <name>
wait_tcp() {
  local host="$1" port="$2" timeout="${3:-300}" name="${4:-service}" i
  for ((i = 0; i <= timeout; i += 5)); do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
      ok "$name готов: tcp $host:$port"
      return 0
    fi
    sleep 5
  done
  warn "$name не открыл tcp $host:$port за ${timeout} с"
  return 1
}

# Проверка наличия пути (файла/каталога): model_check <path> <описание>
# path может быть относительным (относительно ROOT_DIR) или абсолютным
model_check() {
  local path="$1" desc="$2" target
  if [[ "$path" = /* ]]; then target="$path"; else target="$ROOT_DIR/$path"; fi
  if [[ -e "$target" ]]; then
    ok "модель на месте: $path"
  else
    warn "модель НЕ скачана: $path ($desc) — см. models/README.md"
  fi
}

# model_check_any <описание> <path>... — проходит, если существует хотя бы один путь
model_check_any() {
  local desc="$1"; shift
  local p target hit=""
  for p in "$@"; do
    if [[ "$p" = /* ]]; then target="$p"; else target="$ROOT_DIR/$p"; fi
    if [[ -e "$target" ]]; then hit="$p"; break; fi
  done
  if [[ -n "$hit" ]]; then
    ok "модель на месте: $hit"
  else
    warn "модель НЕ скачана: $* ($desc) — см. models/README.md"
  fi
}

# Относительный путь -> абсолютный (значения из config.env могут быть и так и так)
abs_path() {
  if [[ "$1" = /* ]]; then echo "$1"; else echo "$ROOT_DIR/$1"; fi
}
