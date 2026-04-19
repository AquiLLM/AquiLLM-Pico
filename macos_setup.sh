git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
git checkout b8580

cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_METAL=ON \
  -DCMAKE_C_COMPILER=/usr/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/bin/clang++
cmake --build build --config Release -j$(sysctl -n hw.logicalcpu)

python -m venv aquillm
source aquillm/bin/activate

pip install huggingface_hub
python -c "from huggingface_hub import hf_hub_download; hf_hub_download('Qwen/Qwen3-4B-GGUF', filename='Qwen3-4B-Q4_K_M.gguf', local_dir='./models')"
