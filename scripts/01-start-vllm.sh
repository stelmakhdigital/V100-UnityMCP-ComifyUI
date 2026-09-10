#!/usr/bin/env bash
# =============================================================================
#  01-start-vllm.sh — LLM-сервер (1Cat-vLLM) для Unity MCP
#    GPU: из config.env — ПАЙПЛАЙН: 0,1 (TP2) | ПРОДАКШЕН: 0,1,2,3 (TP4, 256k)
#    1Cat-vLLM = vLLM-форк под V100/SM70: FlashAttention-V100, NVFP4 TurboMind,
#    FP8 KV-кэш, DFlash2 спекулятивное декодирование. Запуск `vllm serve`.
#    Флаги = эталонный набор 1Cat (для NVFP4+DFlash2 — без chunked-prefill /
#    prefix-caching: спекулятивное декодирование ведёт своё расписание токенов).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_config

cd "$ROOT_DIR"
NAME="vllm"
PIDFILE="$PID_DIR/$NAME.pid"
URL="http://$LISTEN_HOST:$VLLM_PORT"
HEALTH_URL="http://$HEALTH_HOST:$VLLM_PORT"

if pid_running "$PIDFILE"; then
  warn "$NAME уже запущен (pid $(cat "$PIDFILE")). Остановка: ./scripts/stop-all.sh"
  exit 0
fi
# Остаточный процесс без pid-файла?
if curl -fsS -o /dev/null --max-time 3 "$HEALTH_URL/v1/models" 2>/dev/null; then
  die "$NAME уже слушает $URL, но pid-файла нет. Убейте процесс вручную (ps aux | grep vllm) или смените VLLM_PORT"
fi

# vllm-бинарь: venv проекта или внешнее окружение (VLLM_PYTHON, напр. conda)
if [[ -n "$VLLM_PYTHON" ]]; then
  VLLM_BIN="$(dirname "$VLLM_PYTHON")/vllm"
else
  VLLM_BIN="$ROOT_DIR/venvs/vllm/bin/vllm"
fi
[[ -x "$VLLM_BIN" ]] || die "vllm не найден: $VLLM_BIN (запустите ./scripts/00-setup.sh или укажите VLLM_PYTHON на готовый env)"
LLM_MODEL_PATH="$(abs_path "$LLM_MODEL_DIR")"
[[ -f "$LLM_MODEL_PATH/config.json" ]] || die "модель LLM не найдена: $LLM_MODEL_PATH (скачайте по models/README.md)"

# 256k-контекст при TP<4, как правило, не влезает в VRAM-бюджет (KV 64 слоя × 256 dim)
if (( LLM_MAX_MODEL_LEN > 196608 )) && (( LLM_TP < 4 )); then
  warn "LLM_MAX_MODEL_LEN=$LLM_MAX_MODEL_LEN при LLM_TP=$LLM_TP, скорее всего, не влезет в VRAM (KV-бюджет) — для 256k нужен LLM_TP=4, либо контекст ~131k"
fi

# Опциональные флаги 1Cat-vLLM
EXTRA_FLAGS=()
if [[ "$LLM_KV_CACHE_DTYPE" != "auto" && -n "$LLM_KV_CACHE_DTYPE" ]]; then
  EXTRA_FLAGS+=(--kv-cache-dtype "$LLM_KV_CACHE_DTYPE")
fi
if [[ "$LLM_ENABLE_TOOL_PARSER" == "1" ]]; then
  EXTRA_FLAGS+=(--enable-auto-tool-choice --tool-call-parser "$LLM_TOOL_CALL_PARSER")
  [[ -n "$LLM_REASONING_PARSER" ]] && EXTRA_FLAGS+=(--reasoning-parser "$LLM_REASONING_PARSER")
fi
# enable_thinking (в эталонном наборе 1Cat для Qwen3.8 + DFlash2 — включён)
if [[ "${LLM_ENABLE_THINKING:-0}" == "1" ]]; then
  EXTRA_FLAGS+=(--default-chat-template-kwargs '{"enable_thinking":true}')
fi
# DFlash2 — спекулятивное декодирование (опция; см. config.env)
DFLASH2_ON=0
if [[ "${LLM_DFLASH2:-0}" == "1" ]]; then
  DFLASH2_PATH="$(abs_path "$LLM_DFLASH2_MODEL")"
  [[ -f "$DFLASH2_PATH/config.json" ]] || die \
    "draft-модель DFlash2 не найдена: $DFLASH2_PATH (скачайте по models/README.md или LLM_DFLASH2=0)"
  SPEC_JSON=$(printf '{"method":"dflash","model":"%s","kv_cache_dtype":"auto"}' "$DFLASH2_PATH")
  EXTRA_FLAGS+=(--speculative-config "$SPEC_JSON")
  DFLASH2_ON=1
fi
# Без спекулятивного декодирования — обычный набор: chunked-prefill + prefix-caching
if (( DFLASH2_ON == 0 )); then
  EXTRA_FLAGS+=(--enable-chunked-prefill --enable-prefix-caching)
  EXTRA_FLAGS+=(--max-num-seqs "$LLM_MAX_NUM_SEQS" --max-num-batched-tokens "$LLM_MAX_BATCHED_TOKENS")
fi
# Дополнительные аргументы из config.env (в одну строку)
if [[ -n "${LLM_EXTRA_FLAGS:-}" ]]; then
  read -r -a _extra_flags <<< "$LLM_EXTRA_FLAGS"
  EXTRA_FLAGS+=("${_extra_flags[@]}")
fi

# FP8 KV + NVFP4-чекпоинт: эталонный патч 1Cat — unit-scale e5m2 (игнорируем
# не-unit KV-скейлы из чекпоинта). Идемпотентен.
if [[ "$LLM_KV_CACHE_DTYPE" == fp8_e5m2* ]]; then
  VLLM_PY="$(dirname "$VLLM_BIN")/python"
  "$VLLM_PY" - <<'PYEOF' || warn "e5m2 unit-scale патч не применён — для NVFP4 + fp8 KV сервер может не стартовать"
from pathlib import Path
import vllm
p = Path(vllm.__file__).resolve().parent / "model_executor/layers/attention/attention.py"
text = p.read_text()
old = "if not sm70_flash_v100 or not unit_scale_compatible:"
new = "if not sm70_flash_v100:  # unit e5m2 on mixed NVFP4 (ignore checkpoint KV scales)"
if old in text:
    p.write_text(text.replace(old, new, 1))
    print(f"  e5m2 unit-scale патч применён: {p}")
elif new in text:
    print("  e5m2 unit-scale патч уже применён")
else:
    print("  e5m2 guard не найден в attention.py — патчить нечего (нормально для не-NVFP4 моделей)")
PYEOF
fi

ENV_VARS=("CUDA_VISIBLE_DEVICES=$GPU_VLLM" "TOKENIZERS_PARALLELISM=false")
[[ -n "${VLLM_CUDA_DEVICE_ORDER:-}" ]] && ENV_VARS+=("CUDA_DEVICE_ORDER=$VLLM_CUDA_DEVICE_ORDER")
[[ "${VLLM_SM70_NVFP4_TURBOMIND:-0}" == "1" ]] && ENV_VARS+=("VLLM_SM70_NVFP4_TURBOMIND=1")
[[ "${VLLM_SM70_FLASH_ATTN_V100:-0}" == "1" ]] && ENV_VARS+=("VLLM_SM70_FLASH_ATTN_V100=1")

log "Запуск 1Cat-vLLM: модель=$LLM_MODEL_PATH GPU=$GPU_VLLM TP=$LLM_TP порт=$VLLM_PORT"
log "Контекст=$LLM_MAX_MODEL_LEN, backend=$LLM_ATTENTION_BACKEND, kv=$LLM_KV_CACHE_DTYPE, thinking=$([[ "${LLM_ENABLE_THINKING:-0}" == "1" ]] && echo on || echo off), DFlash2=$([[ "$DFLASH2_ON" == "1" ]] && echo on || echo off)"
log "Лог: $LOG_DIR/vllm.log"

nohup env "${ENV_VARS[@]}" "$VLLM_BIN" serve \
  --model "$LLM_MODEL_PATH" \
  --served-model-name "$LLM_SERVED_NAME" \
  --tensor-parallel-size "$LLM_TP" \
  --dtype float16 \
  --max-model-len "$LLM_MAX_MODEL_LEN" \
  --gpu-memory-utilization "$LLM_GPU_MEM_UTIL" \
  --attention-backend "$LLM_ATTENTION_BACKEND" \
  --trust-remote-code \
  "${EXTRA_FLAGS[@]}" \
  --host "$LISTEN_HOST" \
  --port "$VLLM_PORT" \
  >> "$LOG_DIR/vllm.log" 2>&1 &
echo $! > "$PIDFILE"
log "pid: $(cat "$PIDFILE") — ждём загрузки модели (2-5 мин)..."

if wait_http "$HEALTH_URL/v1/models" 900 "1Cat-vLLM"; then
  ok "1Cat-vLLM работает. Тест:"
  echo
  echo "  curl $URL/v1/chat/completions \\"
  echo "    -H 'Content-Type: application/json' \\"
  echo "    -d '{\"model\": \"$LLM_SERVED_NAME\", \"messages\": [{\"role\": \"user\", \"content\": \"Скажи: Unity MCP готов\"}], \"max_tokens\": 32}'"
  echo
  echo "  Unity MCP подключается к:  $URL/v1   (модель: $LLM_SERVED_NAME)"
else
  warn "$NAME не поднялся за 900 с. Конец лога ($LOG_DIR/vllm.log):"
  tail -n 40 "$LOG_DIR/vllm.log" >&2 || true
  exit 1
fi
