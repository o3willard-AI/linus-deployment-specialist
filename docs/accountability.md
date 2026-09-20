# Accountability: the human behind provisioning and destruction

Linus Deployment Specialist follows the [Registered Accountable Entity (RAE)](https://github.com/o3willard-AI/RAE)
model: an agent action is not fully accounted for until it is attributable to a
named human being. An agent is the *subject* of attribution, never the object
(RAE N2).

This matters more here than in most tools, for two reasons that are the whole
point of Linus: it is **explicitly built for autonomous agent use** (an agent
can install and drive it end to end without a human in the loop), and it
performs **destructive, irreversible actions** (VM destruction) whose only
runtime guard is a `y/N` confirmation prompt — a prompt that `FORCE=true`
skips. A tool that lets an unattended agent create and destroy infrastructure
is precisely the tool that most needs to answer "which human is responsible for
this?" Linus answers it: the operator.

## The accountability chain

**1. The human operator deploys and runs Linus.**

Every provision and destroy action is performed by a Linus deployment running
on behalf of a human operator — the person who installed it, configured its
provider credentials, and invoked it (directly or through an agent they
tasked). The operator is the accountable human: the RAE.

**2. Every provision and destroy action is attributable to that operator.**

Provisioning a VM, configuring it, and destroying it are all recorded against
the operator of record (`LINUS_OPERATOR_ID` / `LINUS_OPERATOR_NAME`, defaulting
to the invoking `$USER`), carried through Linus's structured output
(`LINUS_RESULT:SUCCESS|FAILURE` with key-value pairs) and into the destruction
confirmation path. So the trail resolves person → invocation → infrastructure
action without leaving the tool's own output. Attribution terminates at the
operator, never at the agent that drove Linus and never at the provider API
that executed the call.

**3. `FORCE=true` does not launder attribution — it confirms it.**

Destruction normally blocks on a `y/N` confirmation (`confirm_destruction` in
`shared/provision/destroy.sh`). Setting `FORCE=true` skips that prompt so an
autonomous agent can tear down VMs unattended. This does **not** make the
destruction unattributed or anonymous. The operator who set `FORCE=true` — or
who configured the agent and the environment that set it — is the human who
forced it, and the destruction is still attributed to them. Removing the
interactive gate removes a *speed bump*, not the *accountability*: under RAE,
advance authorization (here, pre-setting FORCE) is a sponsorship shape, and the
forced action carries the operator's attribution just as a confirmed one does.
If anything, `FORCE=true` raises the stakes on getting the operator identity
right, because it is exactly the mode where no human is watching the prompt.

## Assurance level: RAE L0 (declared, unverified)

The operator is **self-declared and is not verified** — it comes from an
environment variable, defaulting to the invoking OS username (`$USER`). Nothing
in Linus proves that `LINUS_OPERATOR_NAME` is the person actually running it,
or that the OS account maps to a real, consenting human. Under the RAE
assurance ladder this places the claim at **L0 (declared)**:

> L0 — Claimed identity only. Below the registration bar: a seed of the
> practice, not the practice. (RAE §3)

So the honest claim Linus makes is: it **displays an RAE at L0 (declared,
unverified)**. It does **not** claim to *implement* RAE — the attribution
machinery of the practice (organization-verified identity, signing credentials
bound to authorization records, the rest of N1/N3/N4/N6–N8) begins at RAE L1,
and Linus is not there. See [RAE-CONFORMANCE.md](../RAE-CONFORMANCE.md) for
the exact claim boundary.

L0 is still worth having, and for a destructive autonomous tool it is the
floor, not a nicety: a recorded operator name turns "a VM was destroyed" into
"VM X was destroyed under operator Y at time T, FORCE=true," which is enough
for an organization to act on, audit, and route blame correctly. A
declared-but-false operator is a config/environment-trust problem, not an
audit-integrity problem — the structured record still shows what was declared
and when. Verifying operator identity (e.g., a signed attestation binding
`LINUS_OPERATOR_ID` to an org-issued credential, especially for FORCE
destruction) would raise the claim to RAE L1 and is out of scope for the
current version.

## Why this matters here specifically

Linus is designed so an AI agent can provision and destroy real infrastructure
with no human present. That is a feature — and it is the exact scenario in
which accountability is easiest to lose. "The agent destroyed the VM" is not an
answer an infrastructure owner, a security team, or a regulator can act on;
"operator Y, who configured and tasked the agent, forced destruction of VM X"
is. Binding every provision and destroy to a declared human operator — most
importantly in the FORCE path where no prompt intervenes — is the difference
between an autonomous infrastructure tool that merely logs its actions and one
where somebody is answerable for them.
