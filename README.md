# onedot

**The macOS tool that tells you where your day actually went.**

Every week, the average developer loses 41% of their time to things that aren't code.   
They don't track it because tracking feels like more work.  
onedot requires nothing from you. It sits in your menubar, reads the text on your screen, and categorizes what you're doing — automatically, continuously, invisibly.

<img width="326" height="121" alt="image" src="https://github.com/user-attachments/assets/c6e24864-2810-4cdd-bff7-51392dcb42d2" />


## Categorizing Your Time

Hammerspoon takes a screenshot at your configured interval. The AI reads the visible text and classifies your activity, shown as a single colored dot in your menubar:

| Dot | Category | Examples |
|-----|----------|----------|
| Green | **OUTPUT** | Writing code, composing docs, running terminal commands, debugging |
| Blue | **INPUT** | Reading documentation, watching a technical talk, studying code |
| Orange | **DISTRACTED** | Browsing social media, configuring tools, idle screen |

## Context-Switch Nudge

When the AI detects you've drifted to a different activity — say, from coding to browsing Reddit — a centered overlay pops up showing what you switched away from. Drag the snooze bar to suppress it for 10–30 minutes if the switch was intentional.

## Data and Logging

Everything is logged locally to `~/.config/onedot/log.jsonl`. Each entry includes the timestamp, active app, visible text snippet, classification, and confidence score.

- **View reasoning** — Click the menubar dot to see why the AI classified you that way.
- **Pause tracking** — Select "Pause" from the dropdown menu when you need a break.
- **Daily breakdown** — Run `uv run cost.py --today` to see your daily statistics.

> **Privacy:** This tool sends full screenshots to the Gemini API for classification. Do not use it if your screen frequently displays sensitive information such as plaintext passwords, credentials, or confidential customer data.
>
> You can exclude sensitive apps (e.g. password managers, messaging apps) from screenshot capture by setting `exclude_apps` in your config. When an excluded app is in the foreground, onedot skips the screenshot entirely — nothing is sent to the API.

## Installation

**Prerequisites:** [Hammerspoon](https://www.hammerspoon.org/), [uv](https://docs.astral.sh/uv/), and a [Gemini API key](https://aistudio.google.com/apikey) (free tier is sufficient).

1. Clone the repository:
   ```bash
   git clone https://github.com/wilbeibi/onedot ~/.hammerspoon/onedot
   ```

2. Create your configuration file:
   ```bash
   mkdir -p ~/.config/onedot
   cp ~/.hammerspoon/onedot/config.yaml.example ~/.config/onedot/config.yaml
   ```

3. Edit `~/.config/onedot/config.yaml` and add your Gemini API key.

4. Add one line to `~/.hammerspoon/init.lua`:
   ```lua
   require("onedot")
   ```

5. Reload Hammerspoon. Grant Screen Recording permission if prompted by macOS. The tracking dot will appear in your menubar.

## Configuration

```yaml
api_key: your-gemini-api-key
model: gemini-2.5-flash   # any Gemini model
interval_secs: 30          # seconds between screen checks
exclude_apps: 1Password, Keychain Access, Slack  # optional, comma-separated app names
```

## Cost

**Free tier:** Runs well within Gemini's free tier (2 RPM, limit is 15 RPM). Idle detection automatically skips unchanged screens.

**Paid tier:** ~$0.10–0.40/day depending on usage.

## License

MIT
