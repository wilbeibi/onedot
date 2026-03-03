# /// script
# requires-python = ">=3.11"
# dependencies = ["google-genai", "Pillow"]
# ///

import hashlib
import io
import json
import os
import sys
from datetime import datetime, timedelta
from google import genai

API_KEY = os.environ.get("GEMINI_API_KEY", "")
MODEL = os.environ.get("MODEL", "gemini-2.5-flash")
STATE_PATH = "/tmp/focus-color-state.json"
JSONL_PATH = os.path.expanduser("~/.config/focus-color/log.jsonl")
DHASH_THRESHOLD = 6  # Hamming distance: 0=identical, 64=opposite
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


def log_jsonl(event, result, **extra):
    """Append one JSON line per tick — classifications, idle skips, tokens, timing."""
    os.makedirs(os.path.dirname(JSONL_PATH), exist_ok=True)
    entry = {
        "ts": datetime.now().isoformat(),
        "event": event,
        "model": MODEL,
        "category": result.get("category"),
        "app": result.get("active_app"),
    }
    if event == "classify":
        entry["key_content"] = result.get("key_content")
        entry["confidence"] = result.get("confidence")
        entry["reason"] = result.get("reason")
        entry["tokens"] = result.get("tokens")
        entry["switching"] = result.get("switching")
    if extra:
        entry.update(extra)
    with open(JSONL_PATH, "a") as f:
        f.write(json.dumps(entry) + "\n")


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


def save_state(dhash_val, file_hash_val, result):
    with open(STATE_PATH, "w") as f:
        json.dump({"dhash": dhash_val, "file_hash": file_hash_val, "last_result": result}, f)


def classify(image_data):
    client = genai.Client(api_key=API_KEY)
    response = client.models.generate_content(
        model=MODEL,
        contents=[
            genai.types.Part.from_bytes(data=image_data, mime_type="image/png"),
            PROMPT,
        ],
        config=genai.types.GenerateContentConfig(
            response_mime_type="application/json",
            response_schema={
                "type": "OBJECT",
                "properties": {
                    "active_app": {
                        "type": "STRING",
                        "description": "The foreground app and specific context, e.g. 'Chrome — React docs', 'VS Code — init.lua', 'YouTube — system design talk'",
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
                },
                "required": ["active_app", "key_content", "category", "confidence", "reason"],
            },
        ),
    )

    result = json.loads(response.text)
    if response.usage_metadata:
        result["tokens"] = {
            "input": response.usage_metadata.prompt_token_count,
            "output": response.usage_metadata.candidates_token_count,
        }
    return result


def is_context_switching(window_minutes=10, threshold=5, tail_bytes=40 * 1024):
    """Check if recent classify entries show frequent context switching.
    Counts category transitions within the last window_minutes minutes.
    Ignores entries older than the window, so idle/sleep gaps reset the signal."""
    if not os.path.exists(JSONL_PATH):
        return False
    try:
        cutoff = datetime.now().astimezone().replace(tzinfo=None)
        cutoff -= timedelta(minutes=window_minutes)
        size = os.path.getsize(JSONL_PATH)
        with open(JSONL_PATH) as f:
            if size > tail_bytes:
                f.seek(size - tail_bytes)
                f.readline()
            lines = f.readlines()
        entries = []
        for line in lines:
            entry = json.loads(line)
            if entry.get("event") != "classify":
                continue
            try:
                ts = datetime.fromisoformat(entry["ts"])
            except (KeyError, ValueError):
                continue
            if ts >= cutoff and entry.get("category"):
                entries.append(entry)
        categories = [e["category"] for e in entries]
        transitions = sum(1 for a, b in zip(categories, categories[1:]) if a != b)
        return transitions >= threshold
    except Exception:
        return False


def main():
    if not API_KEY:
        print("ERROR: GEMINI_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    if len(sys.argv) < 2:
        print("ERROR: image path required as argument", file=sys.stderr)
        sys.exit(1)

    image_path = sys.argv[1]
    if not os.path.exists(image_path):
        print(f"ERROR: image not found: {image_path}", file=sys.stderr)
        sys.exit(1)

    # --- Read screenshot once, reuse everywhere ---
    with open(image_path, "rb") as f:
        image_data = f.read()

    # --- Idle detection (two-tier) ---
    state = load_state()
    current_file_hash = file_hash(image_data)

    # Tier 1: exact file match — no image processing, no Pillow import
    if state and current_file_hash == state.get("file_hash"):
        output = dict(state["last_result"], idle=True)
        log_jsonl("idle_exact", state["last_result"])
        print(json.dumps(output))
        return

    # Tier 2: perceptual similarity via dHash — catches clock/cursor changes
    current_dhash = dhash(image_data)
    if state and hamming(current_dhash, state.get("dhash", 0)) < DHASH_THRESHOLD:
        dist = hamming(current_dhash, state["dhash"])
        save_state(current_dhash, current_file_hash, state["last_result"])
        log_jsonl("idle_dhash", state["last_result"], hamming=dist)
        output = dict(state["last_result"], idle=True)
        print(json.dumps(output))
        return

    # --- Screen changed: classify with Gemini ---
    result = classify(image_data)
    result["switching"] = is_context_switching()
    save_state(current_dhash, current_file_hash, result)
    log_jsonl("classify", result)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
