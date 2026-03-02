# focus-color

**On average, developers spend 41% of their day not writing code.** Most do not know where the time goes.

focus-color is a macOS menubar tool that automatically categorizes your screen activity using AI — no timers to start, no categories to pick, no browser extensions to install. It reads the actual text visible on your screen and determines what you are doing. At the end of the week, you have a log with over 10,000 data points showing exactly how you spent your time.

<!-- TODO: Insert screenshot of macOS menubar showing the green, blue, and orange dots -->

## Categorizing Your Time

Hammerspoon takes a screenshot at your configured interval. The AI reads the visible text and classifies your activity, shown as a single colored dot in your menubar:

| Dot | Category | Examples |
|-----|----------|----------|
| Green | **OUTPUT** | Writing code, composing docs, running terminal commands, debugging |
| Blue | **INPUT** | Reading documentation, watching a technical talk, studying code |
| Orange | **DISTRACTED** | Browsing social media, configuring tools, idle screen |

## Data and Logging

Everything is logged locally to `~/.config/focus-color/log.jsonl`. Each entry includes the timestamp, active app, visible text snippet, classification, and confidence score.

- **View reasoning** — Click the menubar dot to see why the AI classified you that way.
- **Pause tracking** — Select "Pause" from the dropdown menu when you need a break.
- **Daily breakdown** — Run `uv run cost.py --today` to see your daily statistics.

> **Privacy:** This tool sends full screenshots to the Gemini API for classification. Do not use it if your screen frequently displays sensitive information such as plaintext passwords, credentials, or confidential customer data.

## Installation

**Prerequisites:** [Hammerspoon](https://www.hammerspoon.org/), [uv](https://docs.astral.sh/uv/), and a [Gemini API key](https://aistudio.google.com/apikey) (free tier is sufficient).

1. Clone the repository:
   ```bash
   git clone https://github.com/wilbeibi/focus-color ~/.hammerspoon/focus-color
   ```

2. Create your configuration file:
   ```bash
   cd ~/.hammerspoon/focus-color
   cp config.yaml.example config.yaml
   ```

3. Edit `config.yaml` and add your Gemini API key.

4. Add one line to `~/.hammerspoon/init.lua`:
   ```lua
   require("focus-color")
   ```

5. Reload Hammerspoon. Grant Screen Recording permission if prompted by macOS. The tracking dot will appear in your menubar.

## Configuration

```yaml
api_key: your-gemini-api-key
model: gemini-2.5-flash   # any Gemini model
interval: 30               # seconds between screen checks
```

## Cost

**Free tier:** Runs well within Gemini's free tier (2 RPM, limit is 15 RPM). Idle detection automatically skips unchanged screens.

**Paid tier:** ~$0.10–0.40/day depending on usage.

## License

MIT
