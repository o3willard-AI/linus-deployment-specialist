# E2E Test Log — 2026-05-30 Driver Script Debugging

**Branch:** `feat/vast-sizing-library`
**Model:** Qwen3-Coder-30B-A3B-Instruct-Q4_K_M (17.28 GB)
**GPU:** RTX 3090
**Challenge:** Kiosk Admin Panel (14 files, 9,411 char spec)

## Run Summary

| Run | Exit | Phase Failed | Bug | Fix Commit |
|-----|------|-------------|-----|------------|
| #1  | 4    | Driver      | parse_linus_result matched bare CONTRACT_ID vs LINUS_CONTRACT_ID | fc27db1 |
| #2  | 5    | Bootstrap   | (a) SSH proxy dropped connection during download (b) awk $4 expanded by eval under set -u | 76f9a9c |
| #3  | 5    | Bootstrap   | Disk calc assumed 7B params → 10.5GB filter for a 30B/18.5GB model | 55d27ad |
| #4  | 1    | Summary     | f-string ${} syntax in print_summary expanded by bash | 3081dbc |
| #5  | 0    | —           | 14/14 files, 100s, $0.096 total. TP3 PASS on boilerplate false positive | — |

## Run #5 — SUCCESS

```
Contract:    38529479
Host:        ssh3.vast.ai:19479
Wall time:   547s (9.1 min) provision+bootstrap
            100s (kiosk challenge)
Cost:        $0.0813 (bootstrap) + $0.015 (challenge) ≈ $0.096 total

Pipeline trace:
  TP1 (offer-select):           deterministic — scored offers, picked 99.9% + 46GB disk
  Provision:                    30s
  Build wait (510s):            no fatal patterns detected
  P0.1 (Content-Range):         17.28 GB ✅
  Disk check:                   45GB free, 21GB needed ✅
  Download (197s):              SSH keepalive held connection ✅
  Server start + health:        7s ✅
  TP3 (quality judge):          PASS — deterministic gates + LLM eval confirmed
  P1.4 (cost):                  $0.0813 (547s @ $0.535/hr) ✅

Kiosk challenge:
  Files:        14/14 (100% spec coverage)
  Tokens:       11,352 completion / 2,282 prompt
  Wall time:    100s (70s on RTX 4090 — 30% slower, expected)
  Anti-patterns: 0
  5-gram max:   11 (false positive — boilerplate error handling in app.py routes)
  DONE token:   Not needed — model completed naturally

5-gram false positive analysis:
  Top 5-grams were: 'except Exception as e: return...' × 11
  This is consistent error handling boilerplate repeated across routes.
  The deterministic 5-gram gate flagged it (threshold 10), but the
  char-level gates passed and TP3 confirmed PASS. This is exactly the
  borderline case the LLM quality judge is designed for.
```

## Key Metrics Across All Runs

| Phase | Best | Worst | Avg | Notes |
|-------|------|-------|-----|-------|
| Provision | 30s | 30s | 30s | Consistently fast |
| Build | 390s | 510s | 450s | Host-dependent (vCPUs) |
| Download | 197s | — | 197s | Only completed once, SSH keepalive critical |
| Server start | 7s | 7s | 7s | Consistently fast |
| Quality gates | 2s | 2s | 2s | Deterministic + LLM eval |
| Kiosk challenge | 100s | — | 100s | 3090 vs 4090 (70s) — 30% slower, expected |

## Commits

```
3081dbc fix: double LINUS_ prefix on COST + f-string escaping in summary
55d27ad fix: pass VAST_MODEL_PARAMS_B to provision script for disk sizing
76f9a9c fix: SSH keepalive + disk space awk escape + parser fix
fc27db1 fix: driver script path resolution and LINUS_RESULT parser
cbdf61c feat: 4 non-deterministic LLM touch points + 8 mustfix hardening fixes
```
