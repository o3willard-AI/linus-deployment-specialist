# Context & Memory Protocol

## Managing AI Context Across Multi-Day Projects

**Version:** 1.0  
**Purpose:** Strict guidelines for maintaining project state and context coherence across sessions

---

## 1. The Context Problem

AI agents have limited context windows. Over a multi-day project:

- **Session Resets**: Each new conversation starts fresh
- **Context Overflow**: Long conversations degrade quality
- **Drift**: Agents may interpret instructions differently over time
- **State Loss**: Work-in-progress can be forgotten

This protocol prevents these issues.

---

## 2. Context Architecture

### 2.1 Three-Layer Context Model

```
┌─────────────────────────────────────────────────────────┐
│  LAYER 1: PERSISTENT (Files on Disk)                    │
│  - Never changes during execution                       │
│  - Source of truth                                      │
│  - Read at start of every session                       │
├─────────────────────────────────────────────────────────┤
│  LAYER 2: SESSION STATE (state.json)                    │
│  - Updated after each micro-milestone                   │
│  - Tracks progress, decisions, blockers                 │
│  - Read/written by agents                               │
├─────────────────────────────────────────────────────────┤
│  LAYER 3: WORKING MEMORY (In-Context)                   │
│  - Current task details                                 │
│  - Temporary calculations                               │
│  - Flushed at session end                               │
└─────────────────────────────────────────────────────────┘
```

### 2.2 File Locations

```
linus-deployment-specialist/
├── .context/                      # Context management directory
│   ├── state.json                # Current project state
│   ├── decisions.log             # All human decisions
│   ├── blockers.log              # Current blocking issues
│   └── session-summaries/        # End-of-session summaries
│       ├── 2025-12-26-session-01.md
│       ├── 2025-12-26-session-02.md
│       └── ...
├── 01-MASTER-PRD.md              # Layer 1: Persistent
├── 02-AGENTIC-CODEX.md           # Layer 1: Persistent
├── 03-CONTEXT-PROTOCOL.md        # Layer 1: Persistent (this file)
└── 04-MICRO-PHASE-ROADMAP.md     # Layer 1: Persistent
```

---

## 3. Session Lifecycle

### 3.1 Session Start Protocol

**EVERY new session MUST begin with these steps:**

```
STEP 1: Load Project Identity
  → Read: 01-MASTER-PRD.md (first 100 lines minimum)
  → Confirm: Project name, goals, current phase

STEP 2: Load Agent Instructions
  → Read: 02-AGENTIC-CODEX.md (relevant sections)
  → Confirm: Script standards, verification patterns

STEP 3: Load Current State
  → Read: .context/state.json
  → Confirm: Current phase, current step, any blockers

STEP 4: Load Recent History
  → Read: Latest file in .context/session-summaries/
  → Confirm: What was accomplished, what's next

STEP 5: Announce Readiness
  → Output: "Ready to continue from Phase X, Step Y: <description>"
```

### 3.2 Session Start Template (For Human to Paste)

```markdown
## Session Resumption

Please load your context for the Linus Deployment Specialist project:

1. Read `.context/state.json` to understand current progress
2. Read the latest session summary in `.context/session-summaries/`
3. Confirm what phase/step you're on
4. Continue from where we left off

If any of these files don't exist, start from Phase 1, Step 1.
```

### 3.3 Mid-Session Checkpoints

**Every 30 minutes OR after completing a micro-milestone:**

```
CHECKPOINT:
1. Update .context/state.json with progress
2. If context feels heavy, consider summarizing and continuing
3. Verify you're still on track with the roadmap
```

### 3.4 Session End Protocol

**EVERY session MUST end with:**

```
STEP 1: Update State File
  → Write current phase, step, status to .context/state.json

STEP 2: Create Session Summary
  → Create new file: .context/session-summaries/YYYY-MM-DD-session-NN.md
  → Include: What was done, what's next, any blockers, decisions made

STEP 3: Announce Completion
  → Output: Summary of session accomplishments
  → Output: Clear next steps for next session
```

---

## 4. State File Specification

### 4.1 state.json Schema

```json
{
  "project": "linus-deployment-specialist",
  "version": "1.0",
  "last_updated": "2025-12-26T14:30:00Z",
  "last_agent": "claude|gemini",
  
  "progress": {
    "current_phase": 1,
    "current_step": 3,
    "phase_status": "in_progress|complete|blocked",
    "step_status": "not_started|in_progress|verifying|complete|failed"
  },
  
  "completed_milestones": [
    {
      "phase": 1,
      "step": 1,
      "description": "MCP SSH server installed",
      "completed_at": "2025-12-26T10:00:00Z",
      "verification": "npm list -g shows @essential-mcp/server-enhanced-ssh"
    },
    {
      "phase": 1,
      "step": 2,
      "description": "SSH host keys generated",
      "completed_at": "2025-12-26T10:15:00Z",
      "verification": "File exists: ~/.mcp/ssh/config/ssh_host_rsa_key"
    }
  ],
  
  "blockers": [
    {
      "id": "BLOCK-001",
      "created": "2025-12-26T11:00:00Z",
      "description": "Need Proxmox API credentials",
      "type": "human_decision",
      "status": "open|resolved",
      "resolved_at": null,
      "resolution": null
    }
  ],
  
  "decisions": [
    {
      "id": "DEC-001",
      "timestamp": "2025-12-26T09:00:00Z",
      "question": "Which packaging approach?",
      "decision": "Option C - Hybrid",
      "rationale": "Supports both Claude and Gemini"
    }
  ],
  
  "environment": {
    "mcp_server_version": "1.0.0",
    "node_version": "22.x",
    "target_providers": ["proxmox", "qemu"],
    "credentials_configured": {
      "proxmox": false,
      "aws": false,
      "qemu": true
    }
  }
}
```

### 4.2 State Update Rules

| Event | Action |
|-------|--------|
| Micro-milestone complete | Add to `completed_milestones`, update `progress` |
| New blocker identified | Add to `blockers` with status "open" |
| Blocker resolved | Update blocker status to "resolved", add resolution |
| Human decision made | Add to `decisions` |
| Session end | Update `last_updated` and `last_agent` |

---

## 5. Session Summary Format

### 5.1 Summary Template

```markdown
# Session Summary

**Date:** YYYY-MM-DD  
**Session Number:** NN  
**Agent:** Claude / Gemini  
**Duration:** ~X hours  

## Starting State
- Phase: X
- Step: Y
- Previous blockers: [list or "none"]

## Accomplishments

### Completed Micro-Milestones
1. [Phase.Step] Description - ✅ Verified
2. [Phase.Step] Description - ✅ Verified

### Partial Progress
- [Phase.Step] Description - 70% complete, next: <specific task>

## Blockers Encountered

### New Blockers
- BLOCK-XXX: Description (type: human_decision|technical|external)

### Resolved Blockers
- BLOCK-YYY: Resolution description

## Decisions Made

### By Agent
- None requiring human review

### Requiring Human Input
- DECISION-XXX: [Question] - Options: A, B, C

## Files Created/Modified
- `path/to/file.sh` - Created: description
- `path/to/existing.sh` - Modified: what changed

## Next Steps
1. Specific next task
2. Following task after that
3. ...

## Context Health
- Token usage: LOW / MEDIUM / HIGH
- Recommendation: CONTINUE / SUMMARIZE_AND_FLUSH / END_SESSION

## Notes
Any additional context for the next session.
```

---

## 6. Context Flush Protocol

### 6.1 When to Flush

Flush context (end session) when:

1. **Token Count High**: Responses slow down or truncate
2. **Phase Complete**: Natural breakpoint
3. **Major Blocker**: Need human input to continue
4. **Time-Based**: After ~2 hours of continuous work
5. **Confusion Signals**: Agent starts misremembering or contradicting itself

### 6.2 Flush Procedure

```
1. STOP current task at a clean checkpoint
2. Complete Session End Protocol (Section 3.4)
3. Ensure state.json accurately reflects progress
4. Write comprehensive session summary
5. Signal human: "Context flush recommended. State saved."
6. END SESSION

--- NEW SESSION ---

1. Human starts new conversation
2. Human pastes Session Start Template (Section 3.2)
3. Agent executes Session Start Protocol (Section 3.1)
4. Work continues from saved state
```

---

## 7. Cross-Agent Handoff

### 7.1 Claude → Gemini Handoff

When Claude completes work and Gemini should continue:

```
CLAUDE:
1. Complete Session End Protocol
2. In summary, add: "HANDOFF TO GEMINI RECOMMENDED"
3. Ensure all Claude-specific state is generic

GEMINI:
1. Read state.json (agent-agnostic)
2. Read latest session summary
3. Initialize Conductor context if needed
4. Continue from documented state
```

### 7.2 Gemini → Claude Handoff

When Gemini completes work and Claude should continue:

```
GEMINI:
1. Ensure conductor/tracks/ state is reflected in .context/state.json
2. Complete Session End Protocol
3. In summary, add: "HANDOFF TO CLAUDE RECOMMENDED"

CLAUDE:
1. Read state.json
2. Read latest session summary
3. If Skill not loaded, reference skill/SKILL.md
4. Continue from documented state
```

---

## 8. Recovery Procedures

### 8.1 State File Corrupted/Missing

```
1. Check .context/session-summaries/ for latest summary
2. Reconstruct state.json from summary
3. Verify against actual file system state
4. If summaries also missing, start from Phase 1 Step 1
5. Notify human of data loss
```

### 8.2 Agent Confusion/Drift

Signs of drift:
- Agent references non-existent files
- Agent contradicts documented decisions
- Agent skips verification steps

Recovery:
```
1. STOP immediately
2. Read state.json fresh
3. Read relevant MASTER documents
4. Compare agent's understanding vs. documentation
5. Correct course explicitly
6. If confusion persists, FLUSH context
```

### 8.3 Verification Failure

When a completed milestone fails re-verification:

```
1. Log the failure in state.json (mark milestone as needs_recheck)
2. Investigate root cause
3. If environment changed: re-execute milestone
4. If script bug: fix script, re-execute, re-verify
5. Document what went wrong in session summary
```

---

## 9. Human Observer Checkpoints

### 9.1 Required Human Reviews

| Checkpoint | When | Human Action |
|------------|------|--------------|
| Phase Start | Beginning of each phase | Approve phase initiation |
| Blocker Resolution | When blocker requires decision | Provide decision |
| Phase Complete | End of each phase | Review deliverables, approve |
| Context Flush | When agent recommends | Start new session |
| Final Review | Project completion | Full acceptance testing |

### 9.2 Human Command Reference

Humans can issue these commands to agents:

```
CONTINUE - Proceed with next step
PAUSE - Stop after current step, don't start new ones
STATUS - Report current state
RETRY [step] - Re-execute a specific step
SKIP [step] - Mark step as skipped, move to next
DECIDE [decision] - Record a human decision
FLUSH - End session, save state
ABORT - Stop all work, preserve state for later
```

---

## 10. Metrics and Health Monitoring

### 10.1 Session Health Indicators

Track in each session summary:

| Metric | Healthy | Warning | Critical |
|--------|---------|---------|----------|
| Steps completed per hour | 3+ | 1-2 | <1 |
| Verification failures | 0 | 1-2 | 3+ |
| Retries required | 0 | 1-2 | 3+ |
| Blockers created | 0-1 | 2-3 | 4+ |
| Context clarity | Clear | Some confusion | Major drift |

### 10.2 Project Health Dashboard

Update in state.json:

```json
"health": {
  "total_milestones": 42,
  "completed_milestones": 12,
  "completion_percentage": 28.5,
  "blockers_open": 1,
  "blockers_resolved": 3,
  "sessions_count": 4,
  "estimated_sessions_remaining": 10
}
```

---

## Appendix: Quick Reference Card

### Session Start (Copy-Paste)
```
Load context for Linus Deployment Specialist:
1. Read .context/state.json
2. Read latest .context/session-summaries/*.md
3. Confirm current phase/step
4. Continue execution
```

### Session End (Copy-Paste)
```
End session for Linus Deployment Specialist:
1. Update .context/state.json
2. Create session summary
3. Announce next steps
```

### State File Path
```
.context/state.json
```

### Session Summary Path
```
.context/session-summaries/YYYY-MM-DD-session-NN.md
```
