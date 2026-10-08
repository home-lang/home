# Signature substitution memo scopes

Source: [b1242be3a](https://github.com/home-lang/home/commit/b1242be3a).

Once a generic signature created a substituted local binder, its parameter,
return, receiver and predicate walks bypassed the enclosing substitution memo.
The same shared graph could therefore be rebuilt exponentially, and a parameter
and receiver with one original type could acquire different identities.

After local binders are fixed, the signature now uses a memo for that stable
substitution map. It restores the enclosing memo when the signature finishes.
Results from separate binder environments remain independent. The new controls
verify nested binders and defaults under string/number substitutions, shared
seven-level graphs, and shared parameter/receiver/assertion-predicate identity.
The allocation bound and identity assertions fail on the preceding implementation
and pass with this change; their expectations remain unchanged.

Observed gates: baseline controls 4 pass / 2 fail, candidate controls 6/6,
complete checker 4,488/4,488, driver 198/198, Program 234/234 and opt-in runner
controls 3/3. Exact stages, source hashes and raw output are in `manifest.json`.

All ten survey admission/mismatch controls pass. The standalone compiler builds
at 3,024 MB observed peak. The pinned 106-file Zod corpus retains 196 TS
diagnostics and three HM9002 recoveries at 617 MB, with the ceiling unchanged.
Its diagnostics equal the preceding checkpoint after normalizing only its
temporary directory. This recovery check does not establish a passing project.

Disk-admission refusals and an original React attempt stopped by the unchanged
critical disk floor are retained separately. They produce no complete corpus
aggregate or passing-case credit. Only inactive generated test/build caches and
older registry-cache copies were reclaimed; source, installed runtimes and
pinned Bun/WebKit artifacts were preserved. Retried checks use the same limits.

The final original React retry stops at 3,841 MB against the unchanged 3,840 MB
ceiling, with exit 125. `intraExpressionInferencesJsx` started;
`contextuallyTypedStringLiteralsInJsxAttributes02` is unstarted. No complete
aggregate or passing-case credit exists. The process sample is from the earlier
disk-stopped attempt on this same source and places work in declaration member
lowering and recursive receiver-predicate substitution. Stable signature sharing
does not resolve that remaining recursive work.

This fixes stable signature-map sharing. Recursive substitution and faithful
declaration-check policy remain open in
[#842](https://github.com/home-lang/home/issues/842). No original declarations,
fixtures, expected diagnostics, skips, TODOs, deadlines or resource ceilings
were altered. Complete corpus and Bun acceptance remain open in
[#832](https://github.com/home-lang/home/issues/832) and
[#66](https://github.com/home-lang/home/issues/66).
