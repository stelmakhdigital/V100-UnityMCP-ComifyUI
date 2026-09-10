# Манифест моделей — что скачать и куда положить

Все пути относительны от корня проекта. Скачивайте в удобное время —
скрипты запуска работают и до момента загрузки моделей (предупредят, чего не хватает).

Общий объём: **~96 GB**. Свободное место на диске (вместе с venvs): **~150 GB**.

Инструмент (одноразово):
```bash
pip install -U "huggingface_hub[cli]"
# Если репозитории gated (требуют согласия) — huggingface-cli login с токеном HF
```

---

## 1. LLM для Unity MCP (1Cat-vLLM, GPU 0–1) — ~19–29 GB

| Что | Откуда | Куда положить |
|---|---|---|
| **Qwen3.8-27B-QUASAR-NVFP4** (основной; dense 27B, QAT NVFP4, ~19.2 GB) | `QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4` | `models/llm/Qwen3.8-27B-QUASAR-NVFP4/` |
| DFlash2 draft (опц., для спекулятивного декодирования; ~3.6 GB) | `incoai/Qwen3.8-27B-DFlash2` | `models/llm/Qwen3.8-27B-DFlash2/` |
| Qwen3.8-27B-FP8 (альтернатива, офиц. FP8; ~28.8 GB) | `Qwen/Qwen3.8-27B-FP8` | `models/llm/Qwen3.8-27B-FP8/` |
| Qwen3-30B-A3B-Instruct-2507-FP8 (альтернатива, MoE active 3.3B; ~29.1 GB) | `Qwen/Qwen3-30B-A3B-Instruct-2507-FP8` | `models/llm/Qwen3-30B-A3B-Instruct-2507-FP8/` |
| Qwen3-14B-Instruct-2507 (запасной: dense, без квантования; ~29.6 GB) | `Qwen/Qwen3-14B-Instruct-2507` | `models/llm/Qwen3-14B-Instruct-2507/` |

```bash
# Основной вариант (уже прописан в config.env):
huggingface-cli download QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4 \
  --local-dir models/llm/Qwen3.8-27B-QUASAR-NVFP4

# DFlash2-ускорение (потом в config.env: LLM_DFLASH2=1):
# huggingface-cli download incoai/Qwen3.8-27B-DFlash2 \
#   --local-dir models/llm/Qwen3.8-27B-DFlash2

# Альтернативы (параллельные каталоги; активная — LLM_MODEL_DIR в config.env):
# huggingface-cli download Qwen/Qwen3.8-27B-FP8 \
#   --local-dir models/llm/Qwen3.8-27B-FP8
# huggingface-cli download Qwen/Qwen3-30B-A3B-Instruct-2507-FP8 \
#   --local-dir models/llm/Qwen3-30B-A3B-Instruct-2507-FP8
# huggingface-cli download Qwen/Qwen3-14B-Instruct-2507 \
#   --local-dir models/llm/Qwen3-14B-Instruct-2507
```

Почему Qwen3.8-27B NVFP4 основной:
- **1Cat-vLLM — «родной» движок модели**: QUASAR-QAT NVFP4 — рекомендуемая
  модель 1Cat для sm70 и модель её release-gate (бенчмарки V100);
- **3.8-поколение** заточено под долгогоризонтные агентные задачи
  (как раз MCP-сценарий); нативный контекст 256k; 4 KV-головы;
- **мультимодальная**: модель умеет видеть изображения — агент может
  «смотреть» скриншоты сцены/игрового окна Unity (через vision-формат
  OpenAI API), чего ни одна из запасных моделей не умеет;
- QAT-квантование NVFP4: качество близко к bf16, веса всего 19.2 GB
  → при TP2 ~9.6 GB/карту, огромный запас под KV-кэш.

DFlash2 (опция `LLM_DFLASH2=1`): спекулятивное декодирование — 1Cat меряет
206–250 tok/s на 4×V100 (TP4); на нашем TP2 работает с частичным фолбэком
fast-path'ов, но всё равно заметно быстрее обычного decode.

Запасной вариант «безотказный»: Qwen3-14B fp16 (dense, без квантования).
МоE-вариант 30B-A3B удобен, если нужен максимум контекста без доп. компонентов.

Проверка: в каталоге модели есть `config.json`.

## 2. ComfyUI (GPU 2) — ~15 GB (минимум) / ~33 GB (с refiner + turbo)

| Что | Откуда | Куда положить |
|---|---|---|
| SDXL 1.0 base (обязательно) ~6.9 GB | `stabilityai/stable-diffusion-xl-base-1.0` | `models/comfy/checkpoints/sd_xl_base_1.0.safetensors` |
| SDXL refiner (опционально, детализация) ~6.9 GB | `stabilityai/stable-diffusion-xl-refiner-1.0` | `models/comfy/checkpoints/sd_xl_refiner_1.0.safetensors` |
| VAE SDXL, fp16-fix (обязательно) ~0.35 GB | `madebyollin/sdxl-vae-fp16-fix` | `models/comfy/vae/sdxl-vae-fp16-fix.safetensors` |
| CLIP-L текстовый энкодер (обязательно)* ~0.25 GB | `openai/clip-vit-large-patch14` | `models/comfy/text_encoders/clip_l.safetensors` |
| SDXL Turbo — быстрый вариант генерации (опц.) ~12 GB | `stabilityai/sdxl-turbo` | `models/comfy/checkpoints/sd_xl_turbo.safetensors` |
| SDXL Lightning 4-step LoRA (опц.) ~0.7 GB | Civitai (поиск "SDXL Lightning") | `models/comfy/loras/sdxl_lightning_4step.safetensors` |
| LoRA под UI/интерфейсы (опц.) — любой SDXL UI LoRA | Civitai (поиск "UI SDXL") | `models/comfy/loras/<имя>.safetensors` |
| Апскейлер 4x-UltraSharp (опц.) ~0.07 GB | Civitai/HF (поиск "4x-UltraSharp") | `models/comfy/upscale_models/4x-UltraSharp.onnx` |

\* ComfyUI докачает CLIP-L сам при первом запуске SDXL-нода, если есть интернет;
файл в каталоге — для полностью офлайн-работы.

```bash
# Минимальный набор:
huggingface-cli download stabilityai/stable-diffusion-xl-base-1.0 sd_xl_base_1.0.safetensors \
  --local-dir models/comfy/checkpoints
huggingface-cli download madebyollin/sdxl-vae-fp16-fix vae.safetensors \
  --local-dir /tmp/vae_sdxl && mv /tmp/vae_sdxl/vae.safetensors models/comfy/vae/sdxl-vae-fp16-fix.safetensors
huggingface-cli download openai/clip-vit-large-patch14 model.safetensors \
  --local-dir /tmp/clip_l && mv /tmp/clip_l/model.safetensors models/comfy/text_encoders/clip_l.safetensors

# Опции (по желанию):
huggingface-cli download stabilityai/stable-diffusion-xl-refiner-1.0 sd_xl_refiner_1.0.safetensors \
  --local-dir models/comfy/checkpoints
huggingface-cli download stabilityai/sdxl-turbo sd_xl_turbo.safetensors \
  --local-dir models/comfy/checkpoints
```

## 3. Hunyuan3D-2 (GPU 3) — ~36.4 GB

Нужны 4 подпапки из репозитория `tencent/Hunyuan3D-2` (весь репозиторий 70 GB —
turbo/fast варианты нам не нужны):

| Что | Размер |
|---|---|
| `hunyuan3d-dit-v2-0` (shape, полная точность) | 22.95 GB |
| `hunyuan3d-paint-v2-0` (PBR-текстуры) | 8.56 GB |
| `hunyuan3d-vae-v2-0` | 0.80 GB |
| `hunyuan3d-delight-v2-0` (нужен paint-пайплайну) | 4.02 GB |
| `config.json` (индекс в корне репозитория) | <1 MB |

```bash
huggingface-cli download tencent/Hunyuan3D-2 \
  --include "hunyuan3d-dit-v2-0/*" \
  --include "hunyuan3d-paint-v2-0/*" \
  --include "hunyuan3d-vae-v2-0/*" \
  --include "hunyuan3d-delight-v2-0/*" \
  --include "config.json" \
  --local-dir models/hunyuan3d-2
```

Проверка: в `models/hunyuan3d-2/` есть каталоги `hunyuan3d-dit-v2-0/`,
`hunyuan3d-paint-v2-0/`, `hunyuan3d-vae-v2-0/`, `hunyuan3d-delight-v2-0/` и файл `config.json`.

---

## Быстрая проверка готовности (после скачивания)

```bash
cd <корень проекта>
./scripts/status.sh          # покажет, что сервисы не запущены (нормально)
./scripts/start-all.sh       # поднимет всё, что можно, с учётом моделей
```
