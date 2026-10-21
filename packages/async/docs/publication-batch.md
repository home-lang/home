# Shared publication preflight

`publication_batch.Plan(capacity)` is an allocation-free helper for coordinating
one irrevocable decision across bounded prepared participants. It does not create
tasks, acquire locks, invoke callbacks or own candidate resources.

`Plan.init(identities)` rejects empty/oversized groups, zero identities and aliases.
Its `order[0..count]` lists input indices sorted by identity, retaining the original
input-to-participant mapping. Use stable lock-owner identities, not participant
identities that could alias one mutex. Acquire in that order and release in reverse.
Every caller that can lock multiple owners must follow the same order.

After acquiring all locks, re-read participant states and call `validate(states)`.
The state array must cover exactly the plan's members. Every member must be ready,
unpublished and uncancelled. Reject the whole group before changing any member
when validation fails. On success, set every publication decision before releasing
any lock or waking a worker. No user hook, allocation or other failure point belongs
between validation and that shared decision. `preparation_gate` supplies the
existing per-job lifecycle; this helper supplies only group preflight and ordering.

A publication decision does not make filesystem writes or arbitrary user hooks
transactional. Workers may install their prepared resources after the decision.
Join every worker before allowing observers to access group state. Callers retain
responsibility for pre-publication discard, joined cancellation and post-publication
retirement errors. Identity lifetime must cover the complete locked operation;
this helper is not a persistent identity allocator or a lock implementation.

Tests cover all eight readiness/cancellation/publication positions, input-order
preservation, every alias placement, invalid counts/zero identities and maximal
integer identities without arithmetic overflow.

```sh
zig test packages/async/src/publication_batch.zig
zig test packages/async/src/publication_batch.zig -O ReleaseSafe
```
