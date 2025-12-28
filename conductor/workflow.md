# Linus Deployment Specialist - Workflow

## Development Process

### 1. Context First
Always read `product.md` and `tech-stack.md` before starting any work. These files define WHAT we're building and HOW.

### 2. Plan Before Code
For any new feature or track:
1. Create `spec.md` defining requirements
2. Create `plan.md` with step-by-step tasks
3. Review plan before implementation
4. Execute plan systematically

### 3. Verify Each Step
Every command must have explicit verification:
- Check exit codes
- Validate expected output
- Confirm state changes
- Never proceed on assumption

### 4. Test Both Agents
All scripts must work identically for:
- Claude (via Skills)
- Gemini (via Conductor)

Scripts are the source of truth, not agent-specific logic.

## Commit Strategy

### Format
```
[Phase.Step] Short description

Optional longer description if needed.
```

### Examples
```
[0.1] Create project directory structure
[1.3] Add Proxmox provisioning script
[2.5] Fix SSH timeout in bootstrap
[3.1] Create Claude SKILL.md
```

### Rules
- One logical change per commit
- Commit after each passing verification
- Never commit broken code
- Always include phase/step reference

## Branching (Optional)

For this project, working on `main` is acceptable since:
- Single-developer workflow
- AI agents executing sequentially
- State tracked in `.context/state.json`

If collaboration needed:
```
main           - Stable, verified code
feature/xxx    - Work in progress
```

## Testing Strategy

### Level 1: Syntax Check
```bash
bash -n script.sh
```
Run immediately after writing any script.

### Level 2: Smoke Test
```bash
./script.sh --help  # Or dry-run mode
```
Verify script loads and shows usage.

### Level 3: Integration Test
Actually execute against a test target:
- Use a dedicated test VM/instance
- Verify expected outcomes
- Clean up after

### Level 4: E2E Test
Full workflow from provision to verified access:
```
Request → Provision → Bootstrap → SSH Success
```

## Code Review (Self)

Before marking any step complete, verify:

- [ ] **Template Compliance**: Follows script template from Agentic Codex
- [ ] **Idempotency**: Safe to run multiple times
- [ ] **Logging**: Appropriate log statements (not excessive)
- [ ] **Error Handling**: Fails gracefully with useful messages
- [ ] **Exit Codes**: Returns correct codes per convention
- [ ] **Verification**: Has explicit success check
- [ ] **Documentation**: Header comments are complete

## Handoff Points

Signal to human observer at:

### Phase Boundaries
"Phase X complete. Ready to proceed to Phase Y. Any concerns?"

### Blocking Decisions
"Blocked on: [issue]. Need decision on: [options]"

### Unrecoverable Errors
"Error encountered: [details]. Unable to proceed automatically."

### Session End
"Session ending. Progress saved to state.json. Next: [step]"

## State Management

### Update State After Each Milestone
```json
{
  "progress": {
    "current_phase": X,
    "current_step": Y,
    "step_status": "complete"
  },
  "completed_milestones": [
    { "phase": X, "step": Y, "description": "..." }
  ]
}
```

### Create Session Summary at End
File: `.context/session-summaries/YYYY-MM-DD-session-NN.md`

Include:
- What was accomplished
- What's next
- Any blockers
- Any decisions made

## Error Recovery

### Script Fails Verification
1. Check the actual error message
2. Identify root cause
3. Fix the issue
4. Re-run verification
5. If still failing after 2 attempts, escalate

### State Inconsistency
1. Read state.json
2. Compare to actual file system
3. Trust file system state over state.json
4. Update state.json to match reality

### Context Confusion
1. Stop current work
2. Re-read foundation documents
3. Re-read state.json
4. If still confused, end session and restart fresh

## Quality Standards

### Scripts Must
- Start with standard header
- Use `set -euo pipefail`
- Source shared libraries
- Validate inputs before acting
- Log key operations
- Return structured output
- Exit with correct codes

### Scripts Must Not
- Use hardcoded values
- Suppress errors silently
- Assume clean state
- Retry indefinitely
- Leave temp files behind

## Time Estimates

Use these as guidelines:

| Task Type | Estimate |
|-----------|----------|
| Simple script | 15-30 min |
| Complex script | 30-60 min |
| Integration testing | 15-30 min |
| Documentation | 15-30 min |
| Debugging | Variable |

If a task takes 2x the estimate, stop and reassess approach.

## Conductor Commands Reference

```bash
# Start new feature
/conductor:newTrack "Description of feature"

# Execute plan
/conductor:implement

# Check progress
/conductor:status

# Revert changes
/conductor:revert

# View current track
cat conductor/tracks/current/plan.md
```
