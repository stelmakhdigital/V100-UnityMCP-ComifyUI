#!/usr/bin/env bash
# =============================================================================
#  02-start-comfyui.sh — ComfyUI для 2D-графики (текстуры, UI, иллюстрации)
#    GPU: 2, порт 8188. Каталог моделей: models/comfy (симлинк в ComfyUI)
#    Основные модели: SDXL base (+refiner), SDXL Turbo / Lightning LoRA,
#    VAE fp16-fix, CLIP-L, LoRA под UI. API: http://127.0.0.1:8188/prompt
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_config

cd "$ROOT_DIR"
NAME="comfyui"
PIDFILE="$PID_DIR/$NAME.pid"
URL="http://$LISTEN_HOST:$COMFY_PORT"
HEALTH_URL="http://$HEALTH_HOST:$COMFY_PORT"

if pid_running "$PIDFILE"; then
  warn "$NAME уже запущен (pid $(cat "$PIDFILE"))"
  exit 0
fi
if curl -fsS -o /dev/null --max-time 3 "$HEALTH_URL/system_stats" 2>/dev/null; then
  die "$NAME уже слушает $URL, но pid-файла нет. Убейте процесс вручную (ps aux | grep ComfyUI)"
fi

[[ -d "vendor/ComfyUI" ]] || die "нет vendor/ComfyUI — сначала запустите ./scripts/00-setup.sh"
[[ -d "venvs/comfyui" ]] || die "нет venvs/comfyui — сначала запустите ./scripts/00-setup.sh"

log "Запуск ComfyUI: GPU=$GPU_COMFYUI порт=$COMFY_PORT, лог: $LOG_DIR/comfyui.log"
(
  cd "$ROOT_DIR/vendor/ComfyUI"
  CUDA_VISIBLE_DEVICES="$GPU_COMFYUI" \
  nohup "$ROOT_DIR/venvs/comfyui/bin/python" main.py \
    --listen "$LISTEN_HOST" \
    --port "$COMFY_PORT" \
    --preview-method auto \
    ${COMFYUI_RESERVE_VRAM:+--reserve-vram "$COMFYUI_RESERVE_VRAM"} \
    >> "$LOG_DIR/comfyui.log" 2>&1 &
  echo $! > "$PIDFILE"
)
log "pid: $(cat "$PIDFILE") — ждём готовности..."

if wait_http "$HEALTH_URL/system_stats" 300 "ComfyUI"; then
  ok "ComfyUI работает: веб-интерфейс $URL, API $URL/prompt"
else
  warn "ComfyUI не ответил за 300 с. Конец лога ($LOG_DIR/comfyui.log):"
  tail -n 40 "$LOG_DIR/comfyui.log" >&2 || true
  exit 1
fi
