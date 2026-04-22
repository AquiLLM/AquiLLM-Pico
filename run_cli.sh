#!/usr/bin/env bash

OLD_STTY=$(stty -g)
trap 'stty "$OLD_STTY"' EXIT
stty echo

cat <<'EOF'
                      _ _      _      __  __            _____ _           
     /\              (_) |    | |    |  \/  |          |  __ (_)          
    /  \   __ _ _   _ _| |    | |    | \  / |  ______  | |__) |  ___ ___  
   / /\ \ / _` | | | | | |    | |    | |\/| | |______| |  ___/ |/ __/ _ \ 
  / ____ \ (_| | |_| | | |____| |____| |  | |          | |   | | (_| (_) |
 /_/    \_\__, |\__,_|_|______|______|_|  |_|          |_|   |_|\___\___/ 
             | |                                                          
             |_|                                                          

To exit:                 /exit  
To regenerate prompt:    /regen  
To clear chat history:   /clear  
To read a text file:     /read  
To pattern match a file: /glob
EOF

script -q /dev/null ./llama.cpp/build/bin/llama-cli \
  -m ./llama.cpp/models/Qwen3-4B-Q4_K_M.gguf \
  -ngl 99 -c 4096 -cnv \
  --reasoning-budget 0 --log-disable --verbosity 0 \
  --no-display-prompt \
| python3 -u -c '
import sys, threading, time, codecs

# ---- spinner shown while the banner has not yet appeared ----
stop_spinner = threading.Event()
def spin():
    frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
    i = 0
    sys.stdout.write("Loading model... ")
    sys.stdout.flush()
    while not stop_spinner.is_set():
        sys.stdout.write(frames[i % len(frames)])
        sys.stdout.flush()
        time.sleep(0.1)
        sys.stdout.write("\b")
        sys.stdout.flush()
        i += 1
    # clear the "Loading model... " line
    sys.stdout.write("\r\033[K")
    sys.stdout.flush()

spinner_thread = threading.Thread(target=spin, daemon=True)
spinner_thread.start()

# ---- streaming UTF-8 decoder: buffers partial multi-byte sequences ----
decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

in_banner = False
started = False
line_buf = ""

while True:
    chunk = sys.stdin.buffer.read(1)
    if not chunk:
        break
    text = decoder.decode(chunk)   # may return "" until a full codepoint is ready
    if not text:
        continue

    for ch in text:
        if started:
            sys.stdout.write(ch)
            sys.stdout.flush()
            continue

        line_buf += ch
        if ch == "\n":
            line = line_buf.rstrip("\r\n")
            if "available commands:" in line:
                in_banner = True
            elif in_banner and line.strip() == "":
                started = True
                stop_spinner.set()
                spinner_thread.join()
            line_buf = ""
'