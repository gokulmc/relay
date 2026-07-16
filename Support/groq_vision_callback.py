"""LiteLLM callback: convert image content blocks to text via Groq vision API.

Registered in litellm-config.yaml as one of the entries in:
    litellm_settings:
      callbacks: ["prometheus", "groq_vision_callback.proxy_handler_instance"]

Uses only stdlib (urllib + json + base64) — zero extra pip dependencies.

The point of this hook is provider-agnostic: it strips every image out of a request
and replaces it with a Groq-generated text description *before* LiteLLM forwards the
request to whatever backend model is selected. That lets a non-vision model (DeepSeek,
or anything the proxy routes to) answer a query that arrived with images attached.
It handles the two content shapes that reach the proxy — OpenAI `image_url` blocks and
Anthropic `image`/`source` blocks — and descends into Anthropic `tool_result` blocks,
whose nested images are exactly what non-vision backends reject as "multimodal function
responses".
"""
import base64
import json
import os
import ssl
from urllib.request import Request, urlopen

from litellm.integrations.custom_logger import CustomLogger

# The proxy runs under a Homebrew/venv Python whose stdlib urllib has no CA
# bundle configured, so HTTPS to api.groq.com fails with CERTIFICATE_VERIFY_FAILED.
# litellm depends on certifi, so use its bundle for a verified TLS context.
try:
    import certifi
    _SSL_CTX = ssl.create_default_context(cafile=certifi.where())
except Exception:
    _SSL_CTX = ssl.create_default_context()

VISION_MODEL = os.environ.get(
    "GROQ_VISION_MODEL", "meta-llama/llama-4-scout-17b-16e-instruct"
)
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")
GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions"

VISION_PROMPT = (
    "Describe this image in detail. Identify all relevant elements, context, "
    "and anything that would help someone who cannot see it."
)

# Fallback text substituted when Groq can't describe an image, so the request still
# reaches the backend as pure text rather than failing on a stray image block.
UNPROCESSED_TEXT = "[Image could not be processed by vision model]"


def _describe_image(
    image_data: bytes, media_type: str = "image/png", prompt: str = VISION_PROMPT
) -> str | None:
    """Send image to Groq vision API, return text description or None on failure."""
    b64 = base64.b64encode(image_data).decode("utf-8")
    body = json.dumps({
        "model": VISION_MODEL,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url",
                 "image_url": {"url": f"data:{media_type};base64,{b64}"}},
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
            # Groq sits behind Cloudflare, which blocks the default
            # "Python-urllib/x.y" UA with a 403 (error 1010). Send a plain UA.
            "User-Agent": "Relay/1.0",
        },
    )
    try:
        with urlopen(req, timeout=30, context=_SSL_CTX) as resp:
            result = json.loads(resp.read())
            return result["choices"][0]["message"]["content"]
    except Exception:
        return None


def _image_from_block(block: dict) -> tuple[bytes, str] | None:
    """Extract (raw bytes, media_type) from an image block in either wire format.

    OpenAI:    {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
    Anthropic: {"type": "image", "source": {"type": "base64",
                                            "media_type": "image/png", "data": "..."}}
    Returns None for URL-referenced (non-data) images, which we can't fetch here.
    """
    btype = block.get("type")
    if btype == "image_url":
        url = block.get("image_url", {}).get("url", "")
        if url.startswith("data:"):
            header, _, payload = url.partition(",")
            # header looks like "data:image/png;base64"
            media_type = header[5:].split(";", 1)[0] or "image/png"
            try:
                return base64.b64decode(payload), media_type
            except Exception:
                return None
    elif btype == "image":
        source = block.get("source", {})
        if source.get("type") == "base64" and source.get("data"):
            media_type = source.get("media_type") or "image/png"
            try:
                return base64.b64decode(source["data"]), media_type
            except Exception:
                return None
    return None


def _text_block(text: str) -> dict:
    return {"type": "text", "text": text}


def transform_blocks(content: list, describe=None) -> list:
    """Return a copy of a content-block list with every image replaced by its text
    description. Recurses into `tool_result` blocks whose content is itself a list.

    `describe` is injectable so the walk can be unit-tested without calling Groq. It
    resolves to the module-level `_describe_image` at call time (not bind time) so a
    monkeypatched replacement is honored on the live hook path too.
    """
    if describe is None:
        describe = _describe_image
    new_blocks = []
    for block in content:
        if not isinstance(block, dict):
            new_blocks.append(block)
            continue

        img = _image_from_block(block)
        if img is not None:
            data, media_type = img
            description = describe(data, media_type)
            new_blocks.append(_text_block(description or UNPROCESSED_TEXT))
            continue

        # Anthropic tool results carry their payload in a nested content list, which
        # may itself hold images — the "multimodal function response" case.
        if block.get("type") == "tool_result" and isinstance(block.get("content"), list):
            new_blocks.append({**block, "content": transform_blocks(block["content"], describe)})
            continue

        new_blocks.append(block)
    return new_blocks


class GroqVisionCallback(CustomLogger):
    """Intercepts requests containing images, converts them to text via Groq."""

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        """Called by LiteLLM before each LLM API call. Modifies data in-place."""
        if not GROQ_API_KEY:
            return

        for msg in data.get("messages", []):
            content = msg.get("content")
            if isinstance(content, list):
                msg["content"] = transform_blocks(content)


# Module-level instance required by LiteLLM callback system.
# Referenced in config.yaml as: groq_vision_callback.proxy_handler_instance
proxy_handler_instance = GroqVisionCallback()
