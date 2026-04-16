# Start llama-server (from your llama.cpp directory)
./llama.cpp/build/bin/llama-server \
-m ./llama.cpp/models/Qwen3-4B-Q4_K_M.gguf \
-ngl 99 \
-c 4096 \
--host 0.0.0.0 \
--port 8080 \
--reasoning-budget 0
