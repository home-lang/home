# Console method investigation — 2026-10-13

The unchanged executable from main `4852a2330` completes the retained-context method probe on Node and Home. Owner and VM realm console.count calls produce count Runtime events in Node and none in Home. Native timeLog/timeEnd events are absent in Home. Node groupEnd and clear carry method-name string arguments; Home emits empty args. Debug, info, error, trace, dir, dirxml, table, assert and group event types arrive in both runtimes. Raw argument, stack and object-preview differences remain available in the archive; this is not full schema parity.

The independent lifetime probe completes in both runtimes, reads answer=42 through the actual remote object, and retains its context after object-group release, Console.clearMessages and disconnect. It does not prove a Home-specific collection regression or a passing collection acceptance. The first method probe lacked a final use of its sandbox, allowing Home to collect it; the failed run remains archived. The revised probe keeps it usable through the last command.

No production method repair is included. #888 and #428 remain open under #66. Pinned SDK references show counter/timer state belongs to the InspectorConsoleAgent; future changes must integrate actual native state and preserve retained-object lifetimes.

Storage cleanup removed completed comparison executables (336,092,544 bytes), an inactive Oct11 compile cache (88,254,217 bytes) and Electron downloads (110,225,719 bytes). Published comparison identities/results, source and active Claude updater were preserved. No tests were admitted below the existing storage threshold.
