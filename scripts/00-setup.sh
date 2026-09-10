#!/usr/bin/env bash
# =============================================================================
#  00-setup.sh — первичная установка (без скачивания моделей)
#    1. Проверяет GPU / драйвер / python
#    2. Клонирует ComfyUI и Hunyuan3D-2.1 в vendor/
#    3. Создаёт 3 изолированных venv: vllm / comfyui / hy3d2
#    4. Устанавливает закреплённые версии (под V100)
#    5. Проверяет наличие моделей (только предупреждения)
#
#  Запуск:  ./scripts/00-setup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_config

cd "$ROOT_DIR"

# ------------------------------------------------------------------ проверки
log "=== Этап 1/5: проверка окружения ==="
require_cmd nvidia-smi
require_cmd git
require_cmd curl
require_cmd python3

GPU_COUNT="$(nvidia-smi -L | wc -l | tr -d ' ')"
(( GPU_COUNT >= 4 )) || die "нужно минимум 4 GPU, найдено: $GPU_COUNT"
log "Найдено GPU: $GPU_COUNT"
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader

DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
log "Драйвер NVIDIA: $DRIVER (рекомендуется 550–570; driver r580+/CUDA 13 V100 не поддерживает)"

command -v "$PYTHON_BIN" >/dev/null 2>&1 || die \
  "$PYTHON_BIN не найден. Wheel 1Cat-vLLM требует Python 3.12: Ubuntu 22.04 — deadsnakes PPA (add-apt-repository ppa:deadsnakes/ppa && apt install python3.12 python3.12-venv), Ubuntu 24.04 — из коробки"
"$PYTHON_BIN" -c 'import sys; assert sys.version_info >= (3, 12), "нужен Python >= 3.12 (wheel 1Cat-vLLM: cp312)"'
log "Python: $("$PYTHON_BIN" --version)"

log "=== Этап 2/5: структура каталогов ==="
mkdir -p \
  "models/llm" \
  "models/comfy/checkpoints" \
  "models/comfy/loras" \
  "models/comfy/vae" \
  "models/comfy/text_encoders" \
  "models/comfy/upscale_models" \
  "models/hunyuan3d-2.1" \
  venvs vendor logs pids

clone_if_missing() { # <url> <dest>
  local url="$1" dest="$2"
  if [[ -d "$dest/.git" ]]; then
    log "уже клонировано: $dest (git pull: cd $dest && git pull)"
  else
    log "клонирование: $url -> $dest"
    git clone --depth 1 "$url" "$dest"
  fi
}

log "=== Этап 3/5: репозитории ComfyUI и Hunyuan3D-2 ==="
clone_if_missing "$COMFYUI_REPO_URL" "vendor/ComfyUI"
clone_if_missing "$HY3D_REPO_URL" "vendor/Hunyuan3D-2.1"

# Каталог моделей ComfyUI — симлинками: либо во внешний каталог (COMFYUI_MODELS_ROOT,
# если модели уже скачаны в другом месте), либо в локальный models/comfy
mkdir -p vendor/ComfyUI/models
for d in checkpoints loras vae text_encoders upscale_models clip; do
  if [[ -n "$COMFYUI_MODELS_ROOT" && -d "$COMFYUI_MODELS_ROOT/$d" ]]; then
    ln -sfn "$COMFYUI_MODELS_ROOT/$d" "vendor/ComfyUI/models/$d"
  else
    ln -sfn "$ROOT_DIR/models/comfy/$d" "vendor/ComfyUI/models/$d"
  fi
done
ok "ComfyUI: каталоги моделей привязаны (внешний каталог: ${COMFYUI_MODELS_ROOT:-нет, локальный models/comfy})"

# ------------------------------------------------------------------ venvs
make_venv() { # <name>
  local name="$1"
  if [[ -d "venvs/$name" ]]; then
    log "venv уже есть: venvs/$name"
  else
    log "создаю venv: venvs/$name"
    "$PYTHON_BIN" -m venv "venvs/$name"
  fi
  "venvs/$name/bin/pip" install -q -U pip wheel setuptools
}

log "=== Этап 4/5: виртуальные окружения ==="

# ---- vllm (1Cat-vLLM) ---------------------------------------------------------
if [[ -n "${VLLM_PYTHON:-}" ]]; then
  log "[1/3] vllm: используется внешнее окружение $VLLM_PYTHON (wheel НЕ ставится)"
  "$VLLM_PYTHON" - <<'PYEOF'
import sys
import torch
import vllm
import flash_attn_v100
archs = torch.cuda.get_arch_list()
print(f"  python={sys.version.split()[0]}  torch={torch.__version__}  vllm={vllm.__version__}")
print(f"  archs={archs}")
assert any("sm_70" in a for a in archs), \
    "torch не содержит sm_70 (V100) — во внешнем env стоит неверный torch"
print("  sm_70 (V100) поддерживается, vllm + flash_attn_v100 импортируются — OK")
PYEOF
else
log "[1/3] venvs/vllm: 1Cat-vLLM $ONECAT_VLLM_VERSION (wheel из GitHub Releases)"
make_venv vllm
WHEEL_NAME="1cat_vllm-${ONECAT_VLLM_VERSION}-cp312-cp312-linux_x86_64.whl"
WHEEL_PATH="vendor/wheels/$WHEEL_NAME"
mkdir -p vendor/wheels
if [[ -f "$WHEEL_PATH" ]]; then
  log "wheel уже скачан: $WHEEL_PATH"
else
  log "скачиваю wheel: $ONECAT_VLLM_WHEEL_URL"
  curl -fL --retry 3 --max-time 900 -o "$WHEEL_PATH" "$ONECAT_VLLM_WHEEL_URL"
fi
WHEEL_SHA="$(sha256sum "$WHEEL_PATH" | awk '{print $1}')"
if [[ "$WHEEL_SHA" != "$ONECAT_VLLM_WHEEL_SHA256" ]]; then
  die "SHA256 wheel не совпадает (ожидалось $ONECAT_VLLM_WHEEL_SHA256, получено $WHEEL_SHA). Удалите $WHEEL_PATH и проверьте ONECAT_VLLM_WHEEL_URL/SHA256 в config.env"
fi
ok "SHA256 wheel подтверждён"
# wheel сам фиксирует torch==2.10.0 и все зависимости (пulled с PyPI)
venvs/vllm/bin/pip install "$WHEEL_PATH"
# Дымовая проверка: sm_70 в torch + импорты vllm и FlashAttention-V100
venvs/vllm/bin/python - <<'PYEOF'
import sys
import torch
import vllm
import flash_attn_v100
archs = torch.cuda.get_arch_list()
print(f"  python={sys.version.split()[0]}  torch={torch.__version__}  vllm={vllm.__version__}")
print(f"  archs={archs}")
assert any("sm_70" in a for a in archs), \
    "torch не содержит sm_70 (V100) — установлен неверный torch (нужен из зависимостей wheel 1Cat-vLLM)"
print("  sm_70 (V100) поддерживается, vllm + flash_attn_v100 импортируются — OK")
PYEOF
fi

# ---- venv comfyui ----------------------------------------------------------
log "[2/3] venvs/comfyui: torch==$TORCH_VERSION ($TORCH_CUDA_TAG) + зависимости ComfyUI"
make_venv comfyui
venvs/comfyui/bin/pip install \
  "torch==$TORCH_VERSION" "torchvision==$TORCHVISION_VERSION" \
  --index-url "https://download.pytorch.org/whl/$TORCH_CUDA_TAG"
venvs/comfyui/bin/pip install -r vendor/ComfyUI/requirements.txt

# ---- venv hy3d2 ------------------------------------------------------------
log "[3/3] venvs/hy3d2: torch==$TORCH_VERSION ($TORCH_CUDA_TAG) + зависимости Hunyuan3D-2.1"
make_venv hy3d2
venvs/hy3d2/bin/pip install \
  "torch==$TORCH_VERSION" "torchvision==$TORCHVISION_VERSION" \
  --index-url "https://download.pytorch.org/whl/$TORCH_CUDA_TAG"
# В requirements Hunyuan3D-2.1 старые пины, у которых нет wheel'ей под Python 3.12
# (numpy==1.24.4, pymeshlab==2022.2.post3) — расслабляем только их
sed -e 's/^numpy==1\.24\.4$/numpy==1.26.4/' \
    -e 's/^pymeshlab==2022\.2\.post3$/pymeshlab==2023.12.post3/' \
    vendor/Hunyuan3D-2.1/requirements.txt > vendor/Hunyuan3D-2.1/requirements.py312.txt
venvs/hy3d2/bin/pip install -r vendor/Hunyuan3D-2.1/requirements.py312.txt

# ------------------------------------------------------------- проверка моделей
log "=== Этап 5/5: проверка наличия моделей (скачать — models/README.md) ==="
LLM_PATH="$(abs_path "$LLM_MODEL_DIR")"
model_check "$LLM_PATH/config.json" "LLM для 1Cat-vLLM"
if [[ "${LLM_DFLASH2:-0}" == "1" ]]; then
  model_check "$(abs_path "$LLM_DFLASH2_MODEL")/config.json" "DFlash2 draft (LLM_DFLASH2=1)"
fi
COMFY_ROOT="${COMFYUI_MODELS_ROOT:-models/comfy}"
model_check "$COMFY_ROOT/checkpoints/sd_xl_base_1.0.safetensors" "SDXL base для ComfyUI"
model_check_any "VAE для SDXL" \
  "$COMFY_ROOT/vae/sdxl_vae.safetensors" "$COMFY_ROOT/vae/sdxl-vae-fp16-fix.safetensors"
model_check_any "CLIP-L для SDXL (или авто-докачка ComfyUI)" \
  "$COMFY_ROOT/clip/clip_l.safetensors" "$COMFY_ROOT/text_encoders/clip_l.safetensors"
HY3D_ROOT="$(abs_path "$HY3D_MODEL_DIR")"
model_check "$HY3D_ROOT/$HY3D_SHAPE_SUBFOLDER" "shape-модель Hunyuan3D-2.1 ($HY3D_SHAPE_SUBFOLDER)"
model_check "$HY3D_ROOT/hunyuan3d-paintpbr-v2-1" "PBR-текстуры Hunyuan3D-2.1"
model_check "$HY3D_ROOT/hunyuan3d-vae-v2-1" "VAE Hunyuan3D-2.1"

echo
ok "Установка завершена."
echo "  Дальше:"
echo "   1) скачать модели по манифесту:  $ROOT_DIR/models/README.md"
echo "   2) запустить пайплайн:            $ROOT_DIR/scripts/start-all.sh"
echo "   3) посмотреть статус:             $ROOT_DIR/scripts/status.sh"
