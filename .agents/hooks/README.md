# Hooks

Storage for provider-neutral **hook scripts** that may run around agent events
(for example, before or after a tool call).

This directory is currently empty. Add shared scripts here only when their
behavior is provider-independent. Provider wiring belongs in a thin,
provider-specific configuration file and must remain approval-gated under
[Principle 1](../../AGENTS.md#principles); no such hook adapter is tracked today.
