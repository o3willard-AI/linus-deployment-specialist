# Story P4-1: Vast Provider — validate_environment()

**Priority:** P0 (entry point for vast.sh)
**Estimate:** 0.5 day
**Phase:** Phase 4 — Vast Core Provider
**Depends on:** P1-1, P2-1, P3-1

## User Story

As the Vast provisioner script, I need `validate_environment()` to verify the Vast CLI is installed/authenticated, the SSH key is registered (and NOT stored as a file path), and required env vars are set — with credential auto-discovery from KeePass.

## Acceptance Criteria

### AC1: CLI verification
- [ ] Checks `vastai` is on PATH; if not, auto-installs via `pip install --user vastai`
- [ ] Verifies API key is set: `vastai set api-key` was called (probes with `vastai show instances` or similar read-only command)
- [ ] Exits with clear error if API key missing

### AC2: SSH key validation (pitfall guard)
- [ ] Runs `vastai show ssh-keys`
- [ ] Verifies at least one key entry starts with `ssh-ed25519` or `ssh-rsa` (NOT a file path like `/home/...`)
- [ ] If key shows as a file path, logs error: "SSH key stored as path, not content. Re-register with: vastai create ssh-key \"\$(cat ~/.ssh/key.pub)\""
- [ ] Exits with error if no valid keys found

### AC3: Credential auto-discovery
- [ ] Scans `~/.hermes/secrets/` for `vast-api-key`, `vast-token`, etc.
- [ ] Falls back to KeePass: extracts `General/Vast API Key` entry
- [ ] Sets `VAST_API_KEY` env var if not already set

### AC4: Integration
- [ ] Function is defined in `shared/provision/vast.sh`
- [ ] Follows same pattern as proxmox.sh `validate_environment()`: numbered log_step, checks in order
- [ ] Returns 0 on success, non-zero exit code on failure (matching proxmox.sh exit code conventions: 2=missing deps, 3=invalid config)

## Technical Notes

Follow the proxmox.sh pattern exactly:
```bash
validate_environment() {
    log_step "1" "Validating environment"
    # Check 1: CLI
    # Check 2: API key
    # Check 3: SSH keys
    # ...
    log_success "Environment validation passed"
    return 0
}
```

Sources: `paths.sh`, `logging.sh`, `validation.sh` (already sourced by vast.sh skeleton)

## Definition of Done
- [ ] All 4 AC sections passing
- [ ] `bash -n shared/provision/vast.sh` clean
- [ ] Tested with: `VAST_API_KEY=fake source shared/provision/vast.sh && validate_environment` exits with clear error
- [ ] Committed
