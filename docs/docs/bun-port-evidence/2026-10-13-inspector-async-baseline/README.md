# Inspector promises and accessor baseline — 2026-10-13

Two strengthened controls pass on Node and fail on the pinned main Home executable. Source and executable hashes are verified. The ordinary diagnostic confirms missing promise subtype, unrouted realm promiseObjectId (-32000), and accessor-only requests returning data descriptors.

The first draft normal build found two diagnostics for the same SDK cast namespace error: JSC::dynamicDowncast does not exist; WTF provides the cast. That compiler unit exited 1. The owned failed build was stopped through its guard (130), preserving evidence without build or runtime pass credit.

Proposed repair `bb57ac090` uses the native SDK cast with an empty-value guard and distinguishes handle envelopes from literal fields in CallArgument/RemoteObject value JSON. The separate payload baseline, maintained Node regression, and corrected build were queued when this checkpoint was created. They receive no outcome credit here.

The [manifest](./manifest.json) retains raw evidence hashes/byte counts and source identities. Earlier validated VM realm support remains on main at `2d9025ce5` with evidence `3179edc81`. [#888](https://github.com/home-lang/home/issues/888), [#428](https://github.com/home-lang/home/issues/428), and [#66](https://github.com/home-lang/home/issues/66) remain open.
