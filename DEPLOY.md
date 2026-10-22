# Put the Ghostly server online

Then the app works from any network, even with your Mac off.

## 1. Make a secret token
Anyone who finds your server's address could otherwise use your AI key. In Terminal:

    openssl rand -hex 24

Copy the result. This is your GHOSTLY_TOKEN.

## 2. Put the Server folder on GitHub
Create a new private repository and upload the contents of the `Server` folder
(app.py, requirements.txt, Dockerfile, render.yaml). Do NOT upload any API keys.

## 3. Deploy on Render (render.com)
1. New > Web Service > connect your GitHub repo. Render finds the Dockerfile.
2. Under Environment add:
   - ANTHROPIC_API_KEY = your Claude key and/or OPENAI_API_KEY = your OpenAI key
   - GHOSTLY_TOKEN = the token from step 1
3. Deploy. When it finishes you get an address like https://ghostly-server.onrender.com

Railway and Fly.io work the same way: they also read the Dockerfile and need the same two variables.

## 4. Connect the apps
Settings > Ghostly AI:
- Server address: the https address from step 3
- Access token: the same token
- Tap Test connection. It should say "Connected".

## Good to know
- Free plans usually put the server to sleep after some idle time. The first request then takes
  up to a minute. If Test connection times out, wait 30-60 seconds and try again.
- Plans, limits and prices change, so check the host's pricing page.
- This lite setup has no local CLIP/BLIP models (too large for small hosts). It needs an AI key.
- The moodboard folder is not kept between restarts on most hosts.
- Never share the token or the API key. If one leaks, change it in the host's dashboard and in the app.
