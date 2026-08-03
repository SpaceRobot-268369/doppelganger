# Agent Knowledge Base

This directory is the provider-neutral doppelganger agent knowledge base.
[`AGENTS.md`](../AGENTS.md) is its authoritative index and policy entry point.

| Area | Purpose |
|------|---------|
| [`skills/`](skills/) | Open `SKILL.md` workflows, including deterministic procedures and judgment-driven capabilities. |
| [`context/`](context/) | Development specification and product references. |
| [`memory/`](memory/) | Shared committed memory and machine-local notes. |
| [`agents/`](agents/) | Reserved for future provider-neutral subagent definitions; currently empty. |
| [`hooks/`](hooks/) | Provider-neutral hook guidance and future shared scripts; currently empty. |

Provider-specific configuration must remain a thin adapter and must never become
a competing knowledge source.
