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

# llama-cli invocation args (shared between platforms)
LLAMA_BIN="./llama.cpp/build/bin/llama-cli"
LLAMA_ARGS=(
    -m ./llama.cpp/models/Qwen3-4B-Q4_K_M.gguf
    -ngl 99
    -c 4096
    -cnv
    --reasoning-budget 0
    --log-disable
    --verbosity 0
    --no-display-prompt
)

# run the command through a PTY, using the right `script` syntax for the OS
run_with_pty() {
    case "$(uname -s)" in
        Darwin)
            # macOS (BSD script): script -q <logfile> <command> [args...]
            script -q /dev/null "$LLAMA_BIN" "${LLAMA_ARGS[@]}"
            ;;
        Linux)
            # Linux (util-linux script): script -qfc "<command string>" <logfile>
            # -f flushes after every write (needed for streaming output)
            local cmd="$LLAMA_BIN"
            for arg in "${LLAMA_ARGS[@]}"; do
                cmd+=" $(printf '%q' "$arg")"
            done
            script -qfc "$cmd" /dev/null
            ;;
        *)
            echo "Unsupported OS: $(uname -s)" >&2
            echo "Falling back to direct invocation (no PTY)." >&2
            "$LLAMA_BIN" "${LLAMA_ARGS[@]}"
            ;;
    esac
}

run_with_pty | python3 -u -c '
import sys, threading, time, codecs

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
    sys.stdout.write("\r\033[K")
    sys.stdout.flush()

spinner_thread = threading.Thread(target=spin, daemon=True)
spinner_thread.start()

decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
in_banner = False
started = False
line_buf = ""

while True:
    chunk = sys.stdin.buffer.read(1)
    if not chunk:
        break
    text = decoder.decode(chunk)
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