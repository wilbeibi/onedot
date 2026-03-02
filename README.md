# focus-color

A Hammerspoon menubar module that classifies your screen activity every 30 seconds using Gemini Flash. It shows a colored dot indicating whether you're producing work, consuming information, or distracted.

## How it works

Every 30 seconds, Hammerspoon captures a screenshot and sends it to Gemini Flash for classification. The AI reads the visible text on screen (not just the app name) and categorizes your activity:

| Category | Dot Color | Meaning |
|----------|-----------|---------|
| OUTPUT | Green | Creating — coding, writing, designing, building |
| INPUT | Blue | Consuming — reading docs, watching tutorials, studying |
| DISTRACTED | Orange | Off-task — social media, entertainment, aimless browsing |

When frequent context switching is detected (many category transitions in the last 10 minutes), the dot shows an amber center with a category-colored ring.

## Prerequisites

- [Hammerspoon](https://www.hammerspoon.org/) with Screen Recording permission granted
- [uv](https://docs.astral.sh/uv/) — Python package runner (`curl -LsSf https://astral.sh/uv/install.sh | sh`)
- A [Gemini API key](https://aistudio.google.com/apikey) (free tier works fine)

## Install

1. Clone into your Hammerspoon config directory:
   ```bash
   git clone https://github.com/user/focus-color ~/.hammerspoon/focus-color
   ```

2. Create your config file:
   ```bash
   cd ~/.hammerspoon/focus-color
   cp config.yaml.example config.yaml
   # Edit config.yaml and add your Gemini API key
   ```

3. Load the module in `~/.hammerspoon/init.lua`:
   ```lua
   require("focus-color")
   ```

4. Reload Hammerspoon (or it will auto-reload if you have a pathwatcher on `~/.hammerspoon/`).

The colored dot should appear in your menubar. Click it to see the last classification reason, or to pause tracking.

## Configuration

Edit `config.yaml`:

```yaml
api_key: your-gemini-api-key
model: gemini-2.5-flash
interval: 30
```

| Key | Default | Description |
|-----|---------|-------------|
| `api_key` | (required) | Your Gemini API key |
| `model` | `gemini-2.5-flash` | Gemini model to use |
| `interval` | `30` | Seconds between screenshots |

## Log

Classifications are logged as JSONL to `~/.config/focus-color/log.jsonl`:

```json
{"ts": "2026-02-27T14:30:00", "event": "classify", "model": "gemini-2.5-flash", "category": "OUTPUT", "app": "VS Code — init.lua", "key_content": "editing captureAndClassify function", "confidence": 0.92, "reason": "User is writing Lua code in VS Code"}
```

Events: `classify` (API call made), `idle_exact` (identical screenshot skipped), `idle_dhash` (perceptually similar screenshot skipped).

## Cost

At 30-second intervals during a 13-hour day (~1,560 calls), idle detection typically reduces actual API calls to a fraction of that. Fits within Gemini's free tier (15 RPM, we use 2 RPM). On the paid tier, expect ~$0.10–0.40/day depending on idle patterns.

Check your actual usage:

```bash
uv run cost.py --today
uv run cost.py --week
uv run cost.py 2026-02-27
```

## License

MIT
