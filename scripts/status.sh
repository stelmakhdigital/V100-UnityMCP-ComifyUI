#!/usr/bin/env bash
# =============================================================================
#  status.sh — состояние пайплайна: GPU, процессы, HTTP-эндпоинты
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_config

echo "${C_BOLD}=== GPU ===${C_RST}"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu \
    --format=csv,noheader | awk -F', ' \
    '{printf "  GPU %s: %s | VRAM: %s / %s | load: %s | %s\n", $1, $2, $3, $4, $5, $6}' || true
  echo
  echo "  Процессы:"
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader \
    | awk -F', ' '{printf "    pid %s: %s (%s)\n", $1, $2, $3}' || echo "    (нет)"
else
  echo "  nvidia-smi не найден (скрипт запущен не на GPU-машине?)"
fi

echo
echo "${C_BOLD}=== Сервисы ===${C_RST}"

service_status() { # <name> <pidfile> <check-url> <hint>
  local name="$1" pidfile="$PID_DIR/$1.pid" url="$3"
  local state="STOPPED" pid=""
  if pid_running "$pidfile"; then
    pid="$(cat "$pidfile")"
    if curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; then
      state="RUNNING"
    else
      state="UP? (pid $pid, нет HTTP-ответа — возможно, ещё грузится)"
    fi
  fi
  case "$state" in
    RUNNING*) echo "  ${C_GREEN}● $state${C_RST}  $name  (pid ${pid:-?})  $4" ;;
    *)        echo "  ${C_RED}● $state${C_RST}   $name  — $4" ;;
  esac
}

service_status vllm    vllm    "http://$HEALTH_HOST:$VLLM_PORT/v1/models"     "LLM для Unity MCP"
service_status comfyui comfyui "http://$HEALTH_HOST:$COMFY_PORT/system_stats" "2D-графика"
service_status hy3d2   hy3d2   "http://$HEALTH_HOST:$HY3D_PORT/"               "3D-модели"

echo
echo "${C_BOLD}=== Быстрые проверки ===${C_RST}"
if curl -fsS -o /dev/null --max-time 5 "http://$HEALTH_HOST:$VLLM_PORT/v1/models" 2>/dev/null; then
  echo "  vLLM  /v1/models            -> 200 OK"
else
  echo "  vLLM  /v1/models            -> недоступен"
fi
if curl -fsS -o /dev/null --max-time 5 "http://$HEALTH_HOST:$COMFY_PORT/system_stats" 2>/dev/null; then
  echo "  ComfyUI /system_stats       -> 200 OK"
else
  echo "  ComfyUI /system_stats       -> недоступен"
fi
if (exec 3<>"/dev/tcp/$HEALTH_HOST/$HY3D_PORT") 2>/dev/null; then
  echo "  Hunyuan3D-2 tcp:$HY3D_PORT  -> открыт"
else
  echo "  Hunyuan3D-2 tcp:$HY3D_PORT  -> закрыт"
fi
echo
echo "Логи: $LOG_DIR/ (vllm.log, comfyui.log, hunyuan3d.log)"
