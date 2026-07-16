"""LiteLLM callback: convert image content blocks to text via Groq vision API.

Registered in litellm-config.yaml as one of the entries in:
    litellm_settings:
      callbacks: ["prometheus", "groq_vision_callback.proxy_handler_instance"]

Uses only stdlib (urllib + json + base64) — zero extra pip dependencies.
"""
import base64
import json
import os
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from litellm.integrations.custom_logger import CustomLogger

VISION_MODEL = os.environ.get(
    "GROQ_VISION_MODEL", "meta-llama/llama-4-scout-17b-16e-instruct"
)
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")
GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions"

VISION_PROMPT = (
    "Describe this image in detail. Identify all relevant elements, context, "
    "and anything that would help someone who cannot see it."
)


def _describe_image(image_data: bytes, prompt: str = VISION_PROMPT) -> str | None:
    """Send image to Groq vision API, return text description or None on failure."""
    b64 = base64.b64encode(image_data).decode("utf-8")
    body = json.dumps({
        "model": VISION_MODEL,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
            ],
        }],
        "temperature": 0.5,
        "max_tokens": 2048,
    }).encode("utf-8")

    req = Request(
        GROQ_API_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {GROQ_API_KEY}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
            return result["choices"][0]["message"]["content"]
    except Exception:
        return None


def _image_data_from_block(block: dict) -> bytes | None:
    """Extract raw image bytes from an image_url content block."""
    url = block.get("image_url", {}).get("url", "")
    if url.startswith("data:"):
        return base64.b64decode(url.split(",", 1)[-1])
    return None


class GroqVisionCallback(CustomLogger):
    """Intercepts requests containing images, converts them to text via Groq."""

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        """Called by LiteLLM before each LLM API call. Modifies data in-place."""
        if not GROQ_API_KEY:
            return

        messages = data.get("messages", [])
        for msg in messages:
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            new_blocks = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "image_url":
                    img_bytes = _image_data_from_block(block)
                    if img_bytes:
                        description = _describe_image(img_bytes)
                        if description:
                            new_blocks.append({"type": "text", "text": description})
                            continue
                    new_blocks.append({
                        "type": "text",
                        "text": "[Image could not be processed by vision model]",
                    })
                else:
                    new_blocks.append(block)
            msg["content"] = new_blocks


# Module-level instance required by LiteLLM callback system.
# Referenced in config.yaml as: groq_vision_callback.proxy_handler_instance
proxy_handler_instance = GroqVisionCallback()
