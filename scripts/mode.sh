#!/usr/bin/env bash
# =============================================================================
#  mode.sh — режим распределения GPU
#
#    pipeline (дефолт, = чистый config.env):
#      LLM 1Cat-vLLM TP2 на GPU 0,1 (контекст из config.env, ~131k)
#      ComfyUI на GPU 2, Hunyuan3D-2.1 на GPU 3
#    prod (оверлей mode.env):
#      LLM 1Cat-vLLM TP4 на GPU 0,1,2,3, контекст 262144 (256k)
#      ComfyUI и 3D НЕ запущены
#
#    ./scripts/mode.sh            — текущий режим + статус сервисов
#    ./scripts/mode.sh prod       — переключиться на prod
#    ./scripts/mode.sh pipeline   — переключиться на pipeline
#
#  Переключение = стоп всех сервисов -> ожидание освобождения VRAM ->
#  запись/удаление mode.env -> старт нужного набора -> статус.
#  Идемпотентно: повторное переключение в активный режим ничего не делает.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_config

MODE_FILE="$ROOT_DIR/mode.env"

# Контент оверлея для prod-режима (остальные параметры — из config.env)
MODE_PROD_BLOCK='# режим: prod — LLM TP4 на GPU 0,1,2,3, контекст 256k (ComfyUI/3D не запущены)
# Генерировано scripts/mode.sh — не редактируйте вручную, переключайтесь через mode.sh
GPU_VLLM="0,1,2,3"
LLM_TP=4
LLM_MAX_MODEL_LEN=262144'

current_mode() {
  if [[ -f "$MODE_FILE" ]]; then echo "prod"; else echo "pipeline"; fi
}

wait_vram_free() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  local i busy
  for i in $(seq 1 12); do
    sleep 2
    busy="$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null \
      | awk -F', ' '$2 > 2048 {print $1}' | tr '\n' ' ' || true)"
    if [[ -z "$busy" ]]; then
      ok "VRAM на всех GPU освобождён"
      return 0
    fi
  done
  warn "VRAM ещё занят на GPU: $busy (после 24 c) — проверьте nvidia-smi; сервис может не стартовать"
  return 0
}

case "${1:-status}" in
  ""|status)
    echo
    log "Текущий режим: $(current_mode)"
    if [[ -f "$MODE_FILE" ]]; then
      grep -E '^(GPU_VLLM|LLM_TP|LLM_MAX_MODEL_LEN)=' "$MODE_FILE" | sed 's/^/    mode.env: /'
    else
      log "mode.env отсутствует — действуют дефолты config.env (pipeline)"
    fi
    bash "$SCRIPT_DIR/status.sh"
    ;;
  prod|pipeline)
    target="$1"
    cur="$(current_mode)"
    if [[ "$target" == "$cur" ]]; then
      log "Уже в режиме $target. Перезапуск сервисов: ./scripts/stop-all.sh && ./scripts/start-all.sh"
      bash "$SCRIPT_DIR/status.sh"
      exit 0
    fi
    echo
    log "Переключение режима: $cur -> $target (остановлю все сервисы)"
    bash "$SCRIPT_DIR/stop-all.sh"
    wait_vram_free
    if [[ "$target" == "prod" ]]; then
      printf '%s\n' "$MODE_PROD_BLOCK" > "$MODE_FILE"
      ok "mode.env записан (prod: LLM TP4, GPU 0,1,2,3, 256k)"
      bash "$SCRIPT_DIR/01-start-vllm.sh"
      log "ComfyUI и Hunyuan3D-2 в prod-режиме не запускаются (карты заняты LLM)"
    else
      rm -f "$MODE_FILE"
      ok "mode.env удалён (pipeline: LLM TP2 на GPU 0,1 + ComfyUI + Hunyuan3D-2.1)"
      bash "$SCRIPT_DIR/start-all.sh"
    fi
    ;;
  *)
    die "неизвестная команда: $1 (используйте: prod | pipeline | status)"
    ;;
esac
