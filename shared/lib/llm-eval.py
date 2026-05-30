#!/usr/bin/env python3
"""
Non-deterministic LLM evaluator for the Vast GPU provisioning pipeline.

Provides small-model decision points for the 4 touch points:
  1. Offer selection    — picks best offer from top 5 candidates
  2. Build watch        — decides WAIT vs ABORT during build
  3. Quality judge      — semantic output quality assessment
  4. Run strategist     — meta-decision on retry strategy

Usage:
  python3 llm-eval.py <mode> < input.txt

Modes:
  offer-select   — reads JSON offers, outputs selected index
  build-watch    — reads build status, outputs WAIT or ABORT:<reason>
  quality-judge  — reads model output, outputs PASS or FAIL:<reason>
  run-strategist — reads run summary, outputs RETRY:<action> or ABORT

Endpoint discovery (checked in order):
  1. LLM_EVAL_ENDPOINT env var        — explicit URL
  2. http://192.168.101.42:4000/v1    — Clubhouse LiteLLM
  3. http://localhost:1234/v1          — local LM Studio
  4. --deterministic flag / fallback  — rule-based decisions
"""

import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path

ENDPOINT = os.environ.get("LLM_EVAL_ENDPOINT", "")
MODEL = os.environ.get("LLM_EVAL_MODEL", "qwen2.5-coder-3b")
API_KEY = os.environ.get("LLM_EVAL_API_KEY", "not-needed")
DETERMINISTIC = os.environ.get("LLM_EVAL_DETERMINISTIC", "") == "1"

# Fallback endpoints if none explicitly set
FALLBACK_ENDPOINTS = [
    "http://192.168.101.42:4000/v1",
    "http://localhost:1234/v1",
]

SYSTEM_PROMPTS = {
    "offer-select": (
        "You are a GPU provisioning evaluator. Given a list of offers with "
        "metadata, select the ONE offer most likely to provision successfully. "
        "Consider: reliability score, disk space vs model size, geographic "
        "location history (some regions have higher SSH proxy failure rates), "
        "and price/reliability trade-off. Output ONLY the offer number (1-5) "
        "with no other text."
    ),
    "build-watch": (
        "You are a build progress evaluator. Given the current build status, "
        "decide whether to keep waiting or abort. Look for: fatal errors "
        "(cmake failure, missing CUDA, compiler crash) vs normal progress "
        "(slow compile, nvcc warnings, high percentage). Output ONLY: "
        "WAIT or ABORT:<reason> with no other text."
    ),
    "quality-judge": (
        "You are a model output quality evaluator. Assess the given text for: "
        "degenerate repetition (same pattern repeated many times), semantic "
        "coherence (does it make sense as a response?), and structural validity. "
        "Output ONLY: PASS or FAIL:<reason> (e.g., FAIL:degeneration, "
        "FAIL:incoherent, FAIL:empty) with no other text."
    ),
    "run-strategist": (
        "You are a GPU provisioning strategist. Given a summary of failed "
        "provisioning attempts, decide the next strategy. Consider: failure "
        "patterns across attempts (same host? same region? same error?), GPU "
        "market alternatives (different GPU tiers, regions), and cost of "
        "continued retries vs switching approach. Output ONLY: "
        "RETRY:same, RETRY:switch_gpu, RETRY:increase_disk, RETRY:different_region, "
        "or ABORT:no_viable_path with no other text."
    ),
}


def discover_endpoint() -> str:
    """Find a working LLM endpoint."""
    if ENDPOINT:
        return ENDPOINT

    for url in FALLBACK_ENDPOINTS:
        try:
            req = urllib.request.Request(
                f"{url}/models",
                headers={"Authorization": f"Bearer {API_KEY}"},
            )
            urllib.request.urlopen(req, timeout=5)
            return url
        except Exception:
            continue

    return ""


def llm_call(endpoint: str, system: str, user: str) -> str:
    """Call the LLM and return the response text."""
    payload = json.dumps({
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": 20,
        "temperature": 0.0,
        "stop": ["\n"],
    }).encode()

    url = f"{endpoint}/chat/completions"
    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
        },
    )

    try:
        resp = urllib.request.urlopen(req, timeout=30)
        data = json.loads(resp.read())
        return data["choices"][0]["message"]["content"].strip()
    except Exception as e:
        print(f"LLM call failed: {e}", file=sys.stderr)
        raise


# ─── Deterministic fallback evaluators ────────────────────────────

def deterministic_offer_select(offers_text: str) -> str:
    """Pick the best offer using heuristics alone."""
    lines = [l.strip() for l in offers_text.strip().split("\n") if l.strip()]
    best_idx = 1
    best_score = -1

    for i, line in enumerate(lines, 1):
        score = 0
        if "99.9%" in line:
            score += 100
        elif "99.8%" in line:
            score += 80
        elif "99.7%" in line:
            score += 60
        elif "99.5%" in line:
            score += 40
        if "GB disk" in line:
            try:
                disk = int(line.split("GB disk")[0].split()[-1])
                if disk >= 50:
                    score += 30
            except ValueError:
                pass
        if score > best_score:
            best_score = score
            best_idx = i

    return str(best_idx)


def deterministic_build_watch(status_text: str) -> str:
    """Decide WAIT vs ABORT using heuristics."""
    status_lower = status_text.lower()

    fatal_markers = [
        "cmake error", "cuda compiler not found", "fatal error",
        "no such file", "cannot find", "build failed", "compilation terminated",
        "error: cuda", "nvcc fatal", "unsupported gpu architecture",
    ]
    for marker in fatal_markers:
        if marker in status_lower:
            return f"ABORT:{marker.replace(' ', '_')}"

    if "build_done" in status_lower:
        return "WAIT"

    if "building" in status_lower or "compiling" in status_lower:
        return "WAIT"

    if "idle" in status_lower and "build_done" not in status_lower:
        return "ABORT:build_stalled"

    return "WAIT"


def deterministic_quality_judge(output_text: str) -> str:
    """Assess output quality using heuristics."""
    if not output_text or not output_text.strip():
        return "FAIL:empty"

    # 5-gram repetition check
    words = output_text.split()
    if len(words) >= 5:
        from collections import Counter
        grams = [" ".join(words[i:i+5]) for i in range(len(words)-4)]
        repeats = Counter(grams)
        top_count = repeats.most_common(1)[0][1] if repeats else 0
        if top_count > 10:
            return "FAIL:degeneration"

    # Char-level checks
    total = len(output_text)
    slash_count = output_text.count("/")
    if total > 0 and slash_count * 100 / total > 50:
        return "FAIL:slash_garbage"

    return "PASS"


def deterministic_run_strategist(summary_text: str) -> str:
    """Decide retry strategy using heuristics."""
    summary_lower = summary_text.lower()

    if "disk full" in summary_lower or "insufficient disk" in summary_lower:
        return "RETRY:increase_disk"
    if "ssh proxy dead" in summary_lower or "unreachable" in summary_lower:
        if "rtx 3090" in summary_lower and "switch" not in summary_lower:
            return "RETRY:switch_gpu"
    if summary_text.count("attempt") >= 3:
        return "RETRY:switch_gpu"
    if "iceland" in summary_lower:
        return "RETRY:different_region"

    return "RETRY:same"


# ─── Main ─────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Usage: llm-eval.py <mode>", file=sys.stderr)
        print("Modes: offer-select, build-watch, quality-judge, run-strategist",
              file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]
    if mode not in SYSTEM_PROMPTS:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)

    user_input = sys.stdin.read()

    if DETERMINISTIC:
        deterministic_funcs = {
            "offer-select": deterministic_offer_select,
            "build-watch": deterministic_build_watch,
            "quality-judge": deterministic_quality_judge,
            "run-strategist": deterministic_run_strategist,
        }
        result = deterministic_funcs[mode](user_input)
        print(result)
        return

    endpoint = discover_endpoint()
    if not endpoint:
        # Fall back to deterministic
        print(f"[llm-eval] No LLM endpoint available — using deterministic fallback",
              file=sys.stderr)
        deterministic_funcs = {
            "offer-select": deterministic_offer_select,
            "build-watch": deterministic_build_watch,
            "quality-judge": deterministic_quality_judge,
            "run-strategist": deterministic_run_strategist,
        }
        result = deterministic_funcs[mode](user_input)
        print(result)
        return

    try:
        result = llm_call(endpoint, SYSTEM_PROMPTS[mode], user_input)
        print(result)
    except Exception as e:
        print(f"[llm-eval] LLM call failed ({e}) — using deterministic fallback",
              file=sys.stderr)
        deterministic_funcs = {
            "offer-select": deterministic_offer_select,
            "build-watch": deterministic_build_watch,
            "quality-judge": deterministic_quality_judge,
            "run-strategist": deterministic_run_strategist,
        }
        result = deterministic_funcs[mode](user_input)
        print(result)


if __name__ == "__main__":
    main()
