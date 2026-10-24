# Factory handoffs

`FactoryHandoff` composes `PreparationGate` for a producer notification and a
waiting consumer with separate lifetimes. The caller serializes transitions and
owns payload storage. `supply` reserves a result but does not publish it:
`finishCallback` must join asynchronous input cleanup first. A cancelled waiter
can retire before its queued producer starts; the producer must still call
`beginCallback` and `finishCallback` without invoking application work when the
claim is rejected. Reclaim the notification only when `releasable()` is true.

`io.ThreadAttachment.Key` supplies hosted Linux/Darwin TLS ownership where a
runtime worker close event precedes actual native thread retirement. Keep the
Key and each parent-owned Binding stable through all callbacks. Explicit detach
clears TLS before cleanup; native thread exit invokes the same cleanup once.
The cleanup may free its Binding's enclosing owner; the Key remains counted
until cleanup returns. Key.close returns Busy through bindings/in-flight calls,
and preserves ownership after a native key deletion failure. Users must provide
synchronization for Binding lifetime and final Key memory destruction.

These helpers require neither a media executor nor a second camera allocator.
The video capture backing owner adds `reapPending()` to retry failed preparations
without evicting idle profiles that a caller may need for mode rollback.
