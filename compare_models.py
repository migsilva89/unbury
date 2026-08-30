#!/usr/bin/env python3
"""Describe the same handful of pages with several models and compare them.

Every link in Unbury is stored as one sentence written by a model, and the vector
a search is ranked against is built from that sentence. So a cheaper model is only
worth taking if its descriptions still say what the page actually is. This script
puts the candidates side by side on real pages, printing what each one wrote and
what it cost per link.

It is how the current model was chosen — read the "The models, and the money"
section of CLAUDE.md for what the numbers came out as.

    export OPENROUTER_API_KEY=sk-or-...
    python compare_models.py https://example.com https://another.example
    python compare_models.py --models moonshotai/kimi-k2,anthropic/claude-sonnet-5 <url>

Needs nothing but Python 3.11 and a key. It talks to OpenRouter and to the pages
themselves, and writes nothing anywhere.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

CANDIDATES = [
    "google/gemini-2.5-flash-lite",
    "google/gemini-3.7-flash",
    "moonshotai/kimi-k2",
    "anthropic/claude-sonnet-5",
]

# Enough pages to see a difference in voice without spending real money.
SAMPLE = [
    "https://www.printables.com/model/1084862-betafpv-pavo-pico-landing-gear",
    "https://github.com/ggerganov/llama.cpp",
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
]

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Unbury/compare-models"
API = "https://openrouter.ai/api/v1"

# The prompt the app itself uses. Comparing models on a different prompt to the
# one they will actually be given answers a question nobody asked.
DESCRIBE_PROMPT = """Write a short record for this bookmark, in ENGLISH.

Reply with JSON only:
{"summary": "1-2 sentences: what this page is and what it is for, concrete and specific", "tags": ["3 to 5 lowercase english tags, hyphenated, no accents"]}

Rules:
- Judge the page by its CONTENT, not by the folder. The folder is a weak hint and is
  often wrong or stale — ignore it when the content says otherwise.
- Tags name the subject, the kind of thing, and the use ("fpv", "3d-printing",
  "open-source", "reference", "shop"). Never invent a tag the page does not support.
- If the content is empty, work from the title and the domain and say what the site is.
- No marketing language. Say what it does, not how great it is.

TITLE: %s
URL: %s
FOLDER (unreliable hint): %s
CONTENT: %s"""


def key() -> str:
    found = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not found:
        sys.exit("Set OPENROUTER_API_KEY first — see https://openrouter.ai/keys")
    return found


def post(path: str, payload: dict) -> dict:
    request = urllib.request.Request(
        API + path,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {key()}",
                 "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


def price(model: str) -> tuple[float, float]:
    """What a million tokens cost, in and out."""
    data = json.load(urllib.request.urlopen(API + "/models", timeout=60))
    for entry in data["data"]:
        if entry["id"] == model:
            pricing = entry["pricing"]
            return (float(pricing["prompt"]) * 1e6,
                    float(pricing.get("completion", 0)) * 1e6)
    return 0.0, 0.0


def fetch(url: str, timeout: int = 20) -> tuple[str, str, str]:
    """Return (title, text, status). Status is 'ok' or the reason it failed."""
    try:
        request = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(request, timeout=timeout) as response:
            html = response.read(400_000).decode("utf-8", "ignore")
    except Exception as error:
        return "", "", type(error).__name__

    found = re.search(r"<title[^>]*>(.*?)</title>", html, re.I | re.S)
    title = re.sub(r"\s+", " ", found.group(1)).strip() if found else ""
    # Body text, roughly: enough for the model to judge the page by, without
    # pulling in a parser this script would otherwise not need.
    stripped = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", html, flags=re.I | re.S)
    text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", stripped)).strip()
    return title, text[:4000], "ok"


def describe_with(model: str, title: str, url: str, content: str) -> tuple[dict, dict]:
    answer = post("/chat/completions", {
        "model": model,
        "messages": [{"role": "user",
                      "content": DESCRIBE_PROMPT % (title, url, "", content[:3500])}],
        "max_tokens": 400,
        "usage": {"include": True},
    })
    text = answer["choices"][0]["message"].get("content") or ""
    match = re.search(r"\{.*\}", text, re.S)
    # A model that answers with something other than JSON is a finding, not a
    # crash — that is exactly what this script is here to notice.
    written = json.loads(match.group(0)) if match else {"summary": text[:200], "tags": []}
    return written, answer.get("usage", {})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("urls", nargs="*", default=[],
                        help="pages to describe; a small default sample if none given")
    parser.add_argument("--models", default=",".join(CANDIDATES))
    parser.add_argument("--library", type=int, default=623, metavar="N",
                        help="how many links to project the per-link cost onto")
    args = parser.parse_args()

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    urls = args.urls or SAMPLE

    pages = []
    for url in urls:
        title, text, status = fetch(url)
        pages.append((title or url, url, text))
        print(f"read  {url[:58]:<60} {status}")
    print()

    for model in models:
        pin, pout = price(model)
        spent, elapsed, failed = 0.0, 0.0, 0
        print("=" * 78)
        print(f"{model}   (in ${pin:.3f}/M · out ${pout:.2f}/M)")
        print("=" * 78)
        for title, url, text in pages:
            started = time.time()
            try:
                written, usage = describe_with(model, title, url, text)
            except Exception as error:
                failed += 1
                print(f"  {url[:22]:<22} FAILED: {str(error)[:90]}")
                continue
            elapsed += time.time() - started
            spent += usage.get("cost") or (
                usage.get("prompt_tokens", 0) * pin
                + usage.get("completion_tokens", 0) * pout) / 1e6
            print(f"  {url[:22]:<22} {written.get('summary', '')[:104]}")
            print(f"  {'':<22} tags: {', '.join(written.get('tags', []))}")
        done = len(pages) - failed
        if done:
            each = spent / done
            print(f"\n  → ${each:.5f} per link · {elapsed/done:.1f}s each · "
                  f"{args.library} links would cost ${each * args.library:.2f}\n")


if __name__ == "__main__":
    main()
