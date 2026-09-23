# Must-Fix Backlog — Vast GPU Provisioning Pipeline

**Created:** 2026-05-30
**Branch:** `feat/vast-sizing-library` (o3willard-AI/linus-deployment-specialist)
**Status:** All open — prioritized by blast radius

---

## P0 — Broken (pipeline fails or silently degrades)

### 1. Range-request size parsing broken
- **File:** `shared/bootstrap/vast-gpu.sh:291`
- **Symptom:** Every run shows `"Model size:  GB ( bytes)"` and `"Could not determine model size — skipping disk space check"`
- **Root cause:** `grep -oP '/\K[0-9]+'` regex doesn't match HuggingFace's `Content-Range` header format (which is `bytes 0-0/TOTAL`, not `/TOTAL`). The `Content-Range` header format is `bytes 0-0/SIZE` where slash is part of `bytes 0-0`, not a prefix separator.
- **Impact:** We never validate disk space before downloading 18GB+ models. On hosts with tight disk, the download fails mid-way after burning time and bandwidth.
- **Fix:** Use proper Content-Range parsing (extract after `bytes 0-0/` not `/` alone). Or switch to `Content-Length` from a HEAD request.

### 2. Semantic quality gate not in bootstrap
- **File:** `shared/bootstrap/vast-gpu.sh:452-479` (verify_inference) and `tests/send-kiosk-challenge.sh`
- **Symptom:** The 3090 CSS degeneration (`.card-row .card-row .card-row` repeating 92% of output) passes the bootstrap's char-level quality gates but is caught by the test harness's 5-gram repetition detector.
- **Root cause:** verify_inference() checks slash ratio, single-char dominance, and whitespace — all character-level. The 5-gram word repetition detection (>10 repeats = degenerate) exists only in the test harness, not in the bootstrap.
- **Impact:** A model can pass bootstrap verification (exit 0) but produce garbage on the actual challenge. Bootstrap says "OK" when it shouldn't, wasting challenge time.
- **Fix:** Promote 5-gram repetition detection into verify_inference() and _try_model(). Change exit 8 threshold: >10 repeats of any 5-word sequence (same as test harness).

---

## P1 — Brittle (works but fragile, costs real money on failure)

### 3. Provision ↔ bootstrap loose coupling
- **Files:** `shared/provision/vast.sh` → manual output → `shared/bootstrap/vast-gpu.sh`
- **Symptom:** After vast.sh succeeds, user/agent must manually copy SSH_HOST, SSH_PORT, PROXY_PORT, CONTRACT_ID and export them before running vast-gpu.sh. Wrong env var order (stdbuf before VAR=val) silently fails.
- **Root cause:** Two independent scripts with no programmatic handoff. The `LINUS_RESULT:SUCCESS` output format carries the data but nothing consumes it automatically.
- **Impact:** Human error in env var passing. Also prevents snapshot caching (can't save a working bootstrap state as a Vast snapshot for reuse).
- **Fix:** A driver script (`vast-provision-and-bootstrap.sh`) that runs vast.sh, parses LINUS_RESULT output, sets env vars, and calls vast-gpu.sh. Single entry point.

### 4. No cost tracking
- **Files:** All provisioning scripts
- **Symptom:** We know the pipeline works but not what each run costs. Can't answer "is RTX 4090 worth it vs 3090 for this model?"
- **Root cause:** No cost instrumentation anywhere in the pipeline.
- **Impact:** Can't optimize GPU/model tradeoffs. Can't detect cost regression. Can't set budgets for automated provisioning.
- **Fix:** Track: instance price × runtime, model download time/cost, total run cost. Output as `LINUS_COST:total_usd=X.XX,instance_price=Y,wall_time_s=Z` in LINUS_RESULT. Include in test harness output.

### 5. Content-Range guard incomplete
- **File:** `shared/bootstrap/vast-gpu.sh:286-296`
- **Symptom:** The range-request size check exists but only covers the primary model download. The fallback chain (_try_model) has no size check — it downloads fallback models blindly into potentially full disk.
- **Root cause:** _try_model() calls retry_model_download directly without pre-flight size/disk checks.
- **Impact:** Fallback model download fails silently on disk-full, burning retry attempts.
- **Fix:** Extract size-check logic into a shared `_check_model_size_and_disk()` helper used by both download_model() and _try_model().

---

## P2 — Optimization (not broken, but sharp edges)

### 6. Build wait is blind — always 900s even when build clearly failed
- **File:** `shared/bootstrap/vast-gpu.sh:200-239`
- **Symptom:** When cmake crashes at 30s with CUDA arch mismatch, the script still waits 900s before concluding failure.
- **Root cause:** The wait loop checks `pgrep cmake|make|cc1plus|nvcc` for BUILDING vs IDLE but doesn't inspect build output for specific failure patterns until timeout.
- **Impact:** ~$0.06 wasted per failed provisioning waiting for a build that already died.
- **Fix:** After each poll interval, tail the onstart log and grep for fatal patterns (`error:`, `FAILED:`, `No such file`). If found, abort immediately instead of waiting out the full 900s.

### 7. Offer selection is greedy — always offer[0]
- **File:** `shared/provision/vast.sh:297`
- **Symptom:** Takes the first offer from dlperf_usd sort. When that offer fails, excludes it as offer:NNN and the 2nd offer might share the same host or same failure mode.
- **Root cause:** No diversity criterion in offer selection — just sort + take first.
- **Impact:** Can waste 2-3 provisioning cycles on the same class of failure (e.g., all cheap Iceland 3090s have SSH proxy issues).
- **Fix:** When retrying, prefer offers from different machine_ids and geolocations. Simple: group top 5 by machine_id, pick from a different group on retry.

### 8. SSH rate-limit recovery is fragile
- **File:** `shared/provision/vast.sh:wait_for_running`
- **Symptom:** The SSH probe works once but the handoff to bootstrap can trigger rate-limiting if the probe and retry_ssh_with_backoff fire in the same window.
- **Root cause:** The current fix (skip wait_for_ssh if ALLOCATED_SSH_HOST is set) works but there's no explicit cooldown guard.
- **Impact:** Intermittent failures that look like "SSH broken" but are actually rate-limit cooldowns.
- **Fix:** Add a 3-second sleep between the probe in wait_for_running and any subsequent SSH call in bootstrap. Document the cooldown window.
