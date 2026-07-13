# macOS Composition Behavior Contract conformance

The macOS implementation remains native to InputMethodKit. It does not adopt
the Linux protobuf or Fcitx renderer. A SHA-256 locked copy of all nine
`composition-behavior-v1` scenarios is bundled into `CoreTests` and audited at
the semantic boundary:

- `InputState` owns the editable composition cursor and direct/mapped input.
- `SegmentsManager` owns candidate segment boundaries and partial completion.
- `ConverterSession` pins the Grimodex generation for one composition epoch.
- every shared action type is mapped to `InputState`, `ClientAction`,
  `SegmentsManager`, or the marked-text adapter, or appears in the explicit
  exception set;
- conversion, segment editing, and Escape transitions execute against the real
  `InputState` in the fixture adapter test;
- existing XPC snapshot/effect, generation, secure-policy, and converter tests
  provide the platform-specific evidence referenced by that mapping.

The fixture test intentionally does not claim byte-for-byte Linux snapshot
equality: macOS has Cocoa marked-text ranges and a native candidate snapshot.
Exact scenario conformance is tracked in Grimodex's platform matrix, while the
lock and action coverage prevent silent contract drift.

The hosted Phase 5 workflow covers Core contracts, the real ConverterServer
process, watcher reload, secure-input policy, and package structure. Interactive
InputMethodKit activation in a logged-in GUI session remains an opt-in machine
test because hosted runners do not provide that lifecycle.

Known intentional platform difference: macOS marked-text ranges use the
Cocoa-side range contract; the adapter converts them to the shared semantic
caret boundary before fixture comparison.

Known gap: the native controller supports selected-text AI transforms but does
not yet expose a Japanese selected-range reconversion action equivalent to the
shared `reconvert` action. The contract audit keeps this action in an explicit
exception set and fails if a P0 trace starts depending on it before a native
adapter and replacement-range tests exist.
