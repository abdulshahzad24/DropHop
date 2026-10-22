import base64
import io
import unittest
from unittest.mock import Mock, patch

from PIL import Image

import app


class ModelRoutingTests(unittest.TestCase):
    def setUp(self):
        self.image = Image.new("RGB", (8, 8), "white")

    def test_openai_answer_uses_selected_model(self):
        response = Mock()
        response.json.return_value = {"output": [{"content": [{"type": "output_text", "text": "Answer"}]}]}
        with patch.object(app, "OPENAI_KEY", "test-key"), patch.object(app.requests, "post", return_value=response) as post:
            self.assertEqual(app.openai_answer([self.image], "Question", "gpt-6-luna"), "Answer")
        self.assertEqual(post.call_args.kwargs["json"]["model"], "gpt-6-luna")

    def test_sonnet_skips_upfront_thinking(self):
        client = Mock()
        client.messages.create.return_value.content = [Mock(type="text", text="Answer")]
        with patch.object(app, "_claude", client):
            self.assertEqual(app.claude_answer([self.image], "Question", "claude-sonnet-5-5"), "Answer")
        self.assertEqual(client.messages.create.call_args.kwargs["thinking"], {"type": "between_tools"})

    def test_image_generation_prefers_openai(self):
        output = io.BytesIO()
        self.image.save(output, format="PNG")
        response = Mock()
        response.json.return_value = {"data": [{"b64_json": base64.b64encode(output.getvalue()).decode()}]}
        with patch.object(app, "OPENAI_KEY", "test-key"), patch.object(app.requests, "post", return_value=response), \
             patch.object(app, "cloudflare_generate_image") as fallback:
            result = app.generate_image([self.image], "Make a variation")
        self.assertEqual(result["engine"], "gpt-image-2.5-flare")
        fallback.assert_not_called()

    def test_image_generation_falls_back_to_cloudflare(self):
        with patch.object(app, "OPENAI_KEY", "test-key"), patch.object(app, "CF_ACCOUNT_ID", "account"), \
             patch.object(app, "CF_API_TOKEN", "token"), patch.object(app.requests, "post", side_effect=OSError("offline")), \
             patch.object(app, "cloudflare_generate_image", return_value={"engine": "cloudflare"}) as fallback:
            self.assertEqual(app.generate_image([self.image], "Variation")["engine"], "cloudflare")
        fallback.assert_called_once()

    def test_analysis_cache_is_separate_per_model(self):
        with patch.object(app, "analyze", side_effect=lambda *args: {"engine": args[-1]}) as analyze:
            app._RESULT_CACHE.clear()
            app.analyze_cached([self.image], [b"image"], model="claude-sonnet-5-5")
            app.analyze_cached([self.image], [b"image"], model="gpt-6-luna")
            self.assertEqual(analyze.call_count, 2)


if __name__ == "__main__":
    unittest.main()
