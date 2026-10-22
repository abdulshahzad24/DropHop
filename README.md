# Ghostly AI server

Ghost Browser sends selected images, page screenshots, and relevant page context to this server
when you use Ghostly AI. The server forwards AI requests to the selected provider and can find
tutorials and similar images.

Designer Mode sends inspected page images and their selected tool context to `POST /design-tool`.
The server routes Inspect, Colors, Typography, Assets, and Page Information through the
Claude or OpenAI model selected in Ghostly; page text is treated as untrusted content.

## Start it (Mac)
1. Set one or both provider keys in Terminal, according to the models you want to use:
   - `export ANTHROPIC_API_KEY=...` for Claude (Sonnet is the default).
   - `export OPENAI_API_KEY=...` for OpenAI analysis and primary image generation.
2. Optional image generation fallback: set up Cloudflare Workers AI credentials:
   ```sh
   export CLOUDFLARE_ACCOUNT_ID="your-account-id"
   export CLOUDFLARE_API_TOKEN="your-workers-ai-token"
   ```
3. Run `./run.sh` in this folder (first run installs dependencies). Restart it after changing keys.

Image generation uses OpenAI `gpt-image-2.5-flare` by default. Set `OPENAI_IMAGE_MODEL` to another supported image edit model if needed. Cloudflare's `@cf/black-forest-labs/flux-2-klein-4b` is used only when OpenAI is unavailable or fails. Claude is used for analysis and questions, not image generation.

Optional offline models (no key, big download): `pip install -r requirements-local.txt`.

## Connect the app
- iOS Simulator or the Mac app: leave Settings > Ghostly AI empty (default http://127.0.0.1:8000).
- Real iPhone/iPad: set a strong `GHOSTLY_TOKEN` before `./run.sh`, then enter your Mac's IP
  (printed by the script) and the same token in the app. Without a token the server listens
  only on `127.0.0.1`. Use the same Wi-Fi and allow Local Network when iOS asks.
- Press "Test connection". It should say "Connected to ...".

Online hosting: see DEPLOY.md.

Check from the Mac: `curl http://127.0.0.1:8000/openapi.json` should print JSON.
