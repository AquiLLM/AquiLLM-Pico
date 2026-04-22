#!/bin/bash
set -e

git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
git checkout b8580

# CPU-only build (works everywhere)
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_HIP=ON
cmake --build build --config Release -j$(nproc)

python3 -m venv aquillm
source aquillm/bin/activate
pip install huggingface_hub
python3 -c "from huggingface_hub import hf_hub_download; hf_hub_download('Qwen/Qwen3-4B-GGUF', filename='Qwen3-4B-Q4_K_M.gguf', local_dir='./models')"