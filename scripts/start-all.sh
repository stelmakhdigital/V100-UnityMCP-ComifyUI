#!/usr/bin/env bash
# =============================================================================
#  start-all.sh — запуск всего пайплайна (vLLM -> ComfyUI -> Hunyuan3D-2)
#  Порядок последовательный: сначала самый долгий (загрузка LLM ~1-3 мин).
#  Повторный запуск безопасен: уже запущенные сервисы пропускаются.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_config

log "Запуск пайплайна V100-UnityMCP-ComifyUI"
log "  GPU 0,1 -> 1Cat-vLLM ($LLM_SERVED_NAME, порт $VLLM_PORT)"
log "  GPU 2   -> ComfyUI (порт $COMFY_PORT)"
log "  GPU 3   -> Hunyuan3D-2 (порт $HY3D_PORT)"
echo

FAILURES=0
for step in 01-start-vllm 02-start-comfyui 03-start-3d; do
  log "### Запускаю $step"
  if bash "$SCRIPT_DIR/$step.sh"; then
    :
  else
    warn "$step завершился с ошибкой (продолжаю остальные)"
    FAILURES=$((FAILURES + 1))
  fi
  echo
done

log "### Статус:"
bash "$SCRIPT_DIR/status.sh"

if (( FAILURES > 0 )); then
  die "$FAILURES сервис(ов) не поднялись — смотрите логи в $LOG_DIR/"
fi
ok "Пайплайн запущен. Unity MCP -> $LISTEN_HOST:$VLLM_PORT/v1 (модель: $LLM_SERVED_NAME)"
