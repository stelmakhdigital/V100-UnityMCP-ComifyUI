#!/usr/bin/env bash
# =============================================================================
#  02-start-comfyui.sh — ComfyUI для 2D-графики (текстуры, UI, иллюстрации)
#    GPU: 2, порт 8188. API: http://127.0.0.1:8188/prompt
#    Режимы:
#      - COMFYUI_PATH задан  -> ваша существующая установка (custom_nodes,
#        workflows, comfy-models.json) — запускаем её main.py вашим python'ом;
#      - иначе -> vendor/ComfyUI + venvs/comfyui из 00-setup.sh.
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
  die "$NAME уже слушает $URL, но pid-файла нет. Убейте процесс вручную (ps aux | grep -i comfy)"
fi

COMFY_ARGS=(--listen "$LISTEN_HOST" --port "$COMFY_PORT" --preview-method auto)
if [[ -n "$COMFYUI_RESERVE_VRAM" ]]; then
  COMFY_ARGS+=(--reserve-vram "$COMFYUI_RESERVE_VRAM")
fi

if [[ -n "$COMFYUI_PATH" ]]; then
  # --- внешний режим: существующая установка ComfyUI ---
  COMFY_DIR="$COMFYUI_PATH"
  [[ -f "$COMFY_DIR/main.py" ]] || die "COMFYUI_PATH: не найден main.py: $COMFY_DIR"
  resolve_repo_python "${COMFYUI_PYTHON:-}" "$COMFY_DIR" || \
    die "COMFYUI_PYTHON: python не найден (укажите COMFYUI_PYTHON; искомые пути: $COMFY_DIR/.venv/bin/python, $COMFY_DIR/venv/bin/python)"
  if [[ -f "$COMFY_DIR/comfy-models.json" ]]; then
    COMFY_ARGS+=(--extra-model-paths-config "$COMFY_DIR/comfy-models.json")
  fi
  COMFY_PY="$REPO_PY"
  log "Запуск ComfyUI (существующая установка): $COMFY_DIR, python=$COMFY_PY, GPU=$GPU_COMFYUI, порт=$COMFY_PORT"
else
  # --- внутренний режим: vendor/ComfyUI + venvs/comfyui из setup ---
  COMFY_DIR="$ROOT_DIR/vendor/ComfyUI"
  [[ -d "$COMFY_DIR" ]] || die "нет vendor/ComfyUI — сначала запустите ./scripts/00-setup.sh"
  [[ -d "$ROOT_DIR/venvs/comfyui" ]] || die "нет venvs/comfyui — сначала запустите ./scripts/00-setup.sh"
  COMFY_PY="$ROOT_DIR/venvs/comfyui/bin/python"
  log "Запуск ComfyUI (vendor): GPU=$GPU_COMFYUI, порт=$COMFY_PORT"
fi
log "Лог: $LOG_DIR/comfyui.log"

(
  cd "$COMFY_DIR"
  CUDA_VISIBLE_DEVICES="$GPU_COMFYUI" \
  nohup "$COMFY_PY" main.py "${COMFY_ARGS[@]}" \
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
