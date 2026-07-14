# Usage + Context Meters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the bridge's per-convo `status` frames as a context gauge + three usage bars in the Mac chat header and behind the iOS ⓘ button, replacing the bot-profile sheet.

**Architecture:** The bridge already publishes `{kind:'ephemeral', convo_id, status:{model?, context?, limits?}}` at turn end; the journal caches the last one per convo and replays it on `viewing`. One small bridge PR adds a normalised `resets_at` ISO timestamp per limits entry. App-side: plain value types in MatronModels, a `ServerFrame` decode branch in MatronJournal, an engine fan-out stream mirroring `activities(convoID:)`, a `TimelineService` passthrough into `ChatViewModel`, and a shared DesignSystem component rendered by the Mac header and a new iOS sheet.

**Tech Stack:** Node ESM + vitest (bridge); Swift/SwiftUI, XCTest, swift-snapshot-testing (apps).

**Spec:** `docs/superpowers/specs/2026-07-14-usage-context-meters-design.md`

## Global Constraints

- Bridge work: repo `~/Dev/claude-matrix-bridge`, new branch `feat/status-resets-at` off `origin/master`, non-draft PR to `master`, push after the task.
- Apps work: repo `~/Dev/matron-apple`, existing branch `feat/usage-meters` (stacked on `feat/diff-cards`). Open a non-draft PR with base `feat/diff-cards` after Task 2's push; push after every task.
- NEVER commit `Matron/App/Info.plist` or `MatronMac/App/Info.plist` — the local NSAllowsLocalNetworking edits are deliberate and must stay uncommitted.
- Bar color thresholds, verbatim from the spec: green `< 50`, orange `< 80`, red `>= 80` (system `.green`/`.orange`/`.red`, no new palette entries).
- Reset formatting, verbatim: `resetsAt` interval `< 60s` → `now`; `< 1h` → `45m`; `< 6h` → `3h20`; otherwise local-time `EEE ha` lowercased (`Fri 12pm`); no `resetsAt` → the raw `resets` string verbatim.
- Label mapping, verbatim: `"Session"` → `Session`; `"Week (all models)"` → `Week`; any other label ending in a parenthesized name → the inner name (`"Week (Fable)"` → `Fable`); anything else passes through verbatim.
- Token compact format: `< 1000` → raw; `< 1m` → rounded `k` (`265k`); else `m` with one decimal only when non-integral (`1m`, `1.5m`).
- Absent status parts mean "unchanged" — merge, never clear, on partial frames.
- SPM tests: `swift test --package-path MatronShared`; report the "Executed N tests" line(s). Never let a grep/tail pipeline hide a failure — assert the executed count is present and failures are 0.
- App builds: `xcodebuild -project Matron.xcodeproj -scheme Matron -destination 'generic/platform=iOS' build` and `xcodebuild -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' build`. Run `xcodegen generate` first whenever app-target files were added or removed.
- Mac app-target tests: `xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests` (never the full MatronMac scheme test — the unsigned XCUITest runner fails Gatekeeper locally).
- iOS app-target tests: `xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MatronTests` (this machine has iPhone 17 simulators, not iPhone 16).

---

### Task 1: Bridge — `parseResetsAt` + `resets_at` on limits entries

**Files:**
- Modify: `~/Dev/claude-matrix-bridge/lib/usage-limits.js`
- Test: `~/Dev/claude-matrix-bridge/test/usage-limits.test.js`

**Interfaces:**
- Consumes: existing `parseUsageLimits(rawText)` / `LINE_RE` in the same file.
- Produces: `parseResetsAt(resetsText, now = new Date())` → ISO-8601 string or `null`; `parseUsageLimits(rawText, now = new Date())` whose line objects gain `resets_at` (ISO string) when parseable, field omitted when not. `index.js` already caches `parsed.lines` and `buildSessionStatus` passes `limits` through untouched, so `resets_at` reaches the journal with no other change.

- [ ] **Step 1: Create the branch**

```bash
cd ~/Dev/claude-matrix-bridge
git fetch origin
git checkout -b feat/status-resets-at origin/master
```

- [ ] **Step 2: Write the failing tests**

Append to `test/usage-limits.test.js` (and add `parseResetsAt` to the import from `../lib/usage-limits.js`):

```js
describe('parseResetsAt', () => {
  const now = new Date('2026-07-08T00:00:00Z');

  it('parses an am time to a UTC ISO timestamp', () => {
    expect(parseResetsAt('Jul 9, 12:59am (UTC)', now)).toBe('2026-07-09T00:59:00.000Z');
  });

  it('parses a pm time', () => {
    expect(parseResetsAt('Jul 12, 6:59pm (UTC)', now)).toBe('2026-07-12T18:59:00.000Z');
  });

  it('rolls to next year when the month/day is far in the past', () => {
    expect(parseResetsAt('Jan 2, 3:00am (UTC)', new Date('2026-12-30T00:00:00Z')))
      .toBe('2027-01-02T03:00:00.000Z');
  });

  it('keeps a reset less than 24h in the past in the current year', () => {
    expect(parseResetsAt('Jul 9, 12:59am (UTC)', new Date('2026-07-09T06:00:00Z')))
      .toBe('2026-07-09T00:59:00.000Z');
  });

  it('returns null on unparseable input', () => {
    expect(parseResetsAt('soon', now)).toBeNull();
    expect(parseResetsAt('', now)).toBeNull();
    expect(parseResetsAt(null, now)).toBeNull();
    expect(parseResetsAt('Julember 9, 12:59am (UTC)', now)).toBeNull();
    expect(parseResetsAt('Jul 9, 12:59am (PST)', now)).toBeNull();
  });
});
```

And a `parseUsageLimits` integration case inside the existing `describe('parseUsageLimits', …)` block:

```js
  it('adds resets_at to lines when the reset text parses', () => {
    const { lines } = parseUsageLimits(SUBSCRIPTION_SAMPLE, new Date('2026-07-08T00:00:00Z'));
    expect(lines.map((l) => l.resets_at)).toEqual([
      '2026-07-09T00:59:00.000Z',
      '2026-07-12T18:59:00.000Z',
      '2026-07-12T18:59:00.000Z',
    ]);
  });

  it('omits resets_at when the reset text does not parse', () => {
    const { lines } = parseUsageLimits('Current session: 39% used · resets soon\n');
    expect(lines).toHaveLength(1);
    expect('resets_at' in lines[0]).toBe(false);
  });
```

The FIRST existing test (`extracts the Current session / week headline lines`) uses `toEqual` on the full line objects, so it must be updated in the same commit: pass `new Date('2026-07-08T00:00:00Z')` as the second argument and add the matching `resets_at` to each expected object (`'2026-07-09T00:59:00.000Z'`, `'2026-07-12T18:59:00.000Z'`, `'2026-07-12T18:59:00.000Z'`).

- [ ] **Step 3: Run tests to verify the new ones fail**

Run: `npx vitest run test/usage-limits.test.js`
Expected: FAIL — `parseResetsAt` is not exported.

- [ ] **Step 4: Implement**

In `lib/usage-limits.js`, below `LINE_RE`:

```js
// "Jul 9, 12:59am (UTC)" -> ISO-8601 string, or null when the text doesn't
// match the fixed format claude prints. The source has no year: use `now`'s
// UTC year, rolling forward one year when the result would be more than 24h
// in the past (resets are always in the future; the 24h tolerance absorbs
// clock skew and a stale cache read). `now` is injected for testability.
const MONTHS = {
  jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5,
  jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11,
};
const RESETS_AT_RE = /^([A-Za-z]{3})\s+(\d{1,2}),\s*(\d{1,2}):(\d{2})\s*(am|pm)\s*\(UTC\)$/i;

export function parseResetsAt(resetsText, now = new Date()) {
  const m = String(resetsText ?? '').trim().match(RESETS_AT_RE);
  if (!m) return null;
  const month = MONTHS[m[1].toLowerCase()];
  if (month === undefined) return null;
  const day = parseInt(m[2], 10);
  const minute = parseInt(m[4], 10);
  let hour = parseInt(m[3], 10) % 12;
  if (m[5].toLowerCase() === 'pm') hour += 12;
  if (day < 1 || day > 31 || minute > 59 || hour > 23) return null;
  let candidate = new Date(Date.UTC(now.getUTCFullYear(), month, day, hour, minute));
  if (candidate.getTime() < now.getTime() - 24 * 60 * 60 * 1000) {
    candidate = new Date(Date.UTC(now.getUTCFullYear() + 1, month, day, hour, minute));
  }
  return candidate.toISOString();
}
```

Change `parseUsageLimits`'s signature to `export function parseUsageLimits(rawText, now = new Date())` and replace the `lines.push({...})` body with:

```js
    const resets = m[3].trim();
    const entry = {
      // Strip the "Current " prefix (already dropped by the regex) and
      // uppercase the first character: "session" -> "Session",
      // "week (all models)" -> "Week (all models)". No model name hardcoded.
      label: rawLabel.charAt(0).toUpperCase() + rawLabel.slice(1),
      percent: parseInt(m[2], 10),
      resets,
    };
    const resetsAt = parseResetsAt(resets, now);
    if (resetsAt) entry.resets_at = resetsAt;
    lines.push(entry);
```

(Keep the existing `const rawLabel = m[1].trim();` line above it.) `index.js` callers pass no `now` — the default is correct there. `formatLimits` ignores the extra field; do not touch it.

- [ ] **Step 5: Run the full bridge suite**

Run: `npx vitest run`
Expected: PASS, no failures. Report the test-count summary line.

- [ ] **Step 6: Commit, push, open PR**

```bash
git add lib/usage-limits.js test/usage-limits.test.js
git commit -m "feat(usage-limits): parse reset text into resets_at ISO timestamp"
git push -u origin feat/status-resets-at
gh pr create --title "feat: normalised resets_at timestamp on usage-limit lines" --body "Parses claude's \"Jul 9, 12:59am (UTC)\" reset text into an ISO-8601 resets_at field on each parsed limits line (year rolled to the next future occurrence, fail-open: field omitted when unparseable, raw string kept). Flows through buildSessionStatus to the journal status frame untouched; consumed by the Matron apps' new usage meters."
```

---

### Task 2: Apps — `SessionStatus` value types, decode branch, engine fan-out

**Files:**
- Create: `MatronShared/Sources/Models/SessionStatus.swift`
- Modify: `MatronShared/Sources/Journal/WireModels.swift` (imports + `ServerFrame` case + decode branch)
- Modify: `MatronShared/Sources/Journal/JournalSyncEngine.swift` (continuation registry + stream + frame-loop case)
- Test: `MatronShared/Tests/JournalTests/WireModelsTests.swift`, `MatronShared/Tests/JournalTests/JournalSyncEngineTests.swift`, new `MatronShared/Tests/JournalTests/SessionStatusTests.swift`

**Interfaces:**
- Consumes: `ServerFrame.decode` ephemeral branching (WireModels.swift:159-206), `activities(convoID:)` pattern (JournalSyncEngine.swift:194-202, 253-259, 385-388).
- Produces (later tasks rely on these exact names):
  - `MatronModels.SessionStatus` — `struct { var model: String?; var context: Context?; var limits: [Limit]?; mutating func apply(_ update: SessionStatusUpdate) }` with `SessionStatus.Context { let tokens: Int; let window: Int; let pct: Int }` and `SessionStatus.Limit { let label: String; let percent: Int; let resets: String?; let resetsAt: Date? }`.
  - `MatronModels.SessionStatusUpdate` — `struct { let convoID: String; let model: String?; let context: SessionStatus.Context?; let limits: [SessionStatus.Limit]? }`.
  - `ServerFrame.sessionStatus(SessionStatusUpdate)`.
  - `JournalSyncEngine.sessionStatus(convoID: String) -> AsyncStream<SessionStatusUpdate>`.

- [ ] **Step 1: Write the failing decode + merge tests**

Append to `MatronShared/Tests/JournalTests/WireModelsTests.swift` (the target already imports `MatronModels` via other tests; add `import MatronModels` at the top of the file if not present):

```swift
    func testDecodeSessionStatusEphemeralFrame() throws {
        let text = #"{"kind":"ephemeral","convo_id":"c1","status":{"model":"claude-fable-5","context":{"tokens":265000,"window":1000000,"pct":27},"limits":[{"label":"Week (Fable)","percent":80,"resets":"Jul 12, 6:59pm (UTC)","resets_at":"2026-07-12T18:59:00.000Z"}]}}"#
        guard case let .sessionStatus(update)? = ServerFrame.decode(text) else {
            return XCTFail("expected sessionStatus frame")
        }
        XCTAssertEqual(update.convoID, "c1")
        XCTAssertEqual(update.model, "claude-fable-5")
        XCTAssertEqual(update.context, SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(update.limits, [SessionStatus.Limit(
            label: "Week (Fable)", percent: 80,
            resets: "Jul 12, 6:59pm (UTC)",
            resetsAt: iso.date(from: "2026-07-12T18:59:00.000Z"))])
    }

    func testDecodeSessionStatusPartialAndMalformed() throws {
        // Context-only frame: model / limits stay nil.
        guard case let .sessionStatus(partial)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"context":{"tokens":5000,"window":200000,"pct":3}}}"#) else {
            return XCTFail("expected context-only sessionStatus frame")
        }
        XCTAssertNil(partial.model)
        XCTAssertNil(partial.limits)
        XCTAssertEqual(partial.context?.tokens, 5000)

        // Malformed resets_at degrades to nil; the raw string survives.
        guard case let .sessionStatus(badDate)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"limits":[{"label":"Session","percent":39,"resets":"soon","resets_at":"not-a-date"}]}}"#) else {
            return XCTFail("expected sessionStatus frame with unparseable resets_at")
        }
        XCTAssertEqual(badDate.limits?.first?.resets, "soon")
        XCTAssertNil(badDate.limits?.first?.resetsAt)

        // A context object missing a required key decodes as nil context.
        guard case let .sessionStatus(noPct)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"model":"m","context":{"tokens":5000}}}"#) else {
            return XCTFail("expected sessionStatus frame with malformed context")
        }
        XCTAssertNil(noPct.context)
        XCTAssertEqual(noPct.model, "m")

        // A limits entry missing label/percent is skipped; the good one survives.
        guard case let .sessionStatus(mixed)? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","status":{"limits":[{"percent":5},{"label":"Session","percent":39}]}}"#) else {
            return XCTFail("expected sessionStatus frame with mixed limits")
        }
        XCTAssertEqual(mixed.limits?.map(\.label), ["Session"])

        // Plain text-streaming ephemerals must still decode as before.
        guard case .ephemeral? = ServerFrame.decode(
            #"{"kind":"ephemeral","convo_id":"c1","message_ref":"m7","text":"hi"}"#) else {
            return XCTFail("text streaming ephemeral regressed")
        }
    }
```

Create `MatronShared/Tests/JournalTests/SessionStatusTests.swift`:

```swift
import XCTest
import MatronModels

final class SessionStatusTests: XCTestCase {
    func testApplyMergesPartsIndependently() {
        var status = SessionStatus()
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: "claude-fable-5",
            context: SessionStatus.Context(tokens: 100_000, window: 1_000_000, pct: 10),
            limits: nil))
        XCTAssertEqual(status.model, "claude-fable-5")
        XCTAssertEqual(status.context?.pct, 10)
        XCTAssertNil(status.limits)

        // A limits-only frame must not clear model/context.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil,
            limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: "soon", resetsAt: nil)]))
        XCTAssertEqual(status.model, "claude-fable-5")
        XCTAssertEqual(status.context?.pct, 10)
        XCTAssertEqual(status.limits?.count, 1)

        // A newer context replaces the old one.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil,
            context: SessionStatus.Context(tokens: 200_000, window: 1_000_000, pct: 20),
            limits: nil))
        XCTAssertEqual(status.context?.tokens, 200_000)
        XCTAssertEqual(status.limits?.count, 1)
    }
}
```

Append to `MatronShared/Tests/JournalTests/JournalSyncEngineTests.swift` (mirrors `testEphemeralFanOut` at line 92):

```swift
    func testSessionStatusFanOutToMatchingConvoOnly() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        var iterC1 = engine.sessionStatus(convoID: "c1").makeAsyncIterator()
        // A frame for another convo first: if fan-out ignored convoID,
        // c1's iterator would yield it.
        socket.serve(#"{"kind":"ephemeral","convo_id":"c2","status":{"model":"other"}}"#)
        socket.serve(#"{"kind":"ephemeral","convo_id":"c1","status":{"context":{"tokens":265000,"window":1000000,"pct":27}}}"#)
        let update = await iterC1.next()
        XCTAssertEqual(update?.convoID, "c1")
        XCTAssertEqual(update?.context?.pct, 27)
        await engine.endSync()
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path MatronShared --filter JournalTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `SessionStatus` / `sessionStatus` unresolved.

- [ ] **Step 3: Create the value types**

Create `MatronShared/Sources/Models/SessionStatus.swift`:

```swift
import Foundation

/// Per-conversation session status published by the bridge at turn end
/// (journal `status` ephemeral): model name, a context-window gauge, and
/// account rate limits. Parts are independently optional — the bridge
/// omits what it doesn't know, and absent parts mean "unchanged", so the
/// held value merges updates rather than replacing wholesale.
public struct SessionStatus: Equatable, Sendable {
    /// Context-window gauge — an estimate computed by the bridge from the
    /// last request's usage block, not /context's exact accounting.
    public struct Context: Equatable, Sendable {
        public let tokens: Int
        public let window: Int
        public let pct: Int

        public init(tokens: Int, window: Int, pct: Int) {
            self.tokens = tokens
            self.window = window
            self.pct = pct
        }
    }

    /// One account rate-limit line (session / week / per-model week).
    /// `resets` is the raw text claude printed; `resetsAt` is the bridge's
    /// normalised timestamp, nil when the bridge couldn't parse the text —
    /// renderers fall back to showing `resets` verbatim.
    public struct Limit: Equatable, Sendable {
        public let label: String
        public let percent: Int
        public let resets: String?
        public let resetsAt: Date?

        public init(label: String, percent: Int, resets: String?, resetsAt: Date?) {
            self.label = label
            self.percent = percent
            self.resets = resets
            self.resetsAt = resetsAt
        }
    }

    public var model: String?
    public var context: Context?
    public var limits: [Limit]?

    public init(model: String? = nil, context: Context? = nil, limits: [Limit]? = nil) {
        self.model = model
        self.context = context
        self.limits = limits
    }

    /// Merge an update: each part replaces the held value only when the
    /// frame carries it (absent = unchanged, per the status protocol).
    public mutating func apply(_ update: SessionStatusUpdate) {
        if let model = update.model { self.model = model }
        if let context = update.context { self.context = context }
        if let limits = update.limits { self.limits = limits }
    }
}

/// One decoded `status` ephemeral frame. Lives in MatronModels (not
/// MatronJournal) so view models and the design system can consume it
/// without a journal dependency.
public struct SessionStatusUpdate: Equatable, Sendable {
    public let convoID: String
    public let model: String?
    public let context: SessionStatus.Context?
    public let limits: [SessionStatus.Limit]?

    public init(convoID: String, model: String?, context: SessionStatus.Context?, limits: [SessionStatus.Limit]?) {
        self.convoID = convoID
        self.model = model
        self.context = context
        self.limits = limits
    }
}
```

- [ ] **Step 4: Decode branch in WireModels**

In `MatronShared/Sources/Journal/WireModels.swift`: add `import MatronModels` under `import Foundation`. Add the case to `ServerFrame`:

```swift
    case sessionStatus(SessionStatusUpdate)
```

Add static ISO parsers inside `ServerFrame` (above `decode`):

```swift
    /// Bridge timestamps are `Date.toISOString()` output (always fractional),
    /// but accept plain ISO too for robustness. ISO8601DateFormatter is
    /// thread-safe, so shared statics are fine.
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseISODate(_ raw: String) -> Date? {
        isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }
```

Insert the decode branch AFTER the `tool_stream` branch and BEFORE the `guard let ref = obj["message_ref"]` line (status frames carry neither `activity` nor `message_ref`, so they currently fall into that guard and drop):

```swift
            // Session-status frames carry a `status` object and no
            // `message_ref`. Parts are independently optional; malformed
            // sub-objects degrade to nil rather than dropping the frame.
            if let status = obj["status"] as? [String: Any] {
                var context: SessionStatus.Context?
                if let ctx = status["context"] as? [String: Any],
                   let tokens = (ctx["tokens"] as? NSNumber)?.intValue,
                   let window = (ctx["window"] as? NSNumber)?.intValue,
                   let pct = (ctx["pct"] as? NSNumber)?.intValue {
                    context = SessionStatus.Context(tokens: tokens, window: window, pct: pct)
                }
                var limits: [SessionStatus.Limit]?
                if let rawLimits = status["limits"] as? [[String: Any]] {
                    let parsed = rawLimits.compactMap { entry -> SessionStatus.Limit? in
                        guard let label = entry["label"] as? String,
                              let percent = (entry["percent"] as? NSNumber)?.intValue
                        else { return nil }
                        return SessionStatus.Limit(
                            label: label, percent: percent,
                            resets: entry["resets"] as? String,
                            resetsAt: (entry["resets_at"] as? String).flatMap(parseISODate))
                    }
                    if !parsed.isEmpty { limits = parsed }
                }
                return .sessionStatus(SessionStatusUpdate(
                    convoID: convoID, model: status["model"] as? String,
                    context: context, limits: limits))
            }
```

- [ ] **Step 5: Engine fan-out**

In `MatronShared/Sources/Journal/JournalSyncEngine.swift`, mirroring the activity plumbing exactly:

Registry (next to `toolStreamContinuations`, line ~55):

```swift
    private var sessionStatusContinuations: [UUID: (convoID: String, continuation: AsyncStream<SessionStatusUpdate>.Continuation)] = [:]
```

Public stream (after `toolStreams(convoID:)`, line ~215):

```swift
    /// Per-conversation stream of session-status updates (journal `status`
    /// ephemerals). Mirrors `activities(convoID:)`. The journal replays the
    /// last cached status when the client sends `viewing`, so a subscriber
    /// that attaches on convo-open gets a populated header immediately —
    /// no client-side caching needed.
    public nonisolated func sessionStatus(convoID: String) -> AsyncStream<SessionStatusUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerSessionStatus(id: id, convoID: convoID, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterSessionStatus(id: id) }
            }
        }
    }
```

Register/unregister (next to the toolStream pair, line ~261):

```swift
    private func registerSessionStatus(id: UUID, convoID: String, continuation: AsyncStream<SessionStatusUpdate>.Continuation) {
        sessionStatusContinuations[id] = (convoID, continuation)
    }

    private func unregisterSessionStatus(id: UUID) {
        sessionStatusContinuations.removeValue(forKey: id)
    }
```

Frame loop (next to `case .toolStream`, line ~415):

```swift
                    case .sessionStatus(let update):
                        for (_, entry) in sessionStatusContinuations where entry.convoID == update.convoID {
                            entry.continuation.yield(update)
                        }
```

- [ ] **Step 6: Run the SPM suite**

Run: `swift test --package-path MatronShared 2>&1 | tail -5`
Expected: PASS. Report every "Executed N tests" line; failures must be 0. (A 9-unattributed-failure full-suite flake has recurred on this machine — if it hits, rerun once and report both outcomes.)

- [ ] **Step 7: Commit, push, open the apps PR**

```bash
cd ~/Dev/matron-apple
git add MatronShared/Sources/Models/SessionStatus.swift MatronShared/Sources/Journal/WireModels.swift MatronShared/Sources/Journal/JournalSyncEngine.swift MatronShared/Tests/JournalTests/
git commit -m "feat(journal): decode session-status ephemerals + engine fan-out"
git push -u origin feat/usage-meters
gh pr create --base feat/diff-cards --title "feat: usage + context meters in the chat header" --body "Renders the bridge's per-convo status frames (context gauge + Session/Week/model usage bars with reset times) in the Mac chat header and behind the iOS info button, replacing the bot-profile sheet. Spec: docs/superpowers/specs/2026-07-14-usage-context-meters-design.md. Bridge counterpart: claude-matrix-bridge feat/status-resets-at."
```

---

### Task 3: Apps — `TimelineService` passthrough + `ChatViewModel` subscription

**Files:**
- Modify: `MatronShared/Sources/Chat/TimelineService.swift`
- Modify: `MatronShared/Sources/Chat/JournalTimelineService.swift`
- Modify: `MatronShared/Sources/ViewModels/ChatViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift` (new test) and `MatronShared/Tests/ViewModelTests/ComposerViewModelTests.swift` (the shared `FakeTimelineService` lives at the top of this file — extend it there)

**Interfaces:**
- Consumes: `SessionStatusUpdate` / `SessionStatus` (Task 2), `JournalSyncEngine.sessionStatus(convoID:)` (Task 2), `ChatViewModel.start()/stop()` lifecycle (ChatViewModel.swift:411-530).
- Produces: `TimelineService.sessionStatus() -> AsyncStream<SessionStatusUpdate>` (defaulted, so existing fakes keep compiling); `ChatViewModel.sessionStatus: SessionStatus?` (`public private(set)`, main-actor mutated) — Tasks 6 and 7 render this.

- [ ] **Step 1: Write the failing view-model test**

The `ViewModelTests` target shares one `FakeTimelineService`, defined at the top of `ComposerViewModelTests.swift` (line ~10). Extend THAT class (do not create a second conformance) with a driveable status stream:

```swift
    private let statusPair = AsyncStream<SessionStatusUpdate>.makeStream()
    var statusContinuation: AsyncStream<SessionStatusUpdate>.Continuation { statusPair.continuation }
    func sessionStatus() -> AsyncStream<SessionStatusUpdate> { statusPair.stream }
```

Then append to `ChatViewModelTests.swift`, matching its existing `@MainActor` + `snapshotsToEmit` style (the fake's items stream finishes after yielding its snapshots, so `await task.value` marks "items processed" while the status stream stays live):

```swift
    @MainActor
    func testSessionStatusSubscriptionMergesPartialFrames() async throws {
        let fake = FakeTimelineService()
        fake.snapshotsToEmit = [[]]
        let vm = ChatViewModel(roomID: "!r:s", timeline: fake, media: FakeMediaService())
        let task = await vm.start()
        defer { vm.stop() }
        await task.value

        fake.statusContinuation.yield(SessionStatusUpdate(
            convoID: "!r:s", model: nil,
            context: SessionStatus.Context(tokens: 100_000, window: 1_000_000, pct: 10),
            limits: nil))
        for _ in 0..<200 {
            if vm.sessionStatus?.context != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.sessionStatus?.context?.pct, 10)

        // A model-only frame must not clear the held context.
        fake.statusContinuation.yield(SessionStatusUpdate(
            convoID: "!r:s", model: "claude-fable-5", context: nil, limits: nil))
        for _ in 0..<200 {
            if vm.sessionStatus?.model != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.sessionStatus?.model, "claude-fable-5")
        XCTAssertEqual(vm.sessionStatus?.context?.pct, 10)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MatronShared --filter ChatViewModelTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `sessionStatus` unresolved on the protocol/VM.

- [ ] **Step 3: Protocol + live implementation**

`MatronShared/Sources/Chat/TimelineService.swift` — add `import MatronModels` under `import Foundation`. Add to the protocol after `markAsRead()`:

```swift
    /// Per-convo stream of session-status updates (model, context gauge,
    /// account limits) — journal `status` ephemerals. The journal replays
    /// the last cached status on `viewing`, so subscribing at convo-open
    /// is enough to populate a header immediately.
    func sessionStatus() -> AsyncStream<SessionStatusUpdate>
```

And to the existing `public extension TimelineService` block:

```swift
    /// Default: no status source — an immediately-finished stream, so
    /// implementations and test fakes without one need no changes.
    func sessionStatus() -> AsyncStream<SessionStatusUpdate> {
        AsyncStream { $0.finish() }
    }
```

`MatronShared/Sources/Chat/JournalTimelineService.swift` — add near the other public methods (it already imports MatronModels via its neighbors; add the import if missing):

```swift
    public func sessionStatus() -> AsyncStream<SessionStatusUpdate> {
        engine.sessionStatus(convoID: convoID)
    }
```

- [ ] **Step 4: ChatViewModel subscription**

In `MatronShared/Sources/ViewModels/ChatViewModel.swift`:

Property (next to `public private(set) var error` at line ~92):

```swift
    /// Last-known session status for this conversation (context gauge +
    /// usage limits), merged across partial frames — absent parts keep
    /// their previous value. Rendered by the Mac chat header and the iOS
    /// session-status sheet. Nil until the first status frame (the journal
    /// replays the cached one on convo-open, so this populates promptly).
    public private(set) var sessionStatus: SessionStatus?
```

Task handle (next to `observationTask` at line ~313):

```swift
    private var statusTask: Task<Void, Never>?
```

In `start()`, immediately after `observationTask = task` (line ~503):

```swift
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await update in timeline.sessionStatus() {
                guard let self else { return }
                await MainActor.run {
                    var merged = self.sessionStatus ?? SessionStatus()
                    merged.apply(update)
                    self.sessionStatus = merged
                }
            }
        }
```

In `stop()` (line ~520), alongside the other cancellations:

```swift
        statusTask?.cancel()
        statusTask = nil
```

Do NOT reset `sessionStatus` in `stop()` — the VM is per-room (cached by roomID), so held status can only ever belong to this room, and keeping it avoids a blank header on re-open before the `viewing` replay lands.

- [ ] **Step 5: Run the SPM suite**

Run: `swift test --package-path MatronShared 2>&1 | tail -5`
Expected: PASS, failures 0; report "Executed N tests" lines.

- [ ] **Step 6: Commit + push**

```bash
git add MatronShared/Sources/Chat/TimelineService.swift MatronShared/Sources/Chat/JournalTimelineService.swift MatronShared/Sources/ViewModels/ChatViewModel.swift MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift
git commit -m "feat(chat): session-status stream through TimelineService into ChatViewModel"
git push
```

---

### Task 4: Apps — `UsageMetersFormat` pure helpers

**Files:**
- Create: `MatronShared/Sources/DesignSystem/UsageMetersFormat.swift`
- Test: Create `MatronShared/Tests/DesignSystemSnapshotTests/UsageMetersFormatTests.swift`

**Interfaces:**
- Consumes: nothing app-specific (SwiftUI `Color`, Foundation).
- Produces (Task 5 renders with these exact signatures): `UsageMetersFormat.compactTokens(_ n: Int) -> String`, `spokenTokens(_ n: Int) -> String`, `barLabel(_ raw: String) -> String`, `barColor(percent: Int) -> Color`, `resetDisplay(resetsAt: Date?, raw: String?, now: Date, timeZone: TimeZone = .current) -> String?`.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/DesignSystemSnapshotTests/UsageMetersFormatTests.swift` (plain XCTest in the snapshot target — precedent: `DateSeparatorLabelTests.swift`, `LiveOutputLogicTests.swift`):

```swift
import XCTest
import SwiftUI
@testable import MatronDesignSystem

final class UsageMetersFormatTests: XCTestCase {
    func testCompactTokens() {
        XCTAssertEqual(UsageMetersFormat.compactTokens(0), "0")
        XCTAssertEqual(UsageMetersFormat.compactTokens(999), "999")
        XCTAssertEqual(UsageMetersFormat.compactTokens(1_000), "1k")
        XCTAssertEqual(UsageMetersFormat.compactTokens(265_400), "265k")
        XCTAssertEqual(UsageMetersFormat.compactTokens(999_500), "1000k")
        XCTAssertEqual(UsageMetersFormat.compactTokens(200_000), "200k")
        XCTAssertEqual(UsageMetersFormat.compactTokens(1_000_000), "1m")
        XCTAssertEqual(UsageMetersFormat.compactTokens(1_500_000), "1.5m")
    }

    func testSpokenTokens() {
        XCTAssertEqual(UsageMetersFormat.spokenTokens(265_400), "265 thousand")
        XCTAssertEqual(UsageMetersFormat.spokenTokens(1_000_000), "1 million")
        XCTAssertEqual(UsageMetersFormat.spokenTokens(1_500_000), "1.5 million")
        XCTAssertEqual(UsageMetersFormat.spokenTokens(500), "500")
    }

    func testBarLabelMapping() {
        XCTAssertEqual(UsageMetersFormat.barLabel("Session"), "Session")
        XCTAssertEqual(UsageMetersFormat.barLabel("Week (all models)"), "Week")
        XCTAssertEqual(UsageMetersFormat.barLabel("Week (Fable)"), "Fable")
        XCTAssertEqual(UsageMetersFormat.barLabel("Week (Sonnet 5)"), "Sonnet 5")
        XCTAssertEqual(UsageMetersFormat.barLabel("Something else"), "Something else")
        XCTAssertEqual(UsageMetersFormat.barLabel(""), "")
    }

    func testBarColorThresholds() {
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 0), .green)
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 49), .green)
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 50), .orange)
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 79), .orange)
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 80), .red)
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 100), .red)
    }

    func testResetDisplay() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let utc = TimeZone(identifier: "UTC")!

        // No timestamp -> raw fallback (nil raw -> nil).
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: nil, raw: "soon", now: now), "soon")
        XCTAssertNil(UsageMetersFormat.resetDisplay(resetsAt: nil, raw: nil, now: now))

        // Already passed / imminent -> "now".
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(-300), raw: nil, now: now, timeZone: utc), "now")
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(30), raw: nil, now: now, timeZone: utc), "now")

        // Under an hour -> minutes.
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(45 * 60), raw: nil, now: now, timeZone: utc), "45m")

        // Under six hours -> XhMM countdown.
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(3 * 3600 + 20 * 60), raw: nil, now: now, timeZone: utc), "3h20")
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(5 * 3600 + 5 * 60), raw: nil, now: now, timeZone: utc), "5h05")

        // Six hours or more -> weekday + hour in the given time zone.
        // 1_760_000_000 is Thu 2025-10-09 08:53:20 UTC; +3 days lands Sun 08:53 -> "Sun 8am".
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(3 * 24 * 3600), raw: nil, now: now, timeZone: utc), "Sun 8am")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path MatronShared --filter UsageMetersFormatTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `UsageMetersFormat` unresolved.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/DesignSystem/UsageMetersFormat.swift`:

```swift
import SwiftUI

/// Pure formatting for the usage/context meters — kept off the views so
/// the label mapping, countdown wording, and thresholds unit-test without
/// rendering. Thresholds mirror the bridge's /usage colors (usage-limits.js
/// percentColor): green < 50, orange < 80, red >= 80.
public enum UsageMetersFormat {
    /// 265_400 -> "265k", 1_000_000 -> "1m", 1_500_000 -> "1.5m".
    public static func compactTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        let millions = (Double(n) / 1_000_000 * 10).rounded() / 10
        return millions == millions.rounded()
            ? "\(Int(millions))m"
            : String(format: "%.1fm", millions)
    }

    /// VoiceOver variant: "265 thousand", "1 million".
    public static func spokenTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded())) thousand" }
        let millions = (Double(n) / 1_000_000 * 10).rounded() / 10
        return millions == millions.rounded()
            ? "\(Int(millions)) million"
            : String(format: "%.1f million", millions)
    }

    /// "Session" -> "Session"; "Week (all models)" -> "Week"; any other
    /// label ending in a parenthesized name -> the inner name, so a model
    /// rename upstream never needs an app change.
    public static func barLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"),
              let open = trimmed.range(of: "(", options: .backwards)
        else { return trimmed }
        let inner = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return trimmed }
        return inner.lowercased() == "all models"
            ? String(trimmed[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            : inner
    }

    public static func barColor(percent: Int) -> Color {
        if percent < 50 { return .green }
        if percent < 80 { return .orange }
        return .red
    }

    /// Reset time for a bar's trailing text. Near resets read as a
    /// countdown, far ones as local weekday + hour; no timestamp falls
    /// back to the raw text the bridge scraped.
    public static func resetDisplay(resetsAt: Date?, raw: String?, now: Date, timeZone: TimeZone = .current) -> String? {
        guard let resetsAt else { return raw }
        let interval = resetsAt.timeIntervalSince(now)
        if interval < 60 { return "now" }
        let totalMinutes = Int(interval / 60)
        if interval < 3600 { return "\(totalMinutes)m" }
        if interval < 6 * 3600 {
            return String(format: "%dh%02d", totalMinutes / 60, totalMinutes % 60)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        formatter.dateFormat = "EEE ha"
        return formatter.string(from: resetsAt)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --package-path MatronShared --filter UsageMetersFormatTests 2>&1 | tail -5`
Expected: PASS ("Executed 5 tests").

- [ ] **Step 5: Commit + push**

```bash
git add MatronShared/Sources/DesignSystem/UsageMetersFormat.swift MatronShared/Tests/DesignSystemSnapshotTests/UsageMetersFormatTests.swift
git commit -m "feat(design): UsageMetersFormat — token/label/reset formatting + bar colors"
git push
```

---

### Task 5: Apps — `UsageMetersView` (gauge + bars) + snapshots

**Files:**
- Create: `MatronShared/Sources/DesignSystem/UsageMetersView.swift`
- Test: Create `MatronShared/Tests/DesignSystemSnapshotTests/UsageMetersSnapshotTests.swift`

**Interfaces:**
- Consumes: `SessionStatus.Context` / `SessionStatus.Limit` (Task 2, MatronModels — already a MatronDesignSystem dependency), `UsageMetersFormat` (Task 4), `assertVariants(of:named:)` (SnapshotVariants.swift).
- Produces (Tasks 6/7 embed these): `ContextGaugeLabel(context:)` and `UsageBarsView(limits:scale:fixedNow:)` with `UsageBarsView.Scale` = `.compact` (Mac header) / `.regular` (iOS sheet); `fixedNow` freezes the clock for snapshots, nil = live 1-minute `TimelineView` refresh.

- [ ] **Step 1: Implement the views**

Create `MatronShared/Sources/DesignSystem/UsageMetersView.swift`:

```swift
import SwiftUI
import MatronModels

/// "Context: 265k/1m" — the context-window gauge from the last status
/// frame. Caption-sized secondary text; sits left of the Mac header title
/// and at the top of the iOS session-status sheet.
public struct ContextGaugeLabel: View {
    let context: SessionStatus.Context

    public init(context: SessionStatus.Context) {
        self.context = context
    }

    public var body: some View {
        Text("Context: \(UsageMetersFormat.compactTokens(context.tokens))/\(UsageMetersFormat.compactTokens(context.window))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Context: \(UsageMetersFormat.spokenTokens(context.tokens)) of \(UsageMetersFormat.spokenTokens(context.window)) tokens")
    }
}

/// Stacked horizontal usage bars (Session / Week / model) with the reset
/// time trailing each bar. `.compact` fits the Mac toolbar's height;
/// `.regular` is the roomier iOS-sheet form. A 1-minute TimelineView keeps
/// countdown text ("3h20") fresh between status frames; `fixedNow` swaps
/// it for a frozen clock so snapshots are deterministic.
public struct UsageBarsView: View {
    public enum Scale {
        case compact, regular

        var font: Font { self == .compact ? .system(size: 9) : .caption }
        var barWidth: CGFloat { self == .compact ? 90 : 160 }
        var barHeight: CGFloat { self == .compact ? 3 : 6 }
        var rowSpacing: CGFloat { self == .compact ? 2 : 8 }
    }

    let limits: [SessionStatus.Limit]
    let scale: Scale
    let fixedNow: Date?

    public init(limits: [SessionStatus.Limit], scale: Scale = .compact, fixedNow: Date? = nil) {
        self.limits = limits
        self.scale = scale
        self.fixedNow = fixedNow
    }

    public var body: some View {
        if let fixedNow {
            rows(now: fixedNow)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                rows(now: timeline.date)
            }
        }
    }

    private func rows(now: Date) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: scale.rowSpacing) {
            // Server order, capped at three — the header is sized for
            // session / week / per-model week.
            ForEach(Array(limits.prefix(3).enumerated()), id: \.offset) { _, limit in
                GridRow {
                    Text("\(UsageMetersFormat.barLabel(limit.label)):")
                        .gridColumnAlignment(.trailing)
                    bar(for: limit)
                    Text(UsageMetersFormat.resetDisplay(resetsAt: limit.resetsAt, raw: limit.resets, now: now) ?? "")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(for: limit, now: now))
            }
        }
        .font(scale.font)
    }

    private func bar(for limit: SessionStatus.Limit) -> some View {
        let fraction = CGFloat(min(max(limit.percent, 0), 100)) / 100
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12))
            Capsule()
                .fill(UsageMetersFormat.barColor(percent: limit.percent))
                .frame(width: scale.barWidth * fraction)
        }
        .frame(width: scale.barWidth, height: scale.barHeight)
    }

    private func accessibilityText(for limit: SessionStatus.Limit, now: Date) -> String {
        var text = "\(UsageMetersFormat.barLabel(limit.label)), \(limit.percent) percent used"
        if let reset = UsageMetersFormat.resetDisplay(resetsAt: limit.resetsAt, raw: limit.resets, now: now) {
            text += ", resets \(reset)"
        }
        return text
    }
}
```

- [ ] **Step 2: Write the snapshot tests**

Create `MatronShared/Tests/DesignSystemSnapshotTests/UsageMetersSnapshotTests.swift`. Snapshots only use `resetsAt: nil` raw-string fallbacks or a `fixedNow` — countdown/weekday text derived from the real clock would churn the PNGs (that formatting is already unit-tested in Task 4).

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
import MatronModels

final class UsageMetersSnapshotTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)

    private func limit(_ label: String, _ percent: Int, resets: String? = nil, resetsAt: Date? = nil) -> SessionStatus.Limit {
        SessionStatus.Limit(label: label, percent: percent, resets: resets, resetsAt: resetsAt)
    }

    func test_contextGauge() {
        assertVariants(
            of: ContextGaugeLabel(context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27))
                .padding(8),
            named: "context_gauge")
    }

    func test_bars_compact_threeColors() {
        let limits = [
            limit("Session", 39, resetsAt: fixedNow.addingTimeInterval(3 * 3600 + 20 * 60)),
            limit("Week (all models)", 66, resetsAt: fixedNow.addingTimeInterval(2 * 24 * 3600)),
            limit("Week (Fable)", 100, resetsAt: fixedNow.addingTimeInterval(2 * 24 * 3600)),
        ]
        assertVariants(
            of: UsageBarsView(limits: limits, scale: .compact, fixedNow: fixedNow).padding(8),
            named: "bars_compact")
    }

    func test_bars_regular() {
        let limits = [
            limit("Session", 12, resetsAt: fixedNow.addingTimeInterval(45 * 60)),
            limit("Week (all models)", 55, resetsAt: fixedNow.addingTimeInterval(3 * 24 * 3600)),
            limit("Week (Fable)", 81, resetsAt: fixedNow.addingTimeInterval(3 * 24 * 3600)),
        ]
        assertVariants(
            of: UsageBarsView(limits: limits, scale: .regular, fixedNow: fixedNow)
                .padding(12).frame(width: 340),
            named: "bars_regular")
    }

    func test_bars_rawStringFallback() {
        let limits = [limit("Session", 39, resets: "Jul 9, 12:59am (UTC)")]
        assertVariants(
            of: UsageBarsView(limits: limits, scale: .regular, fixedNow: fixedNow)
                .padding(12),
            named: "bars_raw_fallback")
    }
}
```

Note on `fixedNow` in the far-future cases: weekday text ("Sun 8am" etc.) comes from `resetsAt` + the machine's local time zone. If the recorded PNGs would embed a TZ-dependent string, pin the offsets so the assertion is stable on this machine and note it in the test — snapshot baselines here are recorded and verified locally, same as DiffCard's.

- [ ] **Step 3: Record baselines, then verify**

Run the suite once to record (new snapshots auto-record on first run): `swift test --package-path MatronShared --filter UsageMetersSnapshotTests 2>&1 | tail -5`
Expected: first run FAILS with "Record mode"/"No reference" messages and writes PNGs under `__Snapshots__/UsageMetersSnapshotTests/`.
Run again: PASS.
Then OPEN the recorded PNGs and visually verify: label/bar/reset columns aligned, three bar colors correct (green/orange/red), compact scale legible at 9pt, raw fallback string rendered verbatim. Report what you saw.

- [ ] **Step 4: Full SPM suite**

Run: `swift test --package-path MatronShared 2>&1 | tail -5`
Expected: PASS, failures 0; report "Executed N tests".

- [ ] **Step 5: Commit + push (include the recorded PNGs)**

```bash
git add MatronShared/Sources/DesignSystem/UsageMetersView.swift MatronShared/Tests/DesignSystemSnapshotTests/UsageMetersSnapshotTests.swift "MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/UsageMetersSnapshotTests/"
git commit -m "feat(design): UsageMetersView — context gauge + stacked usage bars"
git push
```

---

### Task 6: Apps — Mac header integration + Mac bot-profile removal

**Files:**
- Modify: `MatronMac/Features/Chat/MacChatToolbar.swift`
- Modify: `MatronMac/Features/Chat/MacChatView.swift` (drop `onShowBotProfile`, pass status)
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (drop `botProfileSummary` state + sheet + call-site arg)
- Delete: `MatronMac/Features/BotProfile/MacBotProfileSheet.swift`, `MatronMacTests/MacBotProfileSheetTests.swift`
- Test: `MatronMacTests/MacChatToolbarTests.swift`, `MatronMacTests/MacChatViewTests.swift`

**Interfaces:**
- Consumes: `ChatViewModel.sessionStatus` (Task 3), `ContextGaugeLabel` / `UsageBarsView` `.compact` (Task 5).
- Produces: `MacChatToolbar(title: String, status: SessionStatus?)`; `MacChatView` loses its `onShowBotProfile` parameter.

- [ ] **Step 1: Rewrite MacChatToolbar**

Replace the struct body of `MatronMac/Features/Chat/MacChatToolbar.swift` (keep the file's doc comment, appending a line noting the ⓘ/bot-profile removal in favor of inline meters) with:

```swift
@MainActor
struct MacChatToolbar: ToolbarContent {
    let title: String
    /// Last-known session status for the open convo — context gauge
    /// renders left of the title, usage bars right of it. Nil (no status
    /// frame yet) renders the title alone.
    let status: SessionStatus?

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 14) {
                if let context = status?.context {
                    ContextGaugeLabel(context: context)
                }
                // Horizontal padding so the title doesn't butt against the
                // rounded ends of the macOS 26 glass toolbar-item capsule.
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 10)
                if let limits = status?.limits, !limits.isEmpty {
                    UsageBarsView(limits: limits, scale: .compact)
                }
            }
        }
    }
}
```

Add `import MatronDesignSystem` to the file's imports (`ContextGaugeLabel`/`UsageBarsView` live there); `SessionStatus` comes from the existing `import MatronModels`.

- [ ] **Step 2: Update MacChatView**

In `MatronMac/Features/Chat/MacChatView.swift`: delete the `let onShowBotProfile: () -> Void` property (line ~67) and change the toolbar call (line ~189) to:

```swift
            MacChatToolbar(
                title: chatTitle,
                status: viewModel.sessionStatus
            )
```

- [ ] **Step 3: Update MacChatListView**

In `MatronMac/Features/ChatList/MacChatListView.swift`:
- Delete the `@State private var botProfileSummary: ChatSummary?` declaration and its doc comment (lines ~60-66).
- Delete the entire `.sheet(item: $botProfileSummary) { … }` modifier block (lines ~264-286).
- In `chatDetail(for:)` (line ~467), remove the `onShowBotProfile:` argument from the `MacChatView(...)` call.
- In `MatronMac/Features/Chat/MacEventSourceSheet.swift` (line ~50), a comment cites "`MacBotProfileSheet`'s pattern" for the hidden Esc-dismiss button. Reword it so it doesn't reference the deleted type, e.g.: `// Hidden button so Esc also dismisses the sheet.` (Task 7's repo-wide BotProfile grep must come back empty.)

(`BotProfileViewModel` itself is still used by iOS `BotProfileView` until Task 7 — leave it in place here.)

- [ ] **Step 4: Delete the Mac sheet + its tests, update toolbar/view tests**

```bash
git rm MatronMac/Features/BotProfile/MacBotProfileSheet.swift MatronMacTests/MacBotProfileSheetTests.swift
```

`MatronMacTests/MacChatToolbarTests.swift`: the existing test constructs the toolbar with `onShowBotProfile:` and invokes the closure. Replace that test with:

```swift
    func testToolbarCarriesTitleAndStatus() {
        let status = SessionStatus(
            model: "claude-fable-5",
            context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27),
            limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: nil, resetsAt: nil)])
        let toolbar = MacChatToolbar(title: "Chat", status: status)
        XCTAssertEqual(toolbar.title, "Chat")
        XCTAssertEqual(toolbar.status?.context?.pct, 27)
        XCTAssertEqual(toolbar.status?.limits?.count, 1)

        // Nil status is valid — header renders the title alone.
        XCTAssertNil(MacChatToolbar(title: "Chat", status: nil).status)
    }
```

(Add `import MatronModels` if the file lacks it.) `MatronMacTests/MacChatViewTests.swift` (lines ~120-123): remove the `onShowBotProfile:` argument and the `profileTaps` assertions from the construction test — keep the rest of the test intact.

- [ ] **Step 5: Regenerate, build, run Mac unit tests**

```bash
xcodegen generate
xcodebuild -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' build 2>&1 | tail -3
xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`, then `** TEST SUCCEEDED **` with an "Executed N tests" count — report it. Do NOT commit `MatronMac/App/Info.plist` (or the iOS one) if `git status` shows them dirty — they carry deliberate local-only ATS edits.

- [ ] **Step 6: Commit + push**

```bash
git add MatronMac/Features/Chat/MacChatToolbar.swift MatronMac/Features/Chat/MacChatView.swift MatronMac/Features/ChatList/MacChatListView.swift MatronMacTests/MacChatToolbarTests.swift MatronMacTests/MacChatViewTests.swift
git commit -m "feat(mac): usage/context meters in the chat header; bot-profile sheet removed"
git push
```

(The `git rm`'d files are already staged by `git rm`.)

---

### Task 7: Apps — iOS `SessionStatusSheet` + iOS/shared bot-profile removal + close-out

**Files:**
- Create: `Matron/Features/Chat/SessionStatusSheet.swift`
- Modify: `Matron/Features/Chat/ChatView.swift` (ⓘ presents the sheet locally; drop `onShowBotProfile`)
- Modify: `Matron/Features/ChatList/ChatListView.swift` (drop `botProfileSummary` state + sheet + call-site arg)
- Delete: `Matron/Features/BotProfile/BotProfileView.swift`, `MatronShared/Sources/ViewModels/BotProfileViewModel.swift`, `MatronShared/Tests/ViewModelTests/BotProfileViewModelTests.swift`
- Test: `MatronTests/ChatViewBindingTests.swift`

**Interfaces:**
- Consumes: `ChatViewModel.sessionStatus` (Task 3), `ContextGaugeLabel` / `UsageBarsView` `.regular` (Task 5).
- Produces: `SessionStatusSheet(status: SessionStatus?)`; `ChatView` loses its `onShowBotProfile` parameter.

- [ ] **Step 1: Create the sheet**

Create `Matron/Features/Chat/SessionStatusSheet.swift`:

```swift
import SwiftUI
import MatronModels
import MatronDesignSystem

/// iOS session-status sheet — surfaced from `ChatView`'s ⓘ toolbar button.
/// Shows the context-window gauge and the stacked usage bars from the
/// last journal `status` frame; replaces the old bot-profile sheet.
struct SessionStatusSheet: View {
    let status: SessionStatus?

    private var hasContent: Bool {
        status?.context != nil || !(status?.limits ?? []).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let status, hasContent {
                    VStack(alignment: .leading, spacing: 24) {
                        if let context = status.context {
                            ContextGaugeLabel(context: context)
                        }
                        if let limits = status.limits, !limits.isEmpty {
                            UsageBarsView(limits: limits, scale: .regular)
                        }
                        if let model = status.model {
                            Text(model)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                } else {
                    ContentUnavailableView(
                        "No usage data yet",
                        systemImage: "gauge",
                        description: Text("Appears after the next reply.")
                    )
                }
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
```

- [ ] **Step 2: Rewire ChatView's ⓘ**

In `Matron/Features/Chat/ChatView.swift`:
- Delete `let onShowBotProfile: () -> Void` (line ~71) and update the doc-comment mention of it (line ~15) to describe the session-status sheet instead.
- Add next to the view's other `@State`s:

```swift
    /// ⓘ toolbar button → session-status sheet (context gauge + usage bars).
    @State private var showSessionStatus = false
```

- Change the toolbar button (line ~224) to:

```swift
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSessionStatus = true } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Session status")
            }
```

- Add after the `.toolbar { … }` modifier:

```swift
        .sheet(isPresented: $showSessionStatus) {
            SessionStatusSheet(status: viewModel.sessionStatus)
        }
```

- [ ] **Step 3: Strip ChatListView + delete iOS/shared bot-profile files**

In `Matron/Features/ChatList/ChatListView.swift`:
- Delete `@State private var botProfileSummary: ChatSummary?` and its doc comment (lines ~45-49).
- Delete the whole `.sheet(item: $botProfileSummary) { … }` block (lines ~141-160).
- In `chatDestination(for:)` (line ~368), remove the `onShowBotProfile:` argument from the `ChatView(...)` call.

```bash
git rm Matron/Features/BotProfile/BotProfileView.swift MatronShared/Sources/ViewModels/BotProfileViewModel.swift MatronShared/Tests/ViewModelTests/BotProfileViewModelTests.swift
```

`MatronTests/ChatViewBindingTests.swift` (lines ~57, ~80-85): remove the `onShowBotProfile:` arguments and the `profileTaps` closure-invocation assertions; keep the tests' remaining bindings assertions intact.

- [ ] **Step 4: Regenerate + full verification**

```bash
xcodegen generate
swift test --package-path MatronShared 2>&1 | tail -5
xcodebuild -project Matron.xcodeproj -scheme Matron -destination 'generic/platform=iOS' build 2>&1 | tail -3
xcodebuild -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' build 2>&1 | tail -3
xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MatronTests 2>&1 | tail -15
```

Expected: SPM suite PASS with 0 failures (report "Executed N tests"); both builds `** BUILD SUCCEEDED **`; MatronTests `** TEST SUCCEEDED **` with its executed count. Confirm the deleted-type sweep really is complete: `grep -rn "BotProfile" --include=*.swift Matron MatronMac MatronShared MatronTests MatronMacTests` must return nothing.

- [ ] **Step 5: Commit + push**

```bash
git add Matron/Features/Chat/SessionStatusSheet.swift Matron/Features/Chat/ChatView.swift Matron/Features/ChatList/ChatListView.swift MatronTests/ChatViewBindingTests.swift
git commit -m "feat(ios): session-status sheet behind the header info button; bot profile removed"
git push
```

Do NOT commit either `Info.plist`.

---

## Post-plan (controller close-out, not a task)

Final whole-branch review (both repos), then rebuild `tmp/live-testing` (origin/feat/ask-user-instant-buttons + feat/diff-cards + feat/usage-meters), install to iPhone + /Applications swap, and report to Dan — including that live meters need the bridge PRs (`feat/status-resets-at`, and the already-open `#116`) merged + bridge restarted before status frames carry `resets_at`.
