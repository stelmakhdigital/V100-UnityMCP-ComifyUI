#!/usr/bin/env bash
# =============================================================================
#  03-start-3d.sh — Hunyuan3D-2.1: генерация 3D-моделей (mesh + PBR-текстуры)
#    GPU: 3, порт HY3D_PORT.
#    Режимы:
#      - HY3D_PATH задан -> ваша существующая установка: запускаем
#        <path>/api_server.py (REST: POST /generate, поле "texture": true)
#        вашим python'ом;
#      - иначе -> vendor/Hunyuan3D-2.1 + gradio_app.py (Gradio web) из setup.
#    Модели (~14GB вместе): hunyuan3d-dit-v2-1 (shape) + hunyuan3d-paintpbr-v2-1
#    + hunyuan3d-vae-v2-1. Пиковая VRAM ~20–26GB; страховка: HY3D_LOW_VRAM=1.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_config

cd "$ROOT_DIR"
NAME="hy3d2"
PIDFILE="$PID_DIR/$NAME.pid"
URL="http://$LISTEN_HOST:$HY3D_PORT"

if pid_running "$PIDFILE"; then
  warn "$NAME уже запущен (pid $(cat "$PIDFILE"))"
  exit 0
fi
if curl -fsS -o /dev/null --max-time 3 "http://$HEALTH_HOST:$HY3D_PORT/" 2>/dev/null; then
  die "$NAME уже слушает $URL, но pid-файла нет. Убейте процесс вручную (ps aux | grep -E 'gradio_app|api_server')"
fi

HY3D_ROOT="$(abs_path "$HY3D_MODEL_DIR")"
[[ -d "$HY3D_ROOT/$HY3D_SHAPE_SUBFOLDER" ]] || die \
  "shape-модель не найдена: $HY3D_ROOT/$HY3D_SHAPE_SUBFOLDER (скачайте по models/README.md)"
[[ -d "$HY3D_ROOT/hunyuan3d-paintpbr-v2-1" ]] || warn "paintpbr-модель не найдена — текстуры не будут генерироваться"

ENV_VARS=("CUDA_VISIBLE_DEVICES=$GPU_3D")
[[ -n "${HY3D_U2NET_HOME:-}" ]] && ENV_VARS+=("U2NET_HOME=$HY3D_U2NET_HOME")

if [[ -n "$HY3D_PATH" ]]; then
  # --- внешний режим: существующая установка (REST api_server.py) ---
  HY3D_DIR="$HY3D_PATH"
  [[ -f "$HY3D_DIR/api_server.py" ]] || die "HY3D_PATH: не найден api_server.py: $HY3D_DIR"
  resolve_repo_python "${HY3D_PYTHON:-}" "$HY3D_DIR" || \
    die "HY3D_PYTHON: python не найден (укажите HY3D_PYTHON; искомые пути: $HY3D_DIR/.venv/bin/python, $HY3D_DIR/venv/bin/python)"
  HY3D_PY="$REPO_PY"
  # api_server.py создаёт лог ДО разбора аргументов — каталог кэша должен быть
  mkdir -p "$HY3D_DIR/gradio_cache"
  API_ARGS=(--host "$LISTEN_HOST" --port "$HY3D_PORT" --device cuda --model_path "$HY3D_ROOT")
  log "Запуск Hunyuan3D-2.1 (существующая установка, REST): $HY3D_DIR, python=$HY3D_PY, GPU=$GPU_3D, порт=$HY3D_PORT"
else
  # --- внутренний режим: vendor + gradio_app.py ---
  HY3D_DIR="$ROOT_DIR/vendor/Hunyuan3D-2.1"
  [[ -d "$HY3D_DIR" ]] || die "нет vendor/Hunyuan3D-2.1 — сначала запустите ./scripts/00-setup.sh"
  [[ -d "$ROOT_DIR/venvs/hy3d2" ]] || die "нет venvs/hy3d2 — сначала запустите ./scripts/00-setup.sh"
  HY3D_PY="$ROOT_DIR/venvs/hy3d2/bin/python"
  API_ARGS=(
    --model_path "$HY3D_ROOT"
    --subfolder "$HY3D_SHAPE_SUBFOLDER"
    --texgen_model_path "$HY3D_ROOT"
    --port "$HY3D_PORT"
    --host "$LISTEN_HOST"
  )
  if [[ "$HY3D_ENABLE_T23D" == "1" ]]; then API_ARGS+=(--enable_t23d); fi
  if [[ "$HY3D_ENABLE_FLASHVDM" == "1" ]]; then API_ARGS+=(--enable_flashvdm); fi
  if [[ "$HY3D_LOW_VRAM" == "1" ]]; then API_ARGS+=(--low_vram_mode); fi
  log "Запуск Hunyuan3D-2.1 (vendor, Gradio): GPU=$GPU_3D, порт=$HY3D_PORT, shape=$HY3D_SHAPE_SUBFOLDER"
fi
HY3D_ENTRY="gradio_app.py"
if [[ -n "$HY3D_PATH" ]]; then HY3D_ENTRY="api_server.py"; fi
log "Лог: $LOG_DIR/hunyuan3d.log — загрузка ~14GB моделей займёт 2–5 минут..."

(
  cd "$HY3D_DIR"
  nohup env "${ENV_VARS[@]}" "$HY3D_PY" "$HY3D_ENTRY" \
    "${API_ARGS[@]}" \
    >> "$LOG_DIR/hunyuan3d.log" 2>&1 &
  echo $! > "$PIDFILE"
)
log "pid: $(cat "$PIDFILE") — ждём загрузки моделей (порт откроется, когда всё будет в VRAM)..."

if wait_tcp "$HEALTH_HOST" "$HY3D_PORT" 1800 "Hunyuan3D-2.1"; then
  if [[ -n "$HY3D_PATH" ]]; then
    ok "Hunyuan3D-2.1 работает: REST $URL (POST /generate, \"texture\": true -> GLB)"
  else
    ok "Hunyuan3D-2.1 работает: $URL (Gradio: text/image -> 3D, экспорт glb/obj/ply/stl)"
  fi
else
  warn "Hunyuan3D-2.1 не поднялся за 1800 с. Конец лога ($LOG_DIR/hunyuan3d.log):"
  tail -n 40 "$LOG_DIR/hunyuan3d.log" >&2 || true
  exit 1
fi
