"""Unit tests for groq_vision_callback.transform_blocks — the pure image→text walk.

No network: a stub describer replaces the Groq call. Runs with plain python3 (the
`litellm` import is stubbed so the module loads without the proxy's venv).

    python3 Support/test_groq_vision_callback.py
"""
import base64
import sys
import types

# Stub the litellm import so the module loads outside the proxy venv.
_custom_logger = types.ModuleType("litellm.integrations.custom_logger")
_custom_logger.CustomLogger = object
sys.modules.setdefault("litellm", types.ModuleType("litellm"))
sys.modules.setdefault("litellm.integrations", types.ModuleType("litellm.integrations"))
sys.modules["litellm.integrations.custom_logger"] = _custom_logger

import groq_vision_callback as cb  # noqa: E402

PNG = base64.b64encode(b"fake-png-bytes").decode()
JPG = base64.b64encode(b"fake-jpg-bytes").decode()


def stub_describe(data, media_type="image/png", prompt=cb.VISION_PROMPT):
    return f"DESCRIBED({len(data)}b,{media_type})"


def assert_eq(actual, expected, msg):
    if actual != expected:
        raise AssertionError(f"{msg}\n  expected: {expected!r}\n  actual:   {actual!r}")


def test_openai_image_url():
    blocks = [
        {"type": "text", "text": "look at this"},
        {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{PNG}"}},
    ]
    out = cb.transform_blocks(blocks, describe=stub_describe)
    assert_eq(out[0], {"type": "text", "text": "look at this"}, "text passes through")
    assert_eq(out[1]["type"], "text", "openai image → text")
    assert "DESCRIBED" in out[1]["text"] and "image/png" in out[1]["text"], "openai described"
    assert all(b["type"] != "image_url" for b in out), "no image_url survives"


def test_anthropic_image_block():
    blocks = [
        {"type": "image",
         "source": {"type": "base64", "media_type": "image/jpeg", "data": JPG}},
    ]
    out = cb.transform_blocks(blocks, describe=stub_describe)
    assert_eq(out[0]["type"], "text", "anthropic image → text")
    assert "image/jpeg" in out[0]["text"], "media_type preserved (not hardcoded png)"


def test_tool_result_nested_image():
    blocks = [
        {"type": "tool_result", "tool_use_id": "tu_1", "content": [
            {"type": "text", "text": "screenshot:"},
            {"type": "image",
             "source": {"type": "base64", "media_type": "image/png", "data": PNG}},
        ]},
    ]
    out = cb.transform_blocks(blocks, describe=stub_describe)
    assert_eq(out[0]["type"], "tool_result", "tool_result block preserved")
    assert_eq(out[0]["tool_use_id"], "tu_1", "tool_use_id preserved")
    nested = out[0]["content"]
    assert_eq(nested[0], {"type": "text", "text": "screenshot:"}, "nested text kept")
    assert_eq(nested[1]["type"], "text", "nested image → text")
    assert not _has_image(out), "no raw image survives anywhere"


def test_describe_failure_falls_back_to_text():
    blocks = [{"type": "image",
               "source": {"type": "base64", "media_type": "image/png", "data": PNG}}]
    out = cb.transform_blocks(blocks, describe=lambda *a, **k: None)
    assert_eq(out[0], {"type": "text", "text": cb.UNPROCESSED_TEXT}, "failure → fallback text")


def _has_image(blocks):
    for b in blocks:
        if not isinstance(b, dict):
            continue
        if b.get("type") in ("image", "image_url"):
            return True
        if isinstance(b.get("content"), list) and _has_image(b["content"]):
            return True
    return False


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"ok  {t.__name__}")
    print(f"\n{len(tests)} passed")
