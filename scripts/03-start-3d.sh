#!/usr/bin/env bash
# =============================================================================
#  03-start-3d.sh — Hunyuan3D-2: генерация 3D-моделей (mesh + PBR-текстуры)
#    GPU: 3, порт 8081 (Gradio web-интерфейс + API gradio_client)
#    Модели (локальные, см. models/README.md):
#      hunyuan3d-dit-v2-0  (shape, ~23GB)  + hunyuan3d-paint-v2-0 (texture, ~9GB)
#      + hunyuan3d-vae-v2-0 (~0.8GB) + hunyuan3d-delight-v2-0 (~4GB)
#    Пиковая VRAM ~26GB — в 32GB входит с запасом; страховка: HY3D_LOW_VRAM=1
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
  die "$NAME уже слушает $URL, но pid-файла нет. Убейте процесс вручную (ps aux | grep gradio_app)"
fi

[[ -d "vendor/Hunyuan3D-2" ]] || die "нет vendor/Hunyuan3D-2 — сначала запустите ./scripts/00-setup.sh"
[[ -d "venvs/hy3d2" ]] || die "нет venvs/hy3d2 — сначала запустите ./scripts/00-setup.sh"
[[ -d "$HY3D_MODEL_DIR/$HY3D_SHAPE_SUBFOLDER" ]] || die \
  "shape-модель не найдена: $HY3D_MODEL_DIR/$HY3D_SHAPE_SUBFOLDER (скачайте по models/README.md)"
[[ -d "$HY3D_MODEL_DIR/hunyuan3d-paint-v2-0" ]] || warn "paint-модель не найдена — текстуры не будут генерироваться"

EXTRA_FLAGS=()
if [[ "$HY3D_ENABLE_T23D" == "1" ]]; then EXTRA_FLAGS+=(--enable_t23d); fi
if [[ "$HY3D_ENABLE_FLASHVDM" == "1" ]]; then EXTRA_FLAGS+=(--enable_flashvdm); fi
if [[ "$HY3D_LOW_VRAM" == "1" ]]; then EXTRA_FLAGS+=(--low_vram_mode); fi

log "Запуск Hunyuan3D-2: GPU=$GPU_3D порт=$HY3D_PORT shape=$HY3D_SHAPE_SUBFOLDER"
log "Флаги: ${EXTRA_FLAGS[*]:-<нет>}  Лог: $LOG_DIR/hunyuan3d.log"
log "Загрузка ~36GB моделей займёт 3-10 минут..."
(
  cd "$ROOT_DIR/vendor/Hunyuan3D-2"
  CUDA_VISIBLE_DEVICES="$GPU_3D" \
  nohup "$ROOT_DIR/venvs/hy3d2/bin/python" gradio_app.py \
    --model_path "$ROOT_DIR/$HY3D_MODEL_DIR" \
    --subfolder "$HY3D_SHAPE_SUBFOLDER" \
    --texgen_model_path "$ROOT_DIR/$HY3D_MODEL_DIR" \
    --port "$HY3D_PORT" \
    --host "$LISTEN_HOST" \
    "${EXTRA_FLAGS[@]}" \
    >> "$LOG_DIR/hunyuan3d.log" 2>&1 &
  echo $! > "$PIDFILE"
)
log "pid: $(cat "$PIDFILE") — ждём загрузки моделей (порт откроется, когда всё будет в VRAM)..."

if wait_tcp "$HEALTH_HOST" "$HY3D_PORT" 1800 "Hunyuan3D-2"; then
  ok "Hunyuan3D-2 работает: $URL (Gradio: text/image -> 3D, экспорт glb/obj/ply/stl)"
else
  warn "Hunyuan3D-2 не поднялся за 1800 с. Конец лога ($LOG_DIR/hunyuan3d.log):"
  tail -n 40 "$LOG_DIR/hunyuan3d.log" >&2 || true
  exit 1
fi
