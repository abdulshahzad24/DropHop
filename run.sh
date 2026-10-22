#!/bin/bash
# Starts the Ghostly server locally; a token enables access from iPhone or iPad.
cd "$(dirname "$0")"
[ -d .venv ] || python3 -m venv .venv
source .venv/bin/activate
pip install -q -r requirements.txt
if [ -n "${GHOSTLY_TOKEN:-}" ]; then
  BIND_HOST=0.0.0.0
  echo "Your Mac's address on Wi-Fi: http://$(ipconfig getifaddr en0 2>/dev/null || echo '<your-mac-ip>'):8000"
else
  BIND_HOST=127.0.0.1
  echo "Listening on this Mac only. Set GHOSTLY_TOKEN to allow iPhone/iPad access."
fi
# Put your key here, or export it before running:
#   export ANTHROPIC_API_KEY=sk-ant-...      (paid)
#   export GEMINI_API_KEY=...                (free tier)
exec uvicorn app:app --host "$BIND_HOST" --port 8000
