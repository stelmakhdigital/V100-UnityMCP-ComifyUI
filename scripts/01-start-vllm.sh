#!/usr/bin/env bash
# =============================================================================
#  01-start-vllm.sh — LLM-сервер (1Cat-vLLM) для Unity MCP
#    GPU: 0,1 (tensor-parallel=2), порт 8000, OpenAI-совместимый API
#    1Cat-vLLM = vLLM-форк под V100/SM70: FlashAttention-V100, FP8 KV-кэш,
#    оптимизации Volta. Запуск через `vllm serve` (CLI совместим с vLLM).
#    V100-специфика: fp16 (на Volta нет bf16), backend FLASH_ATTN_V100.
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

[[ -d "venvs/vllm" ]] || die "нет venvs/vllm — сначала запустите ./scripts/00-setup.sh"
LLM_MODEL_PATH="$(abs_path "$LLM_MODEL_DIR")"
[[ -f "$LLM_MODEL_PATH/config.json" ]] || die "модель LLM не найдена: $LLM_MODEL_PATH (скачайте по models/README.md)"

# Опциональные флаги 1Cat-vLLM
EXTRA_FLAGS=()
if [[ "$LLM_KV_CACHE_DTYPE" != "auto" && -n "$LLM_KV_CACHE_DTYPE" ]]; then
  EXTRA_FLAGS+=(--kv-cache-dtype "$LLM_KV_CACHE_DTYPE")
fi
if [[ "$LLM_ENABLE_TOOL_PARSER" == "1" ]]; then
  EXTRA_FLAGS+=(--enable-auto-tool-choice --tool-call-parser "$LLM_TOOL_CALL_PARSER")
  [[ -n "$LLM_REASONING_PARSER" ]] && EXTRA_FLAGS+=(--reasoning-parser "$LLM_REASONING_PARSER")
fi
# DFlash2 — спекулятивное декодирование (опционально, см. config.env)
if [[ "${LLM_DFLASH2:-0}" == "1" ]]; then
  DFLASH2_PATH="$(abs_path "$LLM_DFLASH2_MODEL")"
  [[ -f "$DFLASH2_PATH/config.json" ]] || die \
    "draft-модель DFlash2 не найдена: $DFLASH2_PATH (скачайте по models/README.md или LLM_DFLASH2=0)"
  SPEC_JSON=$(printf '{"method":"dflash","model":"%s","kv_cache_dtype":"auto"}' "$DFLASH2_PATH")
  EXTRA_FLAGS+=(--speculative-config "$SPEC_JSON")
fi
# Дополнительные аргументы из config.env (в одну строку)
if [[ -n "${LLM_EXTRA_FLAGS:-}" ]]; then
  read -r -a _extra_flags <<< "$LLM_EXTRA_FLAGS"
  EXTRA_FLAGS+=("${_extra_flags[@]}")
fi

log "Запуск 1Cat-vLLM: модель=$LLM_MODEL_DIR GPU=$GPU_VLLM TP=$LLM_TP порт=$VLLM_PORT"
log "Контекст=$LLM_MAX_MODEL_LEN, gpu-mem-util=$LLM_GPU_MEM_UTIL, backend=$LLM_ATTENTION_BACKEND, kv=$LLM_KV_CACHE_DTYPE"
log "Лог: $LOG_DIR/vllm.log"

CUDA_VISIBLE_DEVICES="$GPU_VLLM" \
TOKENIZERS_PARALLELISM=false \
nohup venvs/vllm/bin/vllm serve \
  --model "$LLM_MODEL_PATH" \
  --served-model-name "$LLM_SERVED_NAME" \
  --tensor-parallel-size "$LLM_TP" \
  --dtype float16 \
  --max-model-len "$LLM_MAX_MODEL_LEN" \
  --gpu-memory-utilization "$LLM_GPU_MEM_UTIL" \
  --max-num-seqs "$LLM_MAX_NUM_SEQS" \
  --max-num-batched-tokens "$LLM_MAX_BATCHED_TOKENS" \
  --attention-backend "$LLM_ATTENTION_BACKEND" \
  --enable-chunked-prefill \
  --enable-prefix-caching \
  "${EXTRA_FLAGS[@]}" \
  --host "$LISTEN_HOST" \
  --port "$VLLM_PORT" \
  >> "$LOG_DIR/vllm.log" 2>&1 &
echo $! > "$PIDFILE"
log "pid: $(cat "$PIDFILE") — ждём загрузки модели (1-3 мин)..."

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
