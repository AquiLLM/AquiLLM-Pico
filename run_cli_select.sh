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

# ── Model selection ─────────────────────────────────────────────────────────
MODELS_DIR="./llama.cpp/models"
declare -A MODEL_MAP
declare -a MODEL_KEYS

while IFS= read -r -d '' f; do
    name=$(basename "$f" .gguf)
    MODEL_MAP["$name"]="$f"
    MODEL_KEYS+=("$name")
done < <(find "$MODELS_DIR" -maxdepth 1 -name '*.gguf' ! -name 'ggml-vocab-*' -print0 | sort -z)

echo ""
echo "Select a model:"
for i in "${!MODEL_KEYS[@]}"; do
    echo "  [$((i+1))] ${MODEL_KEYS[$i]}"
done
echo ""

SELECTED_MODEL_FILE=""
while true; do
    printf "Enter number [1]: "
    read -r model_choice
    model_choice=${model_choice:-1}
    if [[ "$model_choice" =~ ^[0-9]+$ ]] && \
       (( model_choice >= 1 && model_choice <= ${#MODEL_KEYS[@]} )); then
        key="${MODEL_KEYS[$((model_choice-1))]}"
        SELECTED_MODEL_FILE="${MODEL_MAP[$key]}"
        echo "  → Using: $key"
        break
    else
        echo "  Invalid selection, try again."
    fi
done

# ── Thinking / reasoning budget ──────────────────────────────────────────────
echo ""
echo "Enable thinking/reasoning?"
echo "  [1] Off  – fast, no internal monologue (default)"
echo "  [2] On   – unrestricted token budget"
echo "  [3] Limited – specify a token budget"
echo ""

REASONING_BUDGET=0          # default: off
REASONING_FLAG="-rea off"

while true; do
    printf "Enter number [1]: "
    read -r think_choice
    think_choice=${think_choice:-1}
    case "$think_choice" in
        1)
            REASONING_BUDGET=0
            REASONING_FLAG="-rea off"
            echo "  → Thinking: Off"
            break
            ;;
        2)
            REASONING_BUDGET=-1
            REASONING_FLAG="-rea on"
            echo "  → Thinking: On (unrestricted)"
            break
            ;;
        3)
            while true; do
                printf "  Token budget (positive integer): "
                read -r budget
                if [[ "$budget" =~ ^[1-9][0-9]*$ ]]; then
                    REASONING_BUDGET="$budget"
                    REASONING_FLAG="-rea on"
                    echo "  → Thinking: On (budget: $budget tokens)"
                    break
                else
                    echo "  Please enter a positive integer."
                fi
            done
            break
            ;;
        *)
            echo "  Invalid selection, try again."
            ;;
    esac
done

echo ""

# ── Launch llama-cli ─────────────────────────────────────────────────────────
#script -q /dev/null ./llama.cpp/build/bin/llama-cli \
#  -m "$SELECTED_MODEL_FILE" \
#  -ngl 99 -c 4096 -cnv \
#  $REASONING_FLAG \
#  --reasoning-budget "$REASONING_BUDGET" \
#  --log-disable --verbosity 0 \
#  --no-display-prompt \
#| python3 -u -c '

LLAMA_BIN="./llama.cpp/build/bin/llama-cli"
LLAMA_ARGS=(
    -m "$SELECTED_MODEL_FILE"
    -ngl 99
    -c 4096
    -cnv
    $REASONING_FLAG
    --reasoning-budget "$REASONING_BUDGET"
    --log-disable
    --verbosity 0
    --no-display-prompt
)

run_with_pty() {
    case "$(uname -s)" in
        Darwin)
            # macOS BSD script: script -q <logfile> <command> [args...]
            script -q /dev/null "$LLAMA_BIN" "${LLAMA_ARGS[@]}"
            ;;
        Linux)
            # util-linux script: script -qfc "<command string>" <logfile>
            # -f flushes after every write (essential for streaming output)
            local cmd="$LLAMA_BIN"
            for arg in "${LLAMA_ARGS[@]}"; do
                cmd+=" $(printf '%q' "$arg")"
            done
            script -qfc "$cmd" /dev/null
            ;;
        *)
            echo "Unsupported OS: $(uname -s); running without PTY." >&2
            "$LLAMA_BIN" "${LLAMA_ARGS[@]}"
            ;;
    esac
}

run_with_pty | python3 -u -c '
import sys, threading, time, codecs, re, select, shutil, os

# ── Terminal width ────────────────────────────────────────────────────────────
W  = shutil.get_terminal_size((80, 24)).columns
FD = 0   # raw stdin fd – avoids BufferedReader masking data from select()

# ── ANSI codes ────────────────────────────────────────────────────────────────
R  = "\033[0m";  BD = "\033[1m";  DM = "\033[2m";  IT = "\033[3m"
CY = "\033[36m"; YL = "\033[33m"; GN = "\033[32m"
MG = "\033[35m"; GY = "\033[90m"; BL = "\033[34m"
TH = "\033[38;5;67m"   # steel-blue: think content

# ── Spinner ───────────────────────────────────────────────────────────────────
stop_spinner = threading.Event()
def spin():
    frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
    i = 0
    sys.stdout.write("Loading model... "); sys.stdout.flush()
    while not stop_spinner.is_set():
        sys.stdout.write(frames[i % len(frames)]); sys.stdout.flush()
        time.sleep(0.1)
        sys.stdout.write("\b"); sys.stdout.flush()
        i += 1
    sys.stdout.write("\r\033[K"); sys.stdout.flush()

spinner_thread = threading.Thread(target=spin, daemon=True)
spinner_thread.start()

# ── Inline markdown ───────────────────────────────────────────────────────────
def fmt_inline(t):
    t = re.sub(r"\*\*(.+?)\*\*", BD + r"\1" + R, t)
    t = re.sub(r"__(.+?)__",     BD + r"\1" + R, t)
    t = re.sub(r"\*([^*\n]+)\*", IT + r"\1" + R, t)
    t = re.sub(r"_([^_\n]+)_",   IT + r"\1" + R, t)
    t = re.sub(r"`([^`\n]+)`",   CY + r"\1" + R, t)
    return t

# ── Line formatter ────────────────────────────────────────────────────────────
in_think = False
in_code  = False
para_buf = ""   # accumulates plain-text lines; flushed on blank/structural

def flush_para():
    """Emit any accumulated paragraph text as one line; terminal handles wrapping."""
    global para_buf
    if not para_buf: return
    p = para_buf
    para_buf = ""

    # Headings
    m = re.match(r"^(#{1,6}) (.*)", p)
    if m:
        lvl = len(m.group(1)); col = YL if lvl <= 2 else GN
        sys.stdout.write("\r\n" + BD + col + fmt_inline(m.group(2)) + R + "\r\n")
        if lvl <= 2:
            sys.stdout.write(GY + ("═" if lvl == 1 else "─") * min(W, len(m.group(2)) + 4) + R + "\r\n")
        sys.stdout.flush(); return

    # Blockquote
    m = re.match(r"^(>+)\s*(.*)", p)
    if m:
        sys.stdout.write(BL + "│" + R + " " + DM + fmt_inline(m.group(2)) + R + "\r\n")
        sys.stdout.flush(); return

    # Bullet list
    m = re.match(r"^(\s*)[-*+] (.*)", p)
    if m:
        sys.stdout.write(m.group(1) + MG + "•" + R + " " + fmt_inline(m.group(2)) + "\r\n")
        sys.stdout.flush(); return

    # Numbered list
    m = re.match(r"^(\s*)(\d+[.)]) (.*)", p)
    if m:
        sys.stdout.write(m.group(1) + BD + m.group(2) + R + " " + fmt_inline(m.group(3)) + "\r\n")
        sys.stdout.flush(); return

    # Horizontal rule
    if re.fullmatch(r"[-*_]{3,}", p.strip()):
        sys.stdout.write(GY + "─" * W + R + "\r\n")
        sys.stdout.flush(); return

    # Plain text
    sys.stdout.write(fmt_inline(p) + "\r\n")
    sys.stdout.flush()

def emit_line(line):
    global in_think, in_code, para_buf

    if in_think:
        if "</think>" in line or "[End thinking]" in line:
            in_think = False
            pre = re.split(r"</think>|\[End thinking\]", line, 1)[0].strip()
            if pre:
                sys.stdout.write(TH + DM + "│ " + IT + pre + R + "\r\n")
            sys.stdout.write(GY + "└" + "─" * max(0, W - 1) + "┘" + R + "\r\n\r\n")
            sys.stdout.flush()
        else:
            sys.stdout.write(TH + DM + "│ " + IT + line + R + "\r\n")
            sys.stdout.flush()
        return

    if in_code:
        if line.startswith("```"):
            in_code = False
            sys.stdout.write(GY + "└" + "─" * max(0, W - 1) + "┘" + R + "\r\n")
        else:
            sys.stdout.write(GY + "│ " + R + CY + line + R + "\r\n")
        sys.stdout.flush()
        return

    if "<think>" in line or "[Start thinking]" in line:
        flush_para()
        in_think = True
        split_token = "<think>" if "<think>" in line else "[Start thinking]"
        pre  = line.split(split_token, 1)[0].rstrip()
        rest = line.split(split_token, 1)[1].strip()
        if pre:
            # edge case: text before think block
            sys.stdout.write(fmt_inline(pre) + "\r\n")
        label = " Thinking "
        sys.stdout.write("\r\n" + GY + "┌─" + DM + IT + label + R + GY +
                         "─" * max(0, W - len(label) - 3) + "┐" + R + "\r\n")
        if rest:
            sys.stdout.write(TH + DM + "│ " + IT + rest + R + "\r\n")
        sys.stdout.flush()
        return

    if line.startswith("```"):
        flush_para()
        in_code = True
        lang  = line[3:].strip()
        label = (" " + lang + " ") if lang else ""
        sys.stdout.write(GY + "┌─" + CY + label + R + GY +
                         "─" * max(0, W - len(label) - 3) + "┐" + R + "\r\n")
        sys.stdout.flush()
        return

    s = line.strip()

    # Blank line
    if not s:
        flush_para()
        sys.stdout.write("\r\n"); sys.stdout.flush()
        return

    # Horizontal rule
    if re.fullmatch(r"[-*_]{3,}", s):
        flush_para()
        sys.stdout.write(GY + "─" * W + R + "\r\n"); sys.stdout.flush()
        return

    # Table row
    if line.lstrip().startswith("|"):
        flush_para()
        sys.stdout.write(fmt_inline(line) + "\r\n"); sys.stdout.flush()
        return

    # If the line begins a new logical block, flush the old one.
    ls = line.lstrip()
    is_list = bool(re.match(r"[-*+]\s+", ls) or re.match(r"\d+[.)]\s+", ls))
    is_heading = bool(re.match(r"#{1,6}\s+", ls))
    is_quote = ls.startswith(">")

    if is_list or is_heading or is_quote:
        flush_para()
        para_buf = line.rstrip()
    else:
        # Continuation line: append to current paragraph buffer
        if not para_buf:
            para_buf = line.rstrip()
        else:
            para_buf += " " + s

# ── State machine ─────────────────────────────────────────────────────────────
# LOADING   – eating the llama-cli banner until the blank line after
#             "available commands:"
# PASSTHRU  – the "> " prompt and everything the user types (echoed by the pty)
#             forwarded immediately, char-by-char, so input is visible.
#             Pressing Enter (\n) switches to GENERATING.
# GENERATING – model output: buffer whole lines, render markdown, then emit.
#             Seeing "> " at the START of a fresh line with no further data in
#             250 ms means the model is done; flush the prompt raw → PASSTHRU.

LOADING, PASSTHRU, GENERATING = 0, 1, 2
state         = LOADING
in_banner     = False
line_buf      = ""
at_line_start = True   # True immediately after \n or at the start of GENERATING

decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

while True:
    try:
        raw = os.read(FD, 1)   # unbuffered: select() on FD stays accurate
    except OSError:
        break
    if not raw:
        if line_buf.strip():
            emit_line(line_buf)
        if in_code or in_think:
            sys.stdout.write(GY + "└" + "─" * max(0, W - 1) + "┘" + R + "\r\n")
            sys.stdout.flush()
        break

    text = decoder.decode(raw)
    if not text:
        continue

    for ch in text:

        # ── LOADING: eat banner until blank line after "available commands:" ──
        if state == LOADING:
            line_buf += ch
            if ch == "\n":
                line = line_buf.rstrip("\r\n")
                if "available commands:" in line:
                    in_banner = True
                elif in_banner and line.strip() == "":
                    state = PASSTHRU
                    stop_spinner.set()
                    spinner_thread.join()
                line_buf = ""
            continue

        # ── PASSTHRU: prompt chars and user-echoed keystrokes ─────────────────
        # Write each character immediately so the user sees their own typing.
        if state == PASSTHRU:
            sys.stdout.write(ch); sys.stdout.flush()
            if ch == "\n":
                state         = GENERATING
                line_buf      = ""
                at_line_start = True
            continue

        # ── GENERATING: buffer lines and render markdown ───────────────────────
        if ch == "\n":
            emit_line(line_buf.rstrip("\r"))
            line_buf      = ""
            at_line_start = True
            continue

        # Prompt-boundary detection: "> " at the very start of a fresh line.
        # select() is called ONLY here (once per response), never mid-generation.
        if at_line_start and not in_think and not in_code:
            if ch == ">" and not line_buf:
                line_buf = ">"
                continue                      # wait for the space
            if ch == " " and line_buf == ">":
                line_buf = "> "
                # Blockquote or prompt?  If no data arrives within 250 ms → prompt.
                ready, _, _ = select.select([FD], [], [], 0.25)
                if not ready:
                    flush_para()              # emit any trailing paragraph text
                    sys.stdout.write(line_buf); sys.stdout.flush()
                    line_buf      = ""
                    state         = PASSTHRU
                    at_line_start = True
                else:
                    at_line_start = False  # more data → blockquote, keep going
                continue

        at_line_start = False
        line_buf += ch
'
