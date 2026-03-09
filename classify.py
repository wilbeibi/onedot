# /// script
# requires-python = ">=3.11"
# dependencies = ["google-genai", "Pillow", "pyyaml"]
# ///

import hashlib
import io
import json
import os
import re
import sys
from datetime import datetime
from google import genai

import yaml

CONFIG_PATH = os.path.expanduser("~/.config/onedot/config.yaml")

with open(CONFIG_PATH) as f:
    _config = yaml.safe_load(f)
API_KEY = _config.get("api_key", "")
MODEL = _config.get("model", "gemini-3.1-flash-lite-preview")
STATE_PATH = "/tmp/onedot-state.json"
JSONL_PATH = os.path.expanduser("~/.config/onedot/log.jsonl")
DHASH_THRESHOLD = 6  # below this = "same screen" (0=identical, 64=opposite)
IDLE_STREAK_THRESHOLD = 3  # consecutive idle ticks before marking AFK
PROMPT = """Classify the user's current screen activity. Do NOT just identify the application — you must READ the visible text content to determine what the user is actually doing.

Step 1: Read the title bar, tab titles, and URL bar to identify the foreground app.
Step 2: READ the visible text in the main content area — conversation messages, code, article text, video titles, terminal output. Quote the most relevant snippet in key_content.
Step 3: Based on what you read, classify the activity.

Categories:

OUTPUT — Actively producing work. Signals: cursor in editable area, recent code edits, composing text, running project commands, solving a problem, writing a solution. Includes: coding, terminal commands for a project, writing notes/docs, LeetCode (any stage), using AI to generate/debug/build code, committing/pushing.

INPUT — Intentionally consuming information with focus. Signals: reading an article or docs, watching a technical video, studying code, reviewing a PR. Includes: reading docs, tech talks, study material, reading email, using AI to research/learn concepts.

DISTRACTED — Off-task or low-value activity. Signals: entertainment, social media feeds, idle browsing, no clear goal. Includes: entertainment videos, social media scrolling, shopping, news rabbit holes, gaming, lock screen, idle desktop. Also: tool/environment configuration (dotfiles, editor plugins, network setup) not part of a current project — it feels productive but delays real output.

Disambiguation — READ the actual content, don't judge by app name alone:
- AI chat (Claude Code, Claude, ChatGPT, Gemini): READ the conversation text visible on screen.
  OUTPUT: user is asking AI to write code, fix a bug, implement a feature, review a diff, or the AI is actively generating code/commands. Look for code blocks, file paths, error messages, implementation discussion.
  INPUT: user is asking AI to explain a concept, research a topic, compare approaches — learning, not building.
  DISTRACTED: chitchat, aimless "what should I do", meta-discussion about AI itself, no concrete task visible, browsing AI tool settings.
- Terminal / Claude Code agent: READ the terminal output.
  OUTPUT: running tests, git operations, building, editing files, executing project commands.
  DISTRACTED: configuring unrelated tools, installing random packages, SSH/network setup not for current project, idle prompt with no recent commands.
- YouTube/Bilibili: READ the video title. INPUT only if clearly a tech talk, tutorial, or lecture. Entertainment, anime, vlogs, scenic → DISTRACTED.
- Reddit/Twitter/HN: INPUT only if reading a specific technical thread. Scrolling a feed → DISTRACTED.
- LeetCode/coding challenges: always OUTPUT — reading problem, writing solution, debugging are all producing.
- Obsidian/notes: OUTPUT if actively writing. INPUT if reading/reviewing.
- Browser: judge by the visible page content and text, not the browser itself.
- When genuinely ambiguous between OUTPUT and INPUT, prefer OUTPUT if a cursor is active in an editable area.

Examples:
- VS Code with cursor in code, recent edits visible → OUTPUT
- Terminal running pytest, git push, or build commands → OUTPUT
- Claude Code showing "editing file src/auth.py" or generating code → OUTPUT
- AI chat with visible code blocks and implementation discussion → OUTPUT
- LeetCode at any stage → OUTPUT
- AI chat asking "explain how React hooks work" with explanation visible → INPUT
- Browser showing React docs, scroll mid-page → INPUT
- YouTube titled "System Design Interview - Distributed Cache" → INPUT
- AI chat with "what should I work on today" or rambling conversation → DISTRACTED
- Claude Code idle prompt, no recent commands, user hasn't typed → DISTRACTED
- Bilibili showing anime or vlogs → DISTRACTED
- Twitter/Reddit feed scrolling → DISTRACTED
- Configuring Tailscale, Obsidian plugins, SSH keys → DISTRACTED
- Lock screen or screensaver → DISTRACTED

For key_content: quote the most classification-relevant text you can read on screen (a code snippet, conversation message, article title, video title, or terminal command). Max 40 words. This is critical for accurate classification.

Keep the reason under 15 words."""


def rotate_log():
    """If log.jsonl starts in a previous ISO week, archive it."""
    if not os.path.exists(JSONL_PATH):
        return
    with open(JSONL_PATH) as f:
        line = f.readline()
    if not line:
        return
    try:
        ts = json.loads(line).get("ts", "")
        y, w, _ = datetime.fromisoformat(ts).date().isocalendar()
        ny, nw, _ = datetime.now().date().isocalendar()
        if (y, w) != (ny, nw):
            dest = JSONL_PATH.replace("log.jsonl", f"log-{y}-W{w:02d}.jsonl")
            os.rename(JSONL_PATH, dest)
    except (json.JSONDecodeError, ValueError):
        pass


def log_jsonl(event, result, **extra):
    """Append one JSON line per tick — classifications, idle skips, tokens, timing."""
    os.makedirs(os.path.dirname(JSONL_PATH), exist_ok=True)
    entry = {"ts": datetime.now().isoformat(), "event": event, "model": MODEL}
    entry.update({k: v for k, v in result.items() if k != "tokens"})
    if result.get("tokens"):
        entry["tokens"] = result["tokens"]
    if extra:
        entry.update(extra)
    with open(JSONL_PATH, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def file_hash(data):
    """SHA-256 of bytes — catches exact-match idle with zero image processing."""
    return hashlib.sha256(data).hexdigest()


def dhash(data, size=8):
    """Difference hash for perceptual similarity. Returns 64-bit int.
    Lazy-imports Pillow so exact-idle path pays no import cost."""
    from PIL import Image
    img = Image.open(io.BytesIO(data)).resize((size + 1, size), Image.NEAREST).convert("L")
    pixels = list(img.getdata())
    w = size + 1
    h = 0
    for row in range(size):
        for col in range(size):
            if pixels[row * w + col] < pixels[row * w + col + 1]:
                h |= 1 << (row * size + col)
    return h


def hamming(h1, h2):
    return bin(h1 ^ h2).count("1")


def load_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def save_state(dhash_val, file_hash_val, result, idle_streak=0):
    with open(STATE_PATH, "w") as f:
        json.dump({"dhash": dhash_val, "file_hash": file_hash_val, "last_result": result, "idle_streak": idle_streak}, f, ensure_ascii=False)


def classify(image_data, app_name, prev_activity):
    client = genai.Client(
        api_key=API_KEY,
        http_options=genai.types.HttpOptions(
            retry_options=genai.types.HttpRetryOptions(attempts=5),
        ),
    )
    prompt_text = f"The foreground application is: {app_name}\n\n"
    if prev_activity:
        prompt_text += f"The user's previous activity was: {prev_activity}\n\n"
    prompt_text += PROMPT
    response = client.models.generate_content(
        model=MODEL,
        contents=[
            prompt_text,
            genai.types.Part.from_bytes(data=image_data, mime_type="image/png"),
        ],
        config=genai.types.GenerateContentConfig(
            thinking_config=genai.types.ThinkingConfig(thinking_budget=0),
            media_resolution=genai.types.MediaResolution.MEDIA_RESOLUTION_MEDIUM,
            response_mime_type="application/json",
            response_schema={
                "type": "OBJECT",
                "properties": {
                    "activity": {
                        "type": "STRING",
                        "description": "The specific activity, without the app name. E.g. 'editing init.lua timer logic', 'reading React hooks docs', 'watching 外星人纪录片'. Max 10 words. If the work is highly similar to the previous activity, reuse the previous activity text exactly.",
                    },
                    "key_content": {
                        "type": "STRING",
                        "description": "Quote the most relevant visible text: a code snippet, chat message, article title, video title, or terminal command. Max 40 words. This grounds your classification in what you actually read.",
                    },
                    "category": {
                        "type": "STRING",
                        "enum": ["OUTPUT", "INPUT", "DISTRACTED"],
                        "description": "Activity classification based on the visible text content you read, not just the app name",
                    },
                    "confidence": {
                        "type": "NUMBER",
                        "description": "Classification confidence from 0.0 to 1.0",
                    },
                    "reason": {
                        "type": "STRING",
                        "description": "Under 15 words describing the observed activity",
                    },
                    "switching": {
                        "type": "BOOLEAN",
                        "description": "True ONLY if the user switched to a fundamentally different activity from their previous one. Switching apps does NOT count — judge by the actual work. Examples of NOT switching: 'editing init.lua' → 'git push init.lua changes' (same project), 'coding RLE in browser' → 'testing RLE in terminal' (same task), 'reading React docs' → 'coding React component' (same topic). Examples of switching: 'coding RLE algorithm' → 'browsing Reddit', 'writing essay' → 'debugging server'. Always false if no previous activity is provided.",
                    },
                },
                "required": ["activity", "key_content", "category", "confidence", "reason", "switching"],
            },
        ),
    )

    result = json.loads(response.text)
    # Gemini sometimes returns literal \uXXXX instead of actual unicode chars
    for k, v in result.items():
        if isinstance(v, str):
            if "\\u" in v:
                v = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), v)
            result[k] = re.sub(r"[\x00-\x09\x0b\x0c\x0e-\x1f]+", " ", v).strip()
    result["app"] = app_name
    if response.usage_metadata:
        m = response.usage_metadata
        result["tokens"] = {
            "input": m.prompt_token_count,
            "output": m.candidates_token_count,
            "total": m.total_token_count,
        }
        if getattr(m, "thoughts_token_count", None):
            result["tokens"]["thinking"] = m.thoughts_token_count
    return result


def emit_idle(event, state, app_name, dhash_val, file_hash_val, **log_extra):
    streak = state.get("idle_streak", 0) + 1
    prev = state["last_result"]
    if streak < IDLE_STREAK_THRESHOLD:
        save_state(dhash_val, file_hash_val, prev, idle_streak=streak)
        print(json.dumps(prev, ensure_ascii=False))
        return

    prev = dict(prev, app=app_name, activity="away from keyboard", idle=True, switching=False)
    save_state(dhash_val, file_hash_val, prev, idle_streak=streak)
    log_jsonl(event, prev, **log_extra)
    print(json.dumps(prev, ensure_ascii=False))


def main():
    rotate_log()

    if not API_KEY:
        print("ERROR: GEMINI_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    if len(sys.argv) < 3:
        print("ERROR: usage: classify.py <image_path> <app_name>", file=sys.stderr)
        sys.exit(1)

    image_path = sys.argv[1]
    app_name = sys.argv[2]
    if not os.path.exists(image_path):
        print(f"ERROR: image not found: {image_path}", file=sys.stderr)
        sys.exit(1)

    with open(image_path, "rb") as f:
        image_data = f.read()

    # Two-tier idle detection avoids wasting API calls on unchanged screens
    state = load_state()
    current_file_hash = file_hash(image_data)

    # Exact match is cheap (no Pillow import needed)
    if state and current_file_hash == state.get("file_hash"):
        emit_idle("idle_exact", state, app_name, state.get("dhash", 0), current_file_hash)
        return

    # Perceptual hash catches near-identical screens (clock tick, cursor blink)
    current_dhash = dhash(image_data)
    if state and hamming(current_dhash, state.get("dhash", 0)) < DHASH_THRESHOLD:
        emit_idle("idle_dhash", state, app_name, current_dhash, current_file_hash,
                  hamming=hamming(current_dhash, state["dhash"]))
        return

    prev_activity = state.get("last_result", {}).get("activity") if state else None
    result = classify(image_data, app_name, prev_activity)
    save_state(current_dhash, current_file_hash, result)
    log_jsonl("classify", result)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
