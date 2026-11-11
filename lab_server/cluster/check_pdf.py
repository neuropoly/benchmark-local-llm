"""Check the PDF proxy end to end: send a PDF to the server as an Anthropic "document" block (what Claude
Code sends for an attached PDF, the case that fails with 400 without the proxy) and print the answer.

  ~/llm-bench/proxy-venv/bin/python check_pdf.py paper.pdf "What colors are used in Figure 1?"

Then ~/llm-bench/logs/doc-proxy.log should have a "converted PDF" line.
"""
import base64
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent


def setting(name: str, default: str) -> str:
    for line in (HERE / "vllm.env").read_text().splitlines():
        if line.startswith(name + "="):
            return line.split("=", 1)[1].split("#")[0].strip().strip('"') or default
    return default


if len(sys.argv) < 2:
    sys.exit(__doc__)
pdf = Path(sys.argv[1])
question = sys.argv[2] if len(sys.argv) > 2 else "In three sentences: what is this document about, and what does its first figure show?"
port = setting("PORT", "8000")
key = (Path.home() / "llm-bench" / "vllm.key").read_text().strip()

models = json.load(urllib.request.urlopen(urllib.request.Request(
    f"http://127.0.0.1:{port}/v1/models", headers={"Authorization": f"Bearer {key}"})))
model = models["data"][0]["id"]

body = {
    "model": model,
    "max_tokens": 12000,   # a thinking model reasons first: a small budget can end before any answer
    "messages": [{"role": "user", "content": [
        {"type": "document", "title": pdf.name,
         "source": {"type": "base64", "media_type": "application/pdf", "data": base64.b64encode(pdf.read_bytes()).decode()}},
        {"type": "text", "text": question},
    ]}],
}
req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/messages", data=json.dumps(body).encode(), method="POST",
                             headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json",
                                      "anthropic-version": "2023-06-01"})
print(f"Sending {pdf.name} ({pdf.stat().st_size // 1024} KB) to {model} on port {port} as a document block...")
try:
    answer = json.load(urllib.request.urlopen(req, timeout=600))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}: {e.read().decode()[:600]}\n(400 mentioning 'document': the proxy is not in front of vLLM)")
blocks = answer.get("content", [])
text = "\n".join(b.get("text", "") for b in blocks if b.get("type") == "text").strip()
thinking = "\n".join(b.get("thinking", "") for b in blocks if b.get("type") == "thinking").strip()
usage = answer.get("usage", {})
print(f"OK, {usage.get('input_tokens', '?')} input tokens (page images make this much larger than the text alone), "
      f"{usage.get('output_tokens', '?')} output tokens, stop: {answer.get('stop_reason')}.\n")
if text:
    print(text)
else:
    print(f"No answer text (block types: {[b.get('type') for b in blocks]}).")
    if answer.get("stop_reason") == "max_tokens":
        print("The model used all max_tokens before answering: raise max_tokens in this script.")
    if thinking:
        print(f"\nEnd of its reasoning:\n...{thinking[-1500:]}")
