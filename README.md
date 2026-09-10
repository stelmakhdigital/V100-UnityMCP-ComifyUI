# V100 ×4 — полный цикл разработки Unity (LLM + 2D-графика + 3D)

Пайплайн локальной разработки Unity на одной машине с **4 × NVIDIA V100 32GB**:

- **LLM-агент** ([1Cat-vLLM](https://github.com/1CatAI/1Cat-vLLM) — vLLM-форк,
  в котором V100/SM70 — first-class цель: собственный FlashAttention-V100,
  FP8 KV-кэш, оптимизации Volta) — «мозг», который через **Unity MCP** пишет
  C#-скрипты, двигает GameObject'ы, правит сцены и материалы;
- **ComfyUI** — генерация 2D-графики для игры: текстуры, UI-элементы,
  иллюстрации, спрайты (SDXL);
- **Hunyuan3D-2** — генерация 3D-моделей (mesh + PBR-текстуры, экспорт в
  `.glb`/`.fbx`-совместимые форматы) для прямого использования в Unity.

```
                ┌────────────────────────────────────────────────────────────┐
                │                        Unity Editor                        │
                │   (C#-скрипты, сцены, материалы, импортированные .glb)      │
                └───────────────▲────────────────────────────────────────────┘
                                │ MCP (stdio, плагины внутри Unity)
                                │
 ┌────────────────┐   LLM API    │    MCP-клиент (агентный хост:
 │ 1Cat-vLLM +    │◄────────────┤     Cline / Roo Code / OpenCode / …)
 │ Qwen3-30B-A3B  │  OpenAI API │    — он же шлёт запросы генерации вниз
 │ FP8, active    │  :8000/v1   │
 │ + FP8 KV, GPU01│             │
 └────────────────┘             │
                                ├──► ComfyUI (SDXL): текстуры / UI / арт
                                │     GPU 2, :8188 (веб + REST /prompt)
                                │
                                └──► Hunyuan3D-2: 3D-модели
                                      GPU 3, :8081 (Gradio: text/image→3D)
```

## Распределение GPU

| GPU | Сервис | Модель | Пиковая VRAM (оценка) | Бюджет |
|---|---|---|---|---|
| 0, 1 | 1Cat-vLLM (TP=2) | Qwen3-30B-A3B-Instruct-2507-FP8 (MoE, active 3.3B) | ~21–22 GB на карту | 0.90 × 32 = 28.8 GB |
| 2 | ComfyUI | SDXL base+refiner+VAE+CLIP-L+LoRA | ~15 GB (пик с refiner'ом) | 32 GB |
| 3 | Hunyuan3D-2 | DiT + Paint + VAE + Delight, fp16 | ~26 GB | 32 GB |

Все три сервиса живут **на разных картах** и никогда не конкурируют за VRAM —
главная гарантия «без OOM». Детальный расчёт — ниже, [VRAM-бюджет](#vram-бюджет-почему-нет-oom).

## Требования к машине

- Linux (Ubuntu 22.04/24.04), x86_64;
- драйвер NVIDIA **550–570** (CUDA 12.2–12.8). Драйвер r580+/CUDA 13 V100
  **не поддерживает** — не обновляйте драйвер «до свежайшего»;
- Python **3.12** с `python3.12-venv` (обязательно: wheel 1Cat-vLLM собран
  только под cp312; Ubuntu 24.04 — из коробки, 22.04 — deadsnakes PPA);
- сеть (клонирование репозиториев, pip, скачивание моделей);
- диск: ~150 GB свободно (модели ~96 GB + venvs + запасы);
- 4 × V100 32GB (проверка: `nvidia-smi -L`).

## Быстрый старт

```bash
# 1. Установка (venvs, wheel 1Cat-vLLM, ComfyUI, Hunyuan3D-2 — БЕЗ моделей)
./scripts/00-setup.sh

# 2. Скачать модели (отдельно, по манифесту)
#    -> models/README.md  (~96 GB, huggingface-cli)

# 3. Запустить весь пайплайн
./scripts/start-all.sh

# 4. Статус (GPU + сервисы + проверки)
./scripts/status.sh

# Остановка
./scripts/stop-all.sh
```

Порядок шагов 1 и 2 не важен: модели можно качать, пока стоит venv (и наоборот).

## Сервисы

### 1Cat-vLLM + Qwen3-30B-A3B (GPU 0–1, порт 8000)

Модель: **Qwen3-30B-A3B-Instruct-2507-FP8** — MoE (30.5B total / 3.3B active).
Для 2×V100 это лучший вариант, а не компромисс: веса в FP8 занимают те же
~14.6 GB/карту, что и 14B в fp16, при этом активных параметров на токен в
4.5 раза меньше → decode быстрее в 3–5 раз (V100 ограничен пропускной
способностью памяти), качество ~32B-dense класса, нативный контекст 256k.
1Cat-vLLM несёт оптимизированный sm70-путь для MoE+FP8. Запасные варианты
(в т.ч. «безотказный» Qwen3-14B fp16) — в `models/README.md`.

OpenAI-совместимый API: `http://127.0.0.1:8000/v1`
(эндпоинты `/v1/chat/completions`, `/v1/models`, `/health`; API-ключ не нужен).

[1Cat-vLLM](https://github.com/1CatAI/1Cat-vLLM) — vLLM-форк, оптимизированный
под V100/SM70: собственный **FlashAttention-V100**, **FP8 KV-кэш**, оптимизации
Volta. Ставится предсобранным wheel'ем из [GitHub Releases](https://github.com/1CatAI/1Cat-vLLM/releases)
— собирать из исходников не нужно. Запуск через `vllm serve` (CLI совместим
с vLLM).

Ключевые параметры запуска (см. `scripts/01-start-vllm.sh`):

| Флаг | Значение | Зачем |
|---|---|---|
| `--dtype float16` | fp16 | у V100 нет bf16 — чекпоинты в bf16 кастятся в fp16 |
| `--tensor-parallel-size 2` | TP=2 | модель распределена на 2 карты |
| `--max-model-len 131072` | 128k | длинный контекст под агентные MCP-сессии (модель тянет до 256k) |
| `--gpu-memory-utilization 0.90` | 90% | верхняя граница VRAM — анти-OOM |
| `--attention-backend FLASH_ATTN_V100` | FA форка | нативный для sm70 attention (на V100 включается и по умолчанию, фиксируем явно) |
| `--kv-cache-dtype fp8_e5m2` | FP8 KV | KV-кэш вдвое меньше при том же VRAM → больше контекста/конкурентности |
| `--enable-auto-tool-choice --tool-call-parser qwen3_coder` | да | OpenAI tool-calling в формате Qwen3 — для MCP-инструментов |
| `--reasoning-parser qwen3` | да | корректный разбор reasoning-блоков Qwen3 в API |
| `--enable-chunked-prefill` | да | быстрое TTFT на длинных промптах |
| `--enable-prefix-caching` | да | кэш общих префиксов (system-промпт MCP-агента не пересчитывается) |

Thinking-режим Qwen3 на сервере **выключен по умолчанию** в этом движке
(default chat-template kwargs `enable_thinking=false`) — это верный режим для
агентной работы; включить для конкретного запроса можно полем
`chat_template_kwargs` в теле `/v1/chat/completions`.

### ComfyUI (GPU 2, порт 8188)

- веб-интерфейс: `http://127.0.0.1:8188`
- API (для автоматизации/агента): `POST /prompt` (JSON-граф), `/history`,
  `GET /view?filename=...`
- каталог моделей: `models/comfy/` (симлинки в ComfyUI уже сделаны setup'ом);
- базовый набор: **SDXL 1.0 base + VAE fp16-fix + CLIP-L** (текстуры, арт, UI
  с LoRA). Для быстрых превью — SDXL Turbo или Lightning 4-step LoRA;
- все модели живут в VRAM по требованию и выгружаются между заданиями
  (ComfyUI сам управляет offload) — на 32 GB запаса огромный.

### Hunyuan3D-2 (GPU 3, порт 8081)

- Gradio-интерфейс: `http://127.0.0.1:8081` — text-to-3D и image-to-3D,
  экспорт `.glb / .obj / .ply / .stl` (текстурированные GLB импортируются в
  Unity как есть);
- пайплайн: shape DiT (геометрия) → Paint (PBR-текстуры), обе стадии на GPU 3;
- автоматизация: `gradio_client` (или `minimal_demo.py` в репозитории для
  пакетной генерации).

## Подключение Unity MCP

1. В Unity установлен MCP-сервер (C#-плагин; он поднимает локальный MCP-сервер,
   доступный агенту).
2. В MCP-клиенте (агентном хосте) прописывается провайдер LLM — 1Cat-vLLM
   (OpenAI-совместимый API):

   ```json
   {
     "provider": "openai-compatible",
     "apiBase": "http://127.0.0.1:8000/v1",
     "apiKey": "sk-local-any",
     "model": "unity-llm"
   }
   ```

   Готовый пример с комментариями: `unity/mcp-llm-client.example.json`.
3. Агентный цикл: хост шлёт промпт + результаты MCP-инструментов в LLM-сервер
   (1Cat-vLLM), тот отвечает следующим действием (вызов инструмента), хост выполняет его
   в Unity. Qwen3 поддерживает tool-calling через стандартный OpenAI-формат.
4. (Опционально) чтобы агент сам запрашивал арт и 3D, оберните ComfyUI
   (`/prompt`) и Hunyuan3D-2 (`gradio_client`) в дополнительные MCP-инструменты
   того же клиента — LLM сможет вызывать их наравне с Unity-инструментами.

Практика: у Qwen3 в агентном режиме «thinking» лучше держать выключенным —
в 1Cat-vLLM это уже значение по умолчанию (default chat-template kwargs
`enable_thinking=false`), отдельные действия не нужны; включить для
отдельного запроса можно полем `chat_template_kwargs` в теле запроса.

## VRAM-бюджет: почему нет OOM

### 1Cat-vLLM (GPU 0 и 1, по TP=2)

| Статья | На карту |
|---|---|
| Веса Qwen3-30B-A3B-FP8 (29.1 GB) / 2 | ~14.6 GB |
| KV-кэш на 131 072 токенов, **FP8 E5M2** (48 сл. × 2 × 2 KV-головы/карту × 128 × 1B) | ~3.1 GB |
| Активации, CUDA-графы, NCCL, оверхед | ~3–4 GB |
| **Итого** | **~21–22 GB** из 32 (лимит vLLM: 28.8 GB) |

FP8 KV-кэш (1Cat-vLLM) вдвое сжимает KV относительно fp16 — при том же лимите
VRAM доступно больше контекста/параллельных стримов. Запас ~6–8 GB на карту.
При нехватке: `LLM_MAX_MODEL_LEN=32768`, `LLM_GPU_MEM_UTIL=0.85` или
`LLM_KV_CACHE_DTYPE=auto` (полный fp16 KV вместо FP8 — чуть меньше места).

### ComfyUI (GPU 2)

SDXL base (6.9) + refiner (6.9, по требованию) + VAE (0.35) + CLIP-L (0.25)
+ LoRAs (десятки МБ) ≈ **10–15 GB** пика. Запас ~17 GB. Запасной флаг:
`COMFYUI_RESERVE_VRAM=1`.

### Hunyuan3D-2 (GPU 3)

Официальный минимум полного пайплайна ~26 GB; пик с fp16-моделями ~26–28 GB.
Запас 4–6 GB. Запасной флаг: `HY3D_LOW_VRAM=1` (CPU-offload, медленнее,
но снимает OOM на любой конфигурации).

### Общий принцип

Каждому сервису выделена **своя** карта (`CUDA_VISIBLE_DEVICES`), внутри:
жёсткие пределы (`gpu-memory-utilization`, `--reserve-vram`, `--low_vram_mode`).
Перекрёстное OOM исключено по построению.

## V100: важные особенности (почему всё закреплено)

1. **Только fp16.** У Volta нет bf16. Чекпоинты в bf16 (Qwen3 и др.)
   кастятся в fp16 (`--dtype float16`). FP8 на V100 поддерживается только
   в специфических формах 1Cat-vLLM (FP8 KV-кэш, NVFP4-квантизация весов) —
   нативного fp8-вычисления на Volta нет.
2. **Attention: FlashAttention-V100.** Обычный flash-attn v2 требует SM ≥ 8.0 —
   на V100 (SM 7.0) его нет. 1Cat-vLLM несёт собственный портированный под
   sm70 FlashAttention (`flash_attn_v100`), включается автоматически на V100
   (`VLLM_SM70_FLASH_ATTN_V100=1` по умолчанию) и фиксируется явно флагом
   `--attention-backend FLASH_ATTN_V100`.
3. **Версии.** Пип-колеса vLLM из PyPI (0.21+) собраны на CUDA ≥ 12.8 **без
   sm_70** — поэтому vLLM ставится только wheel'ем 1Cat-vLLM (собран под sm_70,
   SHA256 проверяется в setup'е). Для ComfyUI/Hunyuan3D-2 используется
   torch 2.7.1 **cu126** (sm_70 в сборках есть). Собранные на CUDA 13+ wheel'и
   V100 не поддерживают.
4. **Драйвер.** R550–R570 (CUDA 12.x). R580+/CUDA 13 — про V100.

### Обновление LLM-движка

1Cat-vLLM выпускает готовые wheel'и под sm_70 в [GitHub Releases](https://github.com/1CatAI/1Cat-vLLM/releases):
для обновления достаточно поправить в `config.env` `ONECAT_VLLM_VERSION`,
`ONECAT_VLLM_WHEEL_URL` и `ONECAT_VLLM_WHEEL_SHA256` (SUMS есть в каждом
релизе) и повторить `./scripts/00-setup.sh`. Альтернатива — любой свежий vLLM,
собранный из исходников на CUDA 12.6 (CMake для CUDA < 12.8 ещё компилирует
sm_70; см. [v100-vllm-2026](https://github.com/KumphanartDansiri/v100-vllm-2026)
— бенчмарки на 8×V100-32GB), но это уже ручной путь.

## Операции

| Команда | Что делает |
|---|---|
| `./scripts/00-setup.sh` | Установка окружения (идемпотентна) |
| `./scripts/01-start-vllm.sh` | Только 1Cat-vLLM (GPU 0–1) |
| `./scripts/02-start-comfyui.sh` | Только ComfyUI (GPU 2) |
| `./scripts/03-start-3d.sh` | Только Hunyuan3D-2 (GPU 3) |
| `./scripts/start-all.sh` | Всё подряд + статус |
| `./scripts/stop-all.sh` | Остановка всего (+ зачистка без pid-файлов) |
| `./scripts/status.sh` | GPU, процессы, HTTP-проверки |

Логи: `logs/vllm.log`, `logs/comfyui.log`, `logs/hunyuan3d.log`.
PID-файлы: `pids/`. Все настройки — в `config.env` (GPU, порты, модели,
флаги, версии).

## Тесты после запуска

```bash
# 1) LLM отвечает
curl http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"unity-llm","messages":[{"role":"user","content":"Скажи: Unity MCP готов"}],"max_tokens":32}'

# 2) ComfyUI жив
curl -s http://127.0.0.1:8188/system_stats | python3 -m json.tool

# 3) Hunyuan3D-2 жив
curl -sI http://127.0.0.1:8081 | head -3
```

## Troubleshooting

| Симптом | Причина / решение |
|---|---|
| `no kernel image is available for execution on the device` | В окружении vLLM появился torch/cu13x wheel без sm_70. Удалите `venvs/vllm` и повторите `./scripts/00-setup.sh` (torch придёт из зависимостей wheel 1Cat-vLLM) |
| Wheel 1Cat-vLLM «не для моего Python» | Wheel cp312-only: нужен Python 3.12 (см. Требования). Проверка: `python3.12 --version` |
| SHA256 wheel не совпадает | Повреждённая загрузка/устаревший пин: удалите `vendor/wheels/*.whl`, сверьте URL/SHA256 в `config.env` с релизом |
| OOM в LLM-сервере при запуске | Уменьшите `LLM_MAX_MODEL_LEN` (32768) и/или `LLM_GPU_MEM_UTIL` (0.85) |
| LLM-сервер падает на capture CUDA-графов (редко) | Добавьте `--enforce-eager` в `01-start-vllm.sh` (медленнее, но стабильно) |
| OOM в Hunyuan3D-2 | `HY3D_LOW_VRAM=1` в `config.env` (CPU-offload) |
| OOM в ComfyUI (очень редкий) | `COMFYUI_RESERVE_VRAM=2`, меньше LoRAs в графе |
| Port already in use | Старый процесс без pid-файла: `ps aux \| grep -E 'vllm\|ComfyUI\|gradio'` |
| Медленно грузится Hunyuan3D-2 | Нормально: ~36 GB моделей, 3–10 минут |
| Ошибка pip: конфликты версий при установке 1Cat-vLLM | Wheel жёстко фиксирует зависимости (torch==2.10.0 и др.) — ставьте в ЧИСТЫЙ venv, как делает `00-setup.sh` |

## Что НЕ входит (осознанно)

- Скачивание моделей (делается вручную по `models/README.md`);
- GUI-автоматизация Unity (за этим — сам Unity MCP);
- Распределение пайплайна по нескольким машинам (здесь всё на одной).
