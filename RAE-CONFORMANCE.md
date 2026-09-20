# RAE Conformance Statement — Linus Deployment Specialist

**Specification:** [Registered Accountable Entity (RAE)](https://github.com/o3willard-AI/RAE), v1.0.4
**Product:** Linus Deployment Specialist (this repository)
**Claim:** *displays an RAE at L0 (declared, unverified)* — **not** *implements RAE*
**Date:** 2026-09-19

Per RAE §4, an L0 display is not an implementation and "publishes no
conformance statement." This file is therefore **not** a §4 conformance
declaration — Linus makes no claim to implement the RAE practice, whose
attribution machinery (N1, N3, N4, N6a/N6b, N7, N8) begins at RAE L1. It is
published voluntarily, at the conventional location §4 names, to state exactly
what Linus does and does not assert, so no reader has to infer the boundary.

> Note on labels: unlike some sibling projects, Linus has no internal
> "L0/L1/L2" naming of its own, so every "L0" in this file unambiguously means
> **RAE assurance level L0 (declared)**. There is no model-tier or
> hardware-tier ladder here to confuse it with.

## The claim, precisely

Linus displays an RAE at L0 (declared, unverified):

- **What exists:** the human operator who deploys and runs Linus is the
  accountable human. Every provision and destroy action is recorded against the
  operator of record (`LINUS_OPERATOR_ID` / `LINUS_OPERATOR_NAME`, defaulting
  to the invoking `$USER`), carried through the structured output
  (`LINUS_RESULT:SUCCESS|FAILURE` key-value pairs) and the destruction
  confirmation path. This includes `FORCE=true` destruction: skipping the
  interactive prompt removes a speed bump, not the attribution — the operator
  who set FORCE (or configured the agent and environment that set it) is still
  the accountable human. Attribution terminates at the operator, never at the
  driving agent or the provider API.
- **What is missing for RAE L1:** the operator is self-declared (env var / OS
  username) and not verified — no organization-verified identity, no signing
  credential bound to authorization records. Linus will not claim RAE L1 until
  operator identity is verifiable (e.g., a signed attestation binding
  `LINUS_OPERATOR_ID` to an org-issued credential, especially on the FORCE
  path).

## Clause status (informational — L0 declares no enforcement tier)

| Clause | Status in Linus | Note |
|---|---|---|
| N1 Pre-attribution | Partial, declared | The operator identity is bound in the environment before the action runs (`LINUS_OPERATOR_*`, default `$USER`) — pre-attribution in *shape*. Not registration-grade: the binding is an unverified declaration. |
| N2 Agents are never RAEs | Honored | Linus is built to be driven by autonomous agents, but the agent is the subject of attribution; the operator is the object. No provisioned or destroyed resource is ever attributed to "the agent" as an accountable party. |
| N3 No-RAE invariant | Informational | Every action records an operator (defaulting to `$USER`, so an operator of record is always present), and destruction is loud by default (`y/N` gate, "cannot be undone"). `FORCE=true` suppresses the prompt but still records the operator. Linus declares no enforcement tier at RAE L0; the interactive confirm is a *destruction safety* gate, not an RAE enforcement tier — do not conflate them. |
| N4 Influenced actions | Not applicable | Linus performs agent/operator-directed infrastructure actions directly; it does not model a human acting on agent output as a separate provenance chain. |
| N5 Natural-person resolution | Honored | The operator resolves to a single named human (`LINUS_OPERATOR_NAME`), never an organization or an agent. Default `$USER` is an OS account standing in for that human at L0. |
| N6a/N6b Sponsorship scope | Partial, declared | An invocation authorizes the specific provision/destroy action it performs; provider credentials scope what the operator *can* touch. This is not yet a declared action-class scope evaluated at runtime (N6a) or reviewed for breadth (N6b). `FORCE=true` widens effective authority by removing the confirmation step — exactly the kind of scope breadth a future N6b review would want recorded. |
| N7 Sponsorship lifecycle | Not applicable | The operator binding is per-invocation environment state, not a standing sponsorship relationship; expiry/transfer semantics have nothing to attach to. Revoking access is done at the provider/credential layer, outside Linus. |
| N8 Agent-to-agent delegation | Honored (at the invocation level) | When an agent drives Linus, the action is attributable to the operator whose environment the agent runs under. Linus does not itself spawn sub-agents; the delegation is "operator → agent → Linus," and attribution resolves to the operator, never to the agent or to Linus as a party. |

## Proof location

- **Destruction confirmation + FORCE path:** `confirm_destruction` in
  `shared/provision/destroy.sh` (the `y/N` gate and the `FORCE=true` skip).
- **Structured output:** all scripts emit `LINUS_RESULT:SUCCESS|FAILURE` with
  parseable key-value pairs (see README, "Key Features for Autonomous
  Operation"); this is where the operator-of-record fields ride.
- **Operator binding (companion code change):** `LINUS_OPERATOR_ID` /
  `LINUS_OPERATOR_NAME` (default `$USER`), recorded in the structured output
  and the destruction confirmation, are delivered by the parallel code task
  this documentation describes. This PR is docs-only; it documents the
  authoritative model that change implements.

## What would change the claim

Raising Linus to *implements RAE 1.0.x L1, \<tier\> tier* requires:
organization-verified operator identity; a signing credential bound to the
operator's authorization records (a signed attestation on destructive actions,
especially `FORCE=true`, is the natural fit); declared-scope handling for
N6a/N6b including FORCE-widened authority; an enforcement-tier declaration for
N3; and conversion of this file into a true §4 conformance statement using the
canonical claim form.
