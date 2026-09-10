#!/usr/bin/env bash
# =============================================================================
#  stop-all.sh — остановка всех сервисов пайплайна
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_config

log "Остановка пайплайна (Hunyuan3D-2 -> ComfyUI -> 1Cat-vLLM)"
stop_pidfile hy3d2
stop_pidfile comfyui
stop_pidfile vllm

# Остатки без pid-файлов (на всякий случай). Паттерны покрывают и внутренние
# запуски (venvs/*/vendor/*), и внешние установки (COMFYUI_PATH/HY3D_PATH, напр.
# ~/apps/ComfyUI/.venv/bin/python main.py, ~/apps/Hunyuan3D-2.1/venv/bin/python api_server.py).
for pat in "vllm serve" "vllm.entrypoints.openai.api_server" "comfyui.*main\.py" "gradio_app\.py" "api_server\.py"; do
  pids="$(pgrep -if "$pat" 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    warn "Найдены процессы без pid-файла ($pat): $pids — останавливаю"
    kill -TERM $pids 2>/dev/null || true
  fi
done

echo
ok "Все сервисы остановлены. VRAM освобождён."
