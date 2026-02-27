# /// script
# requires-python = ">=3.11"
# dependencies = ["google-genai", "Pillow"]
# ///

import hashlib
import io
import json
import os
import sys
from datetime import datetime
from google import genai

API_KEY = os.environ.get("GEMINI_API_KEY", "")
MODEL = "gemini-2.5-flash"
STATE_PATH = "/tmp/focus-color-state.json"
JSONL_PATH = os.path.expanduser("~/.config/focus-color/log.jsonl")
DHASH_THRESHOLD = 6  # Hamming distance: 0=identical, 64=opposite
PROMPT = """Analyze this screenshot to classify the user's current activity.

First, identify the foreground application from the title bar or window chrome.
Then, examine what the user is actively doing based on visible content, cursor position, and UI state.

Classify into exactly one category:

OUTPUT — Actively producing or creating. Key signals: cursor in an editable area, recent edits visible, typing code, composing text, running commands, writing in a document, solving a problem, designing. Includes: coding in an editor, terminal commands, writing notes or docs, LeetCode (any stage — reading problem, writing solution, debugging), using AI chat to generate/debug code, committing/pushing code.

INPUT — Intentionally consuming information with focus. Key signals: reading a long-form article or documentation, watching a technical video, studying code or solutions, reviewing a PR. Includes: reading docs, watching a tech talk or tutorial, system design study material, reading email, interview prep reading, using AI chat to research a topic or learn concepts.

DISTRACTED — Off-task, unfocused, or low-value activity. Key signals: entertainment content, social media feeds, idle browsing, no clear goal. Includes: Bilibili/YouTube entertainment or anime, social media scrolling (Twitter/Reddit feeds), shopping, news rabbit holes, scenic/relaxation videos, gaming. Also: lock screen, screensaver, idle desktop. Tool/environment configuration (dotfiles, editor plugins, network setup) that is not directly part of a current project counts as DISTRACTED — it feels productive but delays real output.

Disambiguation rules:
- YouTube/Bilibili: INPUT only if clearly a tech talk, tutorial, or lecture. Entertainment, anime, vlogs, scenic videos → DISTRACTED.
- Reddit/Twitter/HN: INPUT only if reading a specific technical thread. Scrolling a feed → DISTRACTED.
- AI chat (Claude, ChatGPT, Gemini): OUTPUT if the conversation is about coding, building, or debugging. INPUT if researching a topic or learning concepts. DISTRACTED if chitchat, aimless exploring, or no clear goal.
- LeetCode/coding challenges: always OUTPUT — reading the problem, writing the solution, and debugging are all part of producing a solution.
- Obsidian/notes: OUTPUT if actively writing. INPUT if reading/reviewing notes.
- Terminal: OUTPUT if running project commands. DISTRACTED if configuring unrelated tools.
- Browser: judge by visible page content, not the browser itself.
- When genuinely ambiguous between OUTPUT and INPUT, prefer OUTPUT if a cursor is active in an editable area.

Examples:
- VS Code with cursor in a code file, recent edits visible → OUTPUT
- Terminal running pytest or git push → OUTPUT
- LeetCode at any stage (reading problem, writing code, debugging) → OUTPUT
- Claude chat discussing code architecture or debugging → OUTPUT
- ChatGPT conversation researching system design concepts → INPUT
- Browser showing React documentation, scroll mid-page → INPUT
- YouTube showing a system design talk → INPUT
- Obsidian with a study note open, reading → INPUT
- Bilibili showing anime or vlogs → DISTRACTED
- Twitter/Reddit feed scrolling → DISTRACTED
- Configuring Tailscale, Obsidian plugins, SSH keys → DISTRACTED
- Lock screen or screensaver → DISTRACTED

Keep the reason under 15 words, describing what you observe."""


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
                    "category": {
                        "type": "STRING",
                        "enum": ["OUTPUT", "INPUT", "DISTRACTED"],
                        "description": "Activity classification based on visible screen content",
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
                "required": ["active_app", "category", "confidence", "reason"],
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


def is_switching(window=6, threshold=3, tail_bytes=10 * 1024):
    """Check if recent classify entries show frequent context switching."""
    if not os.path.exists(JSONL_PATH):
        return False
    try:
        size = os.path.getsize(JSONL_PATH)
        with open(JSONL_PATH) as f:
            if size > tail_bytes:
                f.seek(size - tail_bytes)
                f.readline()  # discard partial first line
            lines = f.readlines()
        # Only count real classifications, not idle ticks
        entries = []
        for line in reversed(lines):
            entry = json.loads(line)
            if entry.get("event") == "classify":
                entries.append(entry)
                if len(entries) == window:
                    break
        apps = set(e["app"] for e in entries if e.get("app"))
        return len(apps) >= threshold
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
    result["switching"] = is_switching()
    save_state(current_dhash, current_file_hash, result)
    log_jsonl("classify", result)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
