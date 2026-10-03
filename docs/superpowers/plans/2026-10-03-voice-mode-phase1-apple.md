# Voice mode, phase 1 — Apple apps (iPhone) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dan holds a conversation with an agent on his iPhone without reading: he speaks, the app records a voice note, the agent's reply is spoken back in levels (a short line, a longer version on "more", then the message in sections), he can talk over the reply or tap to interrupt it, answer items and prompts by voice with a read-back, start from a "what needs you" queue, and reach both from Siri ("Start voice mode in Matron", "What needs me in Matron").

**Architecture:** Four stacked PRs. **PR 1 (data and pure logic, Tasks 1–9)** stores the bridge's new `summary` keys (`spoken`, `spoken_more`, `spoken_ref`), adds three store reads, the Markdown cleaner, and a new SwiftPM target `MatronVoice` holding the command and label matchers, the queue's ordering and the engine: a pure reducer `(State, Event) -> (State, [Effect])`. Nothing on screen, no audio. **PR 2 (speaking, Tasks 10–14)** adds `JournalAPI+TTS`, `SpeechPlayer` (cloud clip with on-device fallback and a small cache), earcons, a settings section and a hidden "Speak a reply" list. **PR 3 (listening and the loop, Tasks 15–21)** starts with a spike on a real phone, then adds `VoiceCapture` on `AVAudioEngine` with voice processing and `SpeechAnalyzer`, the effect runner, the store feed, the voice-mode screen and its two entry points. **PR 4 (Siri, Tasks 22–23)** adds two in-app App Intents and their App Shortcuts. The engine imports Foundation only and knows nothing about screens, so the Mac's stage, the spoken notification and CarPlay (later phases) add adapters, not engine changes.

**Tech Stack:** Swift 5.10 language mode, SwiftUI (iOS 18+; voice mode gated `@available(iOS 26, *)`), AVFoundation (`AVAudioEngine`, `AVSpeechSynthesizer`), Speech (`SpeechAnalyzer`, `SpeechDetector`, `SpeechTranscriber`), App Intents, GRDB 6 (`JournalStore`), XCTest, swift-snapshot-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-03-voice-mode-carplay-design.md` — this plan is §13 row 1, the apple part: §3 (engine), §4 (items and prompts by voice), §5 (queue), §6 (iPhone screen), §10 (Siri), with §11 and §12 as rules the engine enforces. NOT in this plan: §7 (spoken notification), §8 (the Mac and the stage), §9 (CarPlay). The bridge and journal plans are written in parallel; this plan uses their contracts exactly as given below.

## Changed during PR 1 review (3 Oct 2026) — apply these when executing Tasks 10 onwards

PR 1 (Tasks 1–9) was built from this plan and then changed in review. The code on `feat/voice-data` is the truth; the task text below was not rewritten. Where a later task quotes something from this list, use the new form.

- **Timers carry a token.** `Effect.startTimer(TimerID, TimeInterval, token: Int)`, `Event.timerFired(TimerID, token: Int)`, `State.timers: [TimerID: Int]`, `State.nextTimerToken`. A firing whose token is not the current one is ignored. Task 18's runner must bind the token in `case .startTimer` and send it back in `.timerFired`; its tests pass `runner.state.timers[.x]`.
- **A confirmation is answered by direction.** `cancel` / `no` count from any `words` event. `yes` needs a `speechStarted` that arrived after the new `confirmGuard` timer (0.3 s, `Config.confirmGuard`, `TimerID.confirmGuard`, `State.confirmOnset`) fired. Any later test that confirms with `words("yes")` must fire the guard and send `speechStarted` first. Entering `confirming` now also emits `startTimer(.confirmGuard, …)`, and leaving it `cancelTimer(.confirmGuard)`.
- **A microphone failure during a pending confirmation drops the send:** error earcon, `VoicePhrases.couldNotHear` ("I couldn't hear you, so I haven't sent that."), then waiting.
- **The hint is "I can go deeper if you like."** (`VoicePhrases.moreHint`), not "Say more for the detail.", and the question between sections is **"Keep going?"**, not "Go on?" — the Global Constraints "Copy, verbatim" line, Task 19's snapshot caption and every expected string in later tests change with them. No fixed phrase may contain a command phrasing; a test walks every phrase against every phrasing. "the detail", "give me the detail", "details", "go into detail" and "what's the detail" parse as `more`.
- **A clear label match beats a command word** ("skip please" with a Skip label presses Skip).
- **The "Sending: X" window is held open while Dan is speaking** when its timer fires: up to two 1.5 s extensions before it commits.
- **Test counts moved.** `VoiceModeEngineTests` and `VoiceTests` are larger than Tasks 9, 14 and 21 say. Take the count from a run on the parent branch before starting each PR, add the tests the PR adds, and assert that.
- **Bridge wording.** The `SPOKEN` / `SPOKEN_MORE` prompt was reworded (first person); see the spec. Nothing in the app depends on the wording.

## Changed during PR 2 (3 Oct 2026) — apply these when executing Tasks 15 onwards

PR 2 (Tasks 10–14) was built from this plan and changed in the building and in review. The code on `feat/voice-speaking` is the truth.

- **`SpeechPlayer.fetch` is not a task group.** The request and the two-second clock post to one stream and the first to post wins; `stop()` and the next `speak` post too. A stopped or overtaken line returns `.stopped` at once, without waiting for the journal. Task 18's runner can rely on `await player.speak(…)` returning promptly after `player.stop()`.
- **An empty or whitespace-only line returns `.stopped`** and says nothing.
- **Length is counted in UTF-16 units** (`text.utf16.count <= JournalAPI.ttsTextLimit`), as the journal counts it.
- **A clip is cached only under a known voice id** (the user's choice or the journal's default from `GET /tts/voices`). Call `refreshVoices()` when voice mode opens, before the first fixed phrase, or that phrase is fetched again next time.
- **`SynthesizerLocalVoice.utteranceRate(_:)`** maps the setting to the synthesizer's scale (each 0.1 of the setting is 0.02 of rate). It is a guess until Task 14 Step 6 is done on a phone.
- **The "Speak a reply" list does nothing while a voice note is being recorded** and only deactivates an audio session it activated itself. Task 16's capture must make the same check before it takes the session.
- **Not done:** Task 13 Step 9 and Task 14 Step 6 (both need a phone). Do them with the Task 15 spike.
- **Test counts:** `VoiceTests` is 143 after PR 2; the iOS bundle is 465.

## Changed while building Task 15 (3 Oct 2026) — apply these when executing Tasks 16 onwards

Task 15's code (Steps 1–8) was merged on its own, ahead of the rest of PR 3, so that the spike (Steps 9–10) can be run from a build of `main`. The code is the truth.

- **`CaptureCore.fileSettings(for:)`.** `AVAudioFile(forWriting:)` refuses AAC at 64 kbit/s below 22.05 kHz, so over a hands-free Bluetooth microphone (8 or 16 kHz) the plan's file never opened and nothing would have been recorded. The bit rate is now asked for only at 22.05 kHz and above.
- **`EngineLocalVoice.stop()` abandons a line still being rendered** (`RenderedSpeech.abandon()`), so `speak` returns at once.
- **`VoiceAudioSession.release()` only deactivates a session it activated;** a second `release()` is harmless.
- **The spike screen** refuses to run while a voice note is being recorded, stops and gives the session back when it disappears, keeps the screen awake during a run, and waits 20 s (not 2 s) for the cloud clip.
- **Open, for Tasks 18 and 20:** `VoiceAudioEngine.configure()` runs once, so the tap's format is stale after a route change (AirPods in or out); `SpeechListener.make` runs on every `capture.start`, with no timeout on a model download; `VoiceAudioEngine.play` throwing is swallowed by `EngineLocalVoice`, so `SpeechPlayer` can report `.onDevice` when nothing was said. The spike never records (`.monitor`, `keep: false`): `.record`, `promote()` and the file first run on a phone in Task 18.
- **Test counts:** `VoiceTests` is 153 after Task 15.

## Global Constraints

- **`summary` event payload** (bridge): optional keys `spoken` (≤400 characters), `spoken_more` (≤1,200 characters, may be absent), `spoken_ref`. `spoken` and `spoken_ref` are sent together or not at all; `spoken_more` only ever with them. Both spoken strings are single lines. `spoken_ref` equals `payload.message_ref` of a `text` event published earlier in the same conversation: the FIRST chunk of the agent's last reply covered by that summary (a long reply is several `text` events and only the first carries the ref; bridge notices and tool-call lists carry none). A summary can land after a newer reply has been published: a spoken line is used only when its `spoken_ref` is the `message_ref` of the newest agent reply. No spoken keys at all happens with no summary key on the box, an old bridge, a model that omitted `SPOKEN`, a turn with no assistant message, or a bridge restart mid-session: the app waits up to four seconds after the turn ends, then falls back to the cleaner. Old rows read `nil`.
- **`message_ref` needs no schema change:** `EventRecord.payload` stores every payload whole (`JournalStore.swift:170-197`), and `JournalTimelineService` already reads `payload["message_ref"]` off stored `text` rows (`JournalTimelineService.swift:131`). Task 2's store read does the same.
- **`POST /tts`** body `{text (1..2000 chars), voice?, format? ("mp3" default | "wav")}` → 200 audio bytes (`audio/mpeg`) with an `ETag` (the SHA-256 of the audio; the journal does not act on `If-None-Match`, so the phone caches by its own key of voice + text, never by revalidation). Errors `{error}`: 400 `bad_request` / `unknown_voice`, 403 (agents), 413, 429 `tts_budget_exceeded`, 501 `tts_unconfigured`, 502 `tts_failed`, 503 `tts_busy` (with `Retry-After: 1`); an old journal answers 404. **Rule: ANY non-200, a network error, or no audio within two seconds → say the same text with the on-device voice.**
- **`GET /tts/voices`** → `{voices: [{id, name, locale, gender}], default}`. Voice ids `en-GB-Harry`, `en-GB-Emily`. ONLY a 404 or 501 from this route is remembered for the session as "this journal has no cloud voice"; every other failure is forgotten and asked again.
- **Existing routes used as they are:** `POST /media` (raw body) → `{media_id, …}` (`JournalAPI.uploadMedia`, `JournalAPI.swift:417`); `GET /media/:id/transcript?wait=N` → `{status: none|pending|done|failed, transcript?}`, `wait` ≤ 30 s (matron-journal `src/http.js`, the `/transcript` route; the apps have never called it, Task 16 adds the client); item answers `POST /items/:id/comments {body, action?}` through the item outbox (`ItemsSync.enqueueComment`, as `ItemDetailViewModel.chooseAction` at `ItemDetailViewModel.swift:633`); prompt answers through the `prompt_reply` WebSocket op (`ClientOp.promptReply`, sent by `JournalTimelineService` at lines 716–754); turn end = `session_status` state `waiting` (`JournalStore.sessionStateStream`, `JournalStore.swift:2231`).
- **A tool-permission prompt is a `prompt` event, not a `permission_request` event.** The bridge sends it through `sendButtonMessage` with three buttons whose values are `perm:<uuid>:allow`, `perm:<uuid>:always`, `perm:<uuid>:deny` and labels `Allow once`, `Always allow <tool> (session)`, `Deny` (matron-bridge `lib/permission-prompt.js`, `permissionButtons`); its text is `🔐 Permission: Claude wants to run <tool>` plus a preview. The `permission_request` journal type carries agent-chat and agent-spawn consent cards (`JournalTimelineMapper.swift:114-151`), which need the screen. This plan recognises a permission prompt by its button values.
- **Timings, verbatim from the spec:** end of speech 1.5 s of silence; microphone closes after 8 s of nothing; an utterance is cut at 2 minutes; transcript wait 8 s; summary wait 4 s; "Sending: Go" cancel window 3 s; talk-over: 300 ms of speech ducks the clip, a word within 1 s stops it; idle end 30 minutes; permission prompts are denied after 5 minutes.
- **Copy, verbatim:** `Sending: <label>.` / `Did you mean <label>?` / `Sent.` / `Say more for the detail.` / `Go on?` / `That one needs the screen. It's in your tracker.` / `No connection. I'll send it when you're back online.` / `<box> is busy. It will get this when it finishes.` / `That permission request timed out and was denied.` / `<n> things need you.` Settings: `Talk over the agent`. Every fixed line lives in `VoicePhrases` (Task 6).
- **The engine target never imports UIKit, AppKit or SwiftUI.** `MatronVoice` depends on `MatronModels`, `MatronEvents`, `MatronJournal`, `MatronChat` only. The Markdown cleaner lives in `MatronDesignSystem` (beside the parse it shares) and is handed to the engine's feed as closures (`VoiceTextMaker`).
- **Everything in `MatronShared` must compile for macOS** (the package's tests run on the Mac host): `AVAudioSession` only inside `#if os(iOS)`, Speech APIs behind `@available(iOS 26, macOS 26, *)`.
- Run `xcodegen generate` after adding, renaming or deleting any file or folder (snapshot PNGs are project members), then `git checkout Matron/App/Info.plist` (xcodegen adds an unwanted `audio` entry to `UIBackgroundModes`; the checked-in plist is generated and that hunk is never committed). `Matron.xcodeproj` is git-ignored. The ONE exception is Task 15, which adds a key to `project.yml` and commits exactly that key's two lines in `Info.plist` (the step says how).
- Shared tests: `cd MatronShared && swift test --filter <Target>.<Class>`. Full suite: `swift test --package-path MatronShared --skip test_fileLog` (`ChatViewModelTests.test_fileLog_appendsTimestampedLines_withSessionHeader` hangs for ever on build-mac). `swift test` can also hang at 0% CPU — kill it and rerun. Snapshots record on first run (run twice: the first records and fails, the second passes), then `xcodegen generate`. `MATRON_SKIP_SNAPSHOT_TESTS=1` skips snapshot assertions when a step only needs logic tests. With that variable set, these fail on untouched `main` and are not regressions: `ItemTypographyRenderTests` (3), `MarkdownAttributedFingerprintTests`, `MarkdownCodeBlockBoxTests.test_boxPaintsContinuouslyOnScreen`, `MessageCopyTextViewOnScreenTests` (1), `MessageThemeRenderTests` (1).
- Timing in tests: `Task.sleep` under a test host is coarse (20 ms can take 150). No test in this plan asserts on a fixed delay; they wait on a condition (`waitUntil`) or send `timerFired` by hand.
- iOS tests on an **iPhone 17** simulator (there is no iPhone 16 here): `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath build/ios-test -only-testing:MatronTests/<Class> CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`. **Assert the `Executed N tests, with 0 failures` line with the expected N.** A test file added after the last `xcodegen generate` is not in the project: the run then says `Executed 0 tests` and `** TEST SUCCEEDED **`, which is not a pass. `TextMessageCellTests.test_pillsRow_staysPut_whenTheCellSitsInASafeArea` fails on untouched `main`.
- This plan adds no Mac UI, but two shared files the Mac uses change (`VoiceNoteSession`, the `MatronDesignSystem` target). Mac tests ONLY with the store override as a real environment variable: `env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/mac-test -only-testing:MatronMacTests`. NEVER a trailing `KEY=value` argument and never without the override — the test host can wipe the live journal store.
- Give each `xcodebuild` its own `-derivedDataPath`. Do not pass `-quiet` to `xcodebuild build` here (it prints a bogus error on success); grep for `BUILD SUCCEEDED`.
- Commits: `git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit -m "<subject>" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`. Never `git config` anything (worktrees share `.git/config`).
- CI's type-checker budget is far smaller than local: keep SwiftUI bodies in small computed views / `@ViewBuilder` helpers; every new branch in `AppShellView` goes in a hoisted helper, never inline in `body`.
- iOS List/ScrollView `Button` labels inherit the accent tint — reset with `.foregroundStyle(Color.primary)`.
- The real-device steps (Task 14 Step 6, Task 15, Task 21) need an iPhone on iOS 26 or later: the simulator has no loudspeaker-to-microphone path and cannot judge a voice. Signed builds on build-mac need the signing keychain unlocked first.

## Review Focus

- **A cache coming up from schema v6 or below with `summary` events in it.** Migration v7 backfills `summary_entry` with `SummaryEntryRecord.insert`; once the record gains three columns that insert names columns that do not exist until the last migration, and the store fails to open. Pinned by two existing tests that go red in Task 1 Step 4 (`testMigrationBackfillsSummaryEntriesFromStoredEvents`, `testMigrationBackfillLeavesLiveWrittenEntriesAlone`) and green again when v7 spells its insert out.
- **A summary that lands after a newer reply.** Its line describes the older reply and must not be said for the newest one. Pinned in Task 2 (`testALateSummaryForAnOlderReplyIsNotUsedForTheNewestOne`) and Task 17 (`testALateSummaryForAnOlderReplyIsIgnored`).
- **A long reply split into several `text` rows.** Only the first carries the `message_ref`; the cleaner's fallback must read all of it, and a later chunk must not be taken for a new reply. Pinned in Task 2 (`testALongReplyIsReadAcrossItsChunks`).
- **The agent's own voice coming back through the microphone.** Words that are the clip's own must not stop the clip, and three false starts inside one clip switch talking-over off for that audio route. Pinned in Task 8 (`testTheClipsOwnWordsDoNotInterruptIt`, `testRepeatedSelfTriggersSwitchTalkingOverOffForTheRoute`); whether it happens at all on real hardware is Task 15's spike.
- **Allowing a tool by mistake.** A permission prompt always asks "Did you mean Allow once?" whatever was heard, and sends only on "yes"; "deny" needs no confirmation. Pinned in Task 8 (`testAllowingAPermissionAlwaysAsksFirst`, `testDenyingAPermissionNeedsNoConfirmation`).
- **One word said over a clip ("stop").** The detector can report the end of speech before the recogniser reports the word; the engine must still end the utterance rather than wait two minutes. Pinned in Task 8 (`testAOneWordInterruptionAfterSpeechHasEnded`).

## Decisions this plan makes (the spec left them open)

1. **A new SwiftPM target, `MatronVoice`,** rather than more files in `MatronViewModels` (where `VoiceRecorder` lives and imports UIKit).
2. **The cleaner lives in `MatronDesignSystem`** (`SpeechCleaner`), reusing `MarkdownSource.prepared`, `BlockKind` and `MatronItemLink.itemNumber`, and reaches the engine as closures. A code block says "There's code in the chat." and a `diff` block "There's a diff in the chat." (the spec names a sentence only for tables).
3. **The migration is named `summary_spoken`, not `v17`,** following `event_convo_type` (`JournalStore.swift:755-762`: open branches already claim numbers). No backfill from stored events: only the newest turn is ever spoken.
4. **`SummaryEntryRecord` still requires a non-empty `toc`.** The bridge publishes a summary only when `toc` is non-empty (matron-bridge `index.js`, `if (toc) { journalPublish(session, 'publishSummary', …`), so a spoken line never arrives without one.
5. **A prompt is "pending"** when it is a `prompt` row from an agent, is not a `queued_release` card, no `prompt_reply` of the user's targets it, the user has sent nothing to that conversation after it, the conversation is not hidden or `done`, and it is younger than 5 minutes (permission) or 24 hours (ask-user). The app has no cross-conversation pending-prompt index today (`ChatViewModel.pendingAsk()` is per open chat, `ChatViewModel.swift:2236`).
6. **"Tracker order" is `rank`, then `num`** (`JournalStore.itemsRequest`), not the Decisions tab's newest-first.
7. **"A reply he has not seen"** is a visible top-level conversation with `unreadCount > 0`, whose session is not `running`, that is not muted and has no pending prompt already in the queue; newest activity first.
8. **A command is also looked for in the journal's transcript,** not only the on-device words (the recogniser may be unavailable or wrong), and a command needs 0.6 s of silence rather than 1.5 s. `yes` and `no` are commands only to a question the engine asked ("Go on?", a confirmation). A label wins over a command word (an item may offer "Skip").
9. **Talking over a confirmation** ("Sending: Go") with anything but "yes" or "cancel" drops the send and treats what was said as a new utterance. A tap on a label button sends at once with no read-back, for permissions too (a tap is not a mis-hearing).
10. **Anything other than allow / always / deny said to a permission prompt** is not sent as free text; the engine says "Say allow or deny." and listens again.
11. **False starts are counted per clip** (three inside one clip switch talking-over off for the route), and both "speech without words" and "the clip's own words" count.
12. **Pausing** (a call, Siri, the app leaving the front) discards an utterance in progress; a send already uploading still goes, silently. Ending voice mode mid-send sends what was said as a plain voice note.
13. **In a conversation, items already awaiting Dan when voice mode opens are not read out**; a pending prompt there is, and items that start awaiting him afterwards are.
14. **Voice mode's recordings are AAC `.m4a` at the microphone's own sample rate** (whatever voice processing runs at), not resampled to `VoiceRecorder`'s 44.1 kHz.
15. **Earcons are synthesised** (`EarconSynth`, two sine notes each) rather than shipped as audio files.
16. **The hidden debug list** is reachable on a TestFlight build by a long press on the settings section's title (`MatronDebug` is off in Release and cannot be flipped on a phone).
17. **`AppDependencies.live`,** a process-wide instance, so the Siri intent that runs with no window reads the same journal mirror. "What needs me" answers from the local mirror without syncing first.
18. **The app shell's entry point** is a `waveform` button on the Conversations and Decisions roots; voice mode is one `fullScreenCover` on the shell, so every entry point (and Siri) presents through one place.

---

## File map

| File | Task | Responsibility |
|---|---|---|
| `MatronShared/Sources/Journal/JournalStore.swift` | 1, 2 | `SummaryEntryRecord.spoken/spokenMore/spokenRef`; migration `summary_spoken`; v7 insert spelled out; `ownSender` module-internal |
| `MatronShared/Sources/Journal/JournalStore+Voice.swift` (new) | 2 | `lastAgentReply`, `spokenSummary`, `unansweredPrompts` |
| `MatronShared/Sources/DesignSystem/SpeechCleaner.swift` (new) | 3 | Markdown → speakable text, fallback short form, sections |
| `MatronShared/Package.swift` | 4 | `MatronVoice` target and `VoiceTests` |
| `MatronShared/Sources/Voice/VoiceCommand.swift` (new) | 4 | `VoiceCommand`, `VoiceText` |
| `MatronShared/Sources/Voice/ActionLabelMatcher.swift` (new) | 5 | Labels and permission verdicts |
| `MatronShared/Sources/Voice/VoiceTypes.swift`, `VoicePhrases.swift` (new) | 6 | `SpokenReply`, `VoiceItem`, `VoicePrompt`, `VoiceEntry`; every fixed line |
| `MatronShared/Sources/Voice/NeedsYouQueue.swift` (new) | 7 | Queue ordering, Siri's summary, the store adapter |
| `MatronShared/Sources/Voice/VoiceModeEngine.swift` (new) | 8 | The reducer |
| `MatronShared/Sources/Journal/JournalAPI.swift`, `JournalAPI+TTS.swift` (new) | 10 | `rawRequest` internal; `ttsVoices()`, `tts(text:voice:)` |
| `MatronShared/Sources/Voice/SpeechClipCache.swift`, `EarconSynth.swift`, `VoiceSettings.swift` (new) | 11 | Fixed-phrase cache, earcons, settings |
| `MatronShared/Sources/Voice/SpeechPlayer.swift`, `SystemVoiceOutputs.swift` (new) | 12 | Cloud clip with on-device fallback; `AVAudioPlayer` and `AVSpeechSynthesizer` outputs |
| `project.yml` | 13, 15 | `MatronVoice` product on `Matron` and `MatronTests`; `NSSpeechRecognitionUsageDescription` |
| `Matron/App/AppDependencies.swift` | 13, 20, 22 | `speechSynthesiser(for:)`, `voiceSender(for:)`, `AppDependencies.live` |
| `Matron/App/AppShellView.swift` | 13, 20, 23 | `VoiceSettings` in the environment; the cover and the opener; the Siri hand-off |
| `Matron/Features/Voice/VoiceSettingsSection.swift` (new), `Matron/Features/Settings/DeviceSettingsView.swift` | 13 | Settings ▸ Voice mode |
| `Matron/Features/Voice/VoiceDebugView.swift` (new), `Matron/Features/Chat/SessionStatusSheet.swift` | 14 | "Speak a reply" |
| `MatronShared/Sources/Voice/VoiceModeSeams.swift`, `VoiceAudioEngine.swift`, `VoiceAudioSession.swift`, `VoiceCapture.swift` (new) | 15 | The engine's protocols; `AVAudioEngine` with voice processing; the audio session; capture and `SpeechAnalyzer` |
| `Matron/Features/Voice/VoiceSpikeView.swift` (new, deleted in Task 21) | 15 | The throwaway spike screen |
| `MatronShared/Sources/Journal/JournalAPI+Transcript.swift`, `Sources/Voice/JournalVoiceSender.swift` (new) | 16 | `mediaTranscript`; uploads and sends |
| `MatronShared/Sources/Voice/JournalVoiceFeed.swift` (new) | 17 | Turn ends, the four-second summary wait, prompts and items arriving |
| `MatronShared/Sources/Voice/VoiceModeRunner.swift` (new) | 18 | Carries out effects |
| `MatronShared/Sources/DesignSystem/Voice/VoiceModeScreen.swift` (new) | 19 | The screen, as a plain view over a plain model |
| `Matron/Features/Voice/VoiceModeEntry.swift`, `VoiceTextMaker+Cleaner.swift`, `VoiceModeHost.swift` (new) | 20 | Entry, availability, the host and its session |
| `Matron/App/AppShellNavigation.swift`, `Matron/Features/ChatList/ChatListView.swift`, `Matron/Features/Chat/ChatView.swift` | 20 | `voiceMode`; the two buttons |
| `MatronShared/Sources/ViewModels/VoiceNoteSession.swift` | 20 | No ordinary voice note while voice mode is on |
| `manual-tests.md` | 21 | Voice mode checks |
| `Matron/Features/Voice/Intents/VoiceIntents.swift`, `VoiceModeLaunchInbox.swift` (new), `Matron/App/MatronApp.swift` | 22, 23 | The two intents, their shortcuts, the hand-off to the shell |

## PR split

| PR | Branch | Tasks | Stacks on |
|---|---|---|---|
| 1 — data and pure logic | `feat/voice-data` | 1–9 | `main` |
| 2 — speaking | `feat/voice-speaking` | 10–14 | PR 1 |
| 3 — listening and the loop | `feat/voice-loop` | 15–21 | PR 2 |
| 4 — Siri | `feat/voice-siri` | 22–23 | PR 3 |

Work in a fresh worktree per PR (`git worktree add ../matron-apple-voice-<n> -b <branch> <base>`); never branch-switch a tree someone else is using. When a parent PR merges with `--delete-branch`, retarget its children to `main` first. Each PR ships by itself: PR 1 changes nothing a user sees; PR 2 adds a settings section and a hidden list; PR 3 adds voice mode; PR 4 adds the shortcuts.

---

# PR 1 — data and pure logic

Branch: `git worktree add ../matron-apple-voice-1 -b feat/voice-data origin/main`.

### Task 1: The `summary` event's spoken lines — record, migration, and the v7 trap

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (`SummaryEntryRecord` at lines 251–277; the v7 migration at 486–494; after `event_convo_type` at 760–762)
- Test: `MatronShared/Tests/JournalTests/JournalStoreVoiceTests.swift` (new)

**Interfaces:**
- Produces: `SummaryEntryRecord.spoken: String?`, `.spokenMore: String?`, `.spokenRef: String?`; `SummaryEntryRecord.spokenLimit` (400), `.spokenMoreLimit` (1,200); columns `summary_entry.spoken`, `spoken_more`, `spoken_ref`; migration `summary_spoken`.
- Unchanged: `init?(event:)` still returns `nil` without a non-empty `toc` (Decision 4); `summaryEntries(convoID:)` and `summaryEntriesStream(convoID:)` return the new fields with no change of their own.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/JournalTests/JournalStoreVoiceTests.swift`:

```swift
import GRDB
import XCTest
@testable import MatronJournal
import MatronModels

/// Voice mode's store reads and the `summary` spoken fields (spec
/// 2026-10-03 §1, §3, §5).
final class JournalStoreVoiceTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    private func event(_ seq: Int64, convo: String = "c1", sender: String = "agent:bev",
                       type: String = "text", ts: TimeInterval? = nil,
                       payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: ts ?? Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    // MARK: summary spoken fields

    func testSummaryDecodesTheSpokenLines() throws {
        let entry = try XCTUnwrap(SummaryEntryRecord(event: event(5, type: "summary", payload: [
            "toc": "Deploy finished", "detail": "All green.", "model": "gpt",
            "spoken": "  The deploy finished. Shall I merge?  ",
            "spoken_more": "Every test passed and the cache was rebuilt.",
            "spoken_ref": "msg_9",
        ])))
        XCTAssertEqual(entry.spoken, "The deploy finished. Shall I merge?")
        XCTAssertEqual(entry.spokenMore, "Every test passed and the cache was rebuilt.")
        XCTAssertEqual(entry.spokenRef, "msg_9")
    }

    /// An old bridge sends none of the keys; a new one omits `spoken_more`
    /// when the model wrote NONE. Null, blank and non-strings read as nil.
    func testAbsentBlankAndNoneReadAsNil() throws {
        let old = try XCTUnwrap(SummaryEntryRecord(event: event(5, type: "summary", payload: ["toc": "T", "detail": "D"])))
        XCTAssertNil(old.spoken); XCTAssertNil(old.spokenMore); XCTAssertNil(old.spokenRef)
        let odd = try XCTUnwrap(SummaryEntryRecord(event: event(6, type: "summary", payload: [
            "toc": "T", "spoken": "   ", "spoken_more": "NONE", "spoken_ref": NSNull(),
        ])))
        XCTAssertNil(odd.spoken); XCTAssertNil(odd.spokenMore); XCTAssertNil(odd.spokenRef)
        let wrong = try XCTUnwrap(SummaryEntryRecord(event: event(7, type: "summary", payload: ["toc": "T", "spoken": 12])))
        XCTAssertNil(wrong.spoken)
    }

    func testSpokenLinesAreCutToTheContractCaps() throws {
        let entry = try XCTUnwrap(SummaryEntryRecord(event: event(5, type: "summary", payload: [
            "toc": "T", "spoken": String(repeating: "a", count: 500), "spoken_more": String(repeating: "b", count: 1_500),
        ])))
        XCTAssertEqual(entry.spoken?.count, 400)
        XCTAssertEqual(entry.spokenMore?.count, 1_200)
    }

    /// The migration is additive: a cache from before it keeps its rows,
    /// which read nil for the three new columns.
    func testSummarySpokenMigratesUpAndOldRowsReadNil() throws {
        let queue = try DatabaseQueue()
        try JournalStore.migrator().migrate(queue, upTo: "event_convo_type")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO summary_entry(convo_id, seq, toc, detail, created_at) VALUES('c1', 4, 'Old', 'row', 1000)
                """)
        }
        try JournalStore.migrator().migrate(queue)
        try queue.read { db in
            let old = try XCTUnwrap(SummaryEntryRecord.fetchOne(db, sql: "SELECT * FROM summary_entry"))
            XCTAssertEqual(old.toc, "Old")
            XCTAssertNil(old.spoken); XCTAssertNil(old.spokenMore); XCTAssertNil(old.spokenRef)
            let columns = try db.columns(in: "summary_entry").map(\.name)
            XCTAssertTrue(columns.contains("spoken")); XCTAssertTrue(columns.contains("spoken_more"))
            XCTAssertTrue(columns.contains("spoken_ref"))
        }
    }

    func testSpokenLinesSurviveTheLiveApplyAndHistoryPaths() throws {
        let store = try makeStore()
        _ = try store.applyJournal(event(2, type: "summary", payload: ["toc": "Live", "spoken": "Live line.", "spoken_ref": "m2"]))
        try store.insertHistory([event(1, type: "summary", payload: ["toc": "Old", "spoken": "Old line."])])
        let entries = try store.summaryEntries(convoID: "c1")
        XCTAssertEqual(entries.map(\.spoken), ["Live line.", "Old line."])
        XCTAssertEqual(entries.first?.spokenRef, "m2")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.JournalStoreVoiceTests'`
Expected: build FAILS — `value of type 'SummaryEntryRecord' has no member 'spoken'`.

- [ ] **Step 3: Add the fields and the migration**

In `JournalStore.swift`, replace the body of `SummaryEntryRecord` from `public var createdAt: Int64` to the end of the struct with:

```swift
    /// Milliseconds since epoch, like every other Int64 timestamp column in this store.
    public var createdAt: Int64
    /// What voice mode says when the turn ends (spec 2026-10-03 §1): at
    /// most 400 characters. `nil` from an old bridge, a box with no summary
    /// key, or a row stored before the `summary_spoken` migration.
    public var spoken: String?
    /// What "more" says, at most 1,200 characters; `nil` when the bridge
    /// had nothing to add.
    public var spokenMore: String?
    /// The `message_ref` of the turn's last assistant `text` event: which
    /// reply `spoken` belongs to.
    public var spokenRef: String?

    public static let spokenLimit = 400
    public static let spokenMoreLimit = 1_200

    enum CodingKeys: String, CodingKey {
        case convoID = "convo_id", seq, toc, detail, createdAt = "created_at"
        case spoken, spokenMore = "spoken_more", spokenRef = "spoken_ref"
    }

    public init?(event: JournalEvent) {
        guard event.type == JournalEventType.summary,
              let obj = try? JSONSerialization.jsonObject(with: event.payloadData) as? [String: Any],
              let toc = obj["toc"] as? String, !toc.isEmpty
        else { return nil }
        self.convoID = event.convoID
        self.seq = event.seq
        self.toc = toc
        self.detail = obj["detail"] as? String ?? ""
        self.createdAt = Int64(event.ts.timeIntervalSince1970 * 1000)
        self.spoken = Self.spokenText(obj["spoken"], limit: Self.spokenLimit)
        self.spokenMore = Self.spokenText(obj["spoken_more"], limit: Self.spokenMoreLimit)
        self.spokenRef = (obj["spoken_ref"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A spoken line off the wire: trimmed, cut to the contract's cap, and
    /// `nil` for anything that is not words (absent, null, a non-string,
    /// blank, or the summary pass's literal `NONE`).
    static func spokenText(_ raw: Any?, limit: Int) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != "NONE" else { return nil }
        return String(text.prefix(limit))
    }
}
```

In `JournalStore.migrator()`, directly after the `event_convo_type` registration and before `return migrator`:

```swift
        // Voice mode (spec 2026-10-03 §1): the spoken lines the bridge's
        // summary pass writes. Additive and nullable: rows stored before
        // this read nil and voice mode falls back to the cleaner for those
        // turns. No backfill: only the newest turn is ever spoken. Named,
        // not numbered, for the same reason as `event_convo_type`.
        migrator.registerMigration("summary_spoken") { db in
            try Self.addColumnIfMissing(db, table: "summary_entry", column: "spoken", .text)
            try Self.addColumnIfMissing(db, table: "summary_entry", column: "spoken_more", .text)
            try Self.addColumnIfMissing(db, table: "summary_entry", column: "spoken_ref", .text)
        }
```

- [ ] **Step 4: Run, and see the v7 trap**

Run: `cd MatronShared && swift test --filter 'JournalTests.(JournalStoreVoiceTests|JournalStoreTests)'`
Expected: `JournalStoreVoiceTests` passes (5 tests) and two EXISTING tests in `JournalStoreTests` FAIL — `testMigrationBackfillsSummaryEntriesFromStoredEvents` and `testMigrationBackfillLeavesLiveWrittenEntriesAlone` — with `table summary_entry has no column named spoken`. Migration v7 inserts through the record type, which now names columns that do not exist until `summary_spoken` runs: a real upgrade from v6 or below would fail to open the store.

- [ ] **Step 5: Spell out v7's insert**

In the `v7` registration, replace `try entry.insert(db, onConflict: .ignore)` (line 492; NOT the two live-path inserts at 1240 and 1479, which are correct) with:

```swift
                // Spelled out, not `entry.insert`: the record has since
                // gained the `summary_spoken` columns, which do not exist
                // yet when v7 runs on a cache coming up from v6 or below.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO summary_entry(convo_id, seq, toc, detail, created_at)
                    VALUES(?, ?, ?, ?, ?)
                    """, arguments: [entry.convoID, entry.seq, entry.toc, entry.detail, entry.createdAt])
```

- [ ] **Step 6: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.(JournalStoreVoiceTests|JournalStoreTests|JournalStoreMigrationIdempotenceTests)'`
Expected: `Executed 5 tests` (voice), `Executed 81 tests` (store), `Executed 2 tests` (idempotence), all with 0 failures.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore.swift MatronShared/Tests/JournalTests/JournalStoreVoiceTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: store the summary event's spoken lines (migration summary_spoken)" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Store reads — the newest reply, its spoken summary, unanswered prompts

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (line 288, `private let ownSender`)
- Create: `MatronShared/Sources/Journal/JournalStore+Voice.swift`
- Test: `MatronShared/Tests/JournalTests/JournalStoreVoiceTests.swift`

**Interfaces:**
- Consumes: Task 1's columns; `EventRecord`, `ConversationRecord`, the `event_type_ts` and `event_convo_type` indexes.
- Produces (MatronJournal):
  - `struct AgentReplyRow { seq: Int64; messageRef: String?; body: String }`.
  - `struct UnansweredPromptRow { event: JournalEvent; convoTitle: String; agentName: String? }`.
  - `JournalStore.lastAgentReply(convoID:afterSeq:) throws -> AgentReplyRow?`.
  - `JournalStore.spokenSummary(convoID:for:) throws -> SummaryEntryRecord?` — by `spoken_ref` only.
  - `JournalStore.unansweredPrompts(since:) throws -> [UnansweredPromptRow]`.

- [ ] **Step 1: Write the failing tests**

In `JournalStoreVoiceTests.swift`, insert before the class's closing brace:

```swift
    // MARK: lastAgentReply / spokenSummary

    func testLastAgentReplyIsTheNewestReferencedTextAboveTheFloor() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "first", "message_ref": "m1"]),
            event(2, sender: "user:dan", payload: ["body": "my question"]),
            event(3, payload: ["body": "thinking out loud", "message_ref": "m3"]),
            event(4, type: "tool_output", payload: ["command": "ls"]),
            event(5, payload: ["body": "the answer", "message_ref": "m5"]),
            event(6, payload: ["body": "mirror of an item", "fallback_for": "item"]),
            event(7, type: "session_status", payload: ["state": "waiting"]),
        ])
        XCTAssertEqual(try store.lastAgentReply(convoID: "c1"),
                       AgentReplyRow(seq: 5, messageRef: "m5", body: "the answer"))
        XCTAssertEqual(try store.lastAgentReply(convoID: "c1", afterSeq: 2)?.seq, 5)
        XCTAssertNil(try store.lastAgentReply(convoID: "c1", afterSeq: 5), "nothing new since the reply already heard")
        XCTAssertNil(try store.lastAgentReply(convoID: "other"))
    }

    /// A long reply is several `text` rows; only the first carries the
    /// ref. The body is all of them. A bridge notice after the turn ended,
    /// or text after a tool call, is not part of it.
    func testALongReplyIsReadAcrossItsChunks() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "Part one.", "message_ref": "m1"]),
            event(2, payload: ["body": "Part two."]),
            event(3, sender: "user:dan", type: "read_marker", payload: ["up_to_seq": 2]),
            event(4, payload: ["body": "Part three."]),
            event(5, type: "session_status", payload: ["state": "waiting"]),
            event(6, payload: ["body": "✅ Always allowing Bash for this session."]),
        ])
        XCTAssertEqual(try store.lastAgentReply(convoID: "c1"),
                       AgentReplyRow(seq: 1, messageRef: "m1", body: "Part one.\n\nPart two.\n\nPart three."))
    }

    /// A bridge that sends no ref on an unstreamed reply: the newest
    /// assistant text stands alone, and has no spoken summary.
    func testAReplyWithoutARefIsTheNewestAssistantText() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "older"]),
            event(2, payload: ["body": "newer"]),
            event(3, type: "summary", payload: ["toc": "T", "spoken": "Line.", "spoken_ref": "m9"]),
        ])
        let reply = try XCTUnwrap(try store.lastAgentReply(convoID: "c1"))
        XCTAssertEqual(reply, AgentReplyRow(seq: 2, messageRef: nil, body: "newer"))
        XCTAssertNil(try store.spokenSummary(convoID: "c1", for: reply))
    }

    func testSpokenSummaryMatchesByRef() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "one", "message_ref": "m1"]),
            event(2, type: "summary", payload: ["toc": "A", "spoken": "About one.", "spoken_ref": "m1"]),
            event(3, payload: ["body": "two", "message_ref": "m3"]),
        ])
        let first = AgentReplyRow(seq: 1, messageRef: "m1", body: "one")
        let second = AgentReplyRow(seq: 3, messageRef: "m3", body: "two")
        XCTAssertEqual(try store.spokenSummary(convoID: "c1", for: first)?.spoken, "About one.")
        XCTAssertNil(try store.spokenSummary(convoID: "c1", for: second), "the summary for the new reply has not landed")
        _ = try store.applyJournal(event(4, type: "summary", payload: ["toc": "B", "spoken": "About two.", "spoken_ref": "m3"]))
        XCTAssertEqual(try store.spokenSummary(convoID: "c1", for: second)?.spoken, "About two.")
    }

    /// A summary can land after a newer reply was published: its line is
    /// for the older reply and must not be said for the newest one.
    func testALateSummaryForAnOlderReplyIsNotUsedForTheNewestOne() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "old reply", "message_ref": "m1"]),
            event(2, payload: ["body": "new reply", "message_ref": "m2"]),
            event(3, type: "summary", payload: ["toc": "Late", "spoken": "About the old reply.", "spoken_ref": "m1"]),
        ])
        let newest = try XCTUnwrap(try store.lastAgentReply(convoID: "c1"))
        XCTAssertEqual(newest.messageRef, "m2")
        XCTAssertNil(try store.spokenSummary(convoID: "c1", for: newest))
    }

    func testASummaryWithoutSpokenIsNotASpokenSummary() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, payload: ["body": "reply", "message_ref": "m1"]),
            event(2, type: "summary", payload: ["toc": "Old bridge"]),
        ])
        XCTAssertNil(try store.spokenSummary(convoID: "c1", for: AgentReplyRow(seq: 1, messageRef: "m1", body: "reply")))
    }

    // MARK: unansweredPrompts

    private func prompt(_ seq: Int64, convo: String = "c1", ts: TimeInterval = 1_000,
                        payload: [String: Any] = ["question": "Which one?", "options": ["A", "B"]]) -> JournalEvent {
        event(seq, convo: convo, type: "prompt", ts: ts, payload: payload)
    }

    func testAPromptNobodyAnsweredIsReturnedWithItsConversation() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            event(1, type: "convo_meta", payload: ["title": "[ab] Auth refactor"]),
            prompt(2),
        ])
        let rows = try store.unansweredPrompts(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(rows.map(\.event.seq), [2])
        XCTAssertEqual(rows.first?.convoTitle, "[ab] Auth refactor")
        XCTAssertNil(rows.first?.agentName)
    }

    func testAnAnsweredPromptIsLeftOut() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            prompt(1), prompt(2), prompt(3, convo: "c2"), prompt(4, convo: "c3"),
            // A tap on prompt 2 only: prompt 1 is still open.
            event(5, sender: "user:dan", type: "prompt_reply", payload: ["target_seq": 2, "choice": "A"]),
            // Typed instead of tapped: answers everything before it in c2.
            event(6, convo: "c2", sender: "user:dan", payload: ["body": "the second"]),
            // The agent talking after its own prompt answers nothing.
            event(7, convo: "c3", payload: ["body": "still waiting"]),
        ])
        XCTAssertEqual(try store.unansweredPrompts(since: Date(timeIntervalSince1970: 0)).map(\.event.seq), [1, 4])
    }

    func testQueueCardsOldPromptsAndDeadConversationsAreLeftOut() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([
            prompt(1, payload: ["question": "Queued", "options": ["Send now"], "kind": "queued_release", "prompt_id": "pr_1"]),
            prompt(2, ts: 10),                         // older than `since`
            prompt(3, convo: "done"),
            event(4, convo: "done", type: "session_status", ts: 1_000, payload: ["state": "done"]),
            prompt(5, convo: "live"),
        ])
        XCTAssertEqual(try store.unansweredPrompts(since: Date(timeIntervalSince1970: 500)).map(\.event.seq), [5])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.JournalStoreVoiceTests'`
Expected: build FAILS — `value of type 'JournalStore' has no member 'lastAgentReply'`.

- [ ] **Step 3: Make `ownSender` reachable from the extension**

In `JournalStore.swift`, replace `private let ownSender: String` with:

```swift
    // Module-internal (not private): JournalStore+Voice.swift tells the
    // user's own events from an agent's.
    let ownSender: String
```

- [ ] **Step 4: Create `JournalStore+Voice.swift`**

```swift
import Foundation
import GRDB

// Voice mode reads (spec 2026-10-03 §3, §5). Everything here is derived
// from tables the sync engine already fills: no new table, no new sync.

/// An ask-user or tool-permission `prompt` nobody has answered yet, with
/// the two facts about its conversation the voice queue says out loud.
public struct UnansweredPromptRow: Equatable, Sendable {
    public let event: JournalEvent
    public let convoTitle: String
    /// The agent box that manages the conversation, when known.
    public let agentName: String?

    public init(event: JournalEvent, convoTitle: String, agentName: String?) {
        self.event = event; self.convoTitle = convoTitle; self.agentName = agentName
    }
}

/// The agent's own words for one reply. The bridge splits a long reply
/// into several `text` rows and only the first carries the `message_ref`;
/// `body` is all of them, `seq` and `messageRef` the first one's.
public struct AgentReplyRow: Equatable, Sendable {
    public let seq: Int64
    /// The bridge's id for the reply (a summary's `spoken_ref` names it).
    /// `nil` only from a bridge that predates refs on unstreamed replies.
    public let messageRef: String?
    public let body: String

    public init(seq: Int64, messageRef: String?, body: String) {
        self.seq = seq; self.messageRef = messageRef; self.body = body
    }
}

extension JournalStore {
    /// `prompt` rows newer than `since` that the user has not answered:
    /// no `prompt_reply` of theirs targets the row, and they have sent
    /// nothing to that conversation after it (typing an answer instead of
    /// tapping one is still an answer). Busy-queue cards (`queued_release`)
    /// are not questions and are left out, as are prompts in a hidden or
    /// finished conversation. Oldest first.
    ///
    /// Reads `event_type_ts` for the candidates and `event_convo_type` for
    /// each one's later rows, so it never walks a conversation.
    public func unansweredPrompts(since: Date) throws -> [UnansweredPromptRow] {
        let sinceMS = Int64(since.timeIntervalSince1970 * 1000)
        let own = ownSender
        return try dbQueue.read { db in
            let candidates = try EventRecord.fetchAll(db, sql: """
                SELECT * FROM event WHERE type = 'prompt' AND ts >= ? ORDER BY seq
                """, arguments: [sinceMS])
            var out: [UnansweredPromptRow] = []
            for record in candidates where record.sender != own {
                let event = record.journalEvent
                if (event.payload["kind"] as? String) == "queued_release" { continue }
                let later = try EventRecord.fetchAll(db, sql: """
                    SELECT * FROM event
                    WHERE convo_id = ? AND type IN ('text', 'file', 'image', 'prompt_reply')
                      AND seq > ? AND sender = ?
                    """, arguments: [event.convoID, event.seq, own])
                let answered = later.contains { row in
                    guard row.type == JournalEventType.promptReply else { return true }
                    return (row.journalEvent.payload["target_seq"] as? NSNumber)?.int64Value == event.seq
                }
                if answered { continue }
                guard let convo = try ConversationRecord.fetchOne(db, key: event.convoID),
                      !convo.hidden, convo.sessionState != "done" else { continue }
                let agent = try convo.agentDeviceID.flatMap {
                    try String.fetchOne(db, sql: "SELECT name FROM agent WHERE id = ?", arguments: [$0])
                }
                out.append(UnansweredPromptRow(event: event, convoTitle: convo.title, agentName: agent))
            }
            return out
        }
    }

    /// The agent's newest reply in a conversation, above `afterSeq`: the
    /// newest assistant `text` row that carries a `message_ref`, with the
    /// unreferenced `text` rows the bridge published straight after it
    /// (the later chunks of a long reply). From a bridge that sends no
    /// ref on an unstreamed reply, the newest assistant `text` row alone.
    ///
    /// The journal's old-client mirror of an item marker (`fallback_for`)
    /// is not a reply and is skipped. `message_ref` needs no column: the
    /// mirror stores every payload whole.
    public func lastAgentReply(convoID: String, afterSeq: Int64 = 0) throws -> AgentReplyRow? {
        let own = ownSender
        return try dbQueue.read { db in
            let rows = try EventRecord.fetchAll(db, sql: """
                SELECT * FROM event
                WHERE convo_id = ? AND type = 'text' AND seq > ? AND sender != ?
                ORDER BY seq DESC LIMIT 40
                """, arguments: [convoID, afterSeq, own])
            var newestPlain: AgentReplyRow?
            for row in rows {
                let payload = row.journalEvent.payload
                if payload["fallback_for"] != nil { continue }
                guard let body = payload["body"] as? String, !body.isEmpty else { continue }
                guard let ref = payload["message_ref"] as? String, !ref.isEmpty else {
                    if newestPlain == nil { newestPlain = AgentReplyRow(seq: row.seq, messageRef: nil, body: body) }
                    continue
                }
                // The first chunk. Whatever text the same sender published
                // straight after it, without a ref, is the rest of it.
                var chunks = [body]
                let later = try EventRecord.fetchAll(db, sql: """
                    SELECT * FROM event WHERE convo_id = ? AND seq > ? ORDER BY seq LIMIT 40
                    """, arguments: [convoID, row.seq])
                for next in later {
                    if !JournalEventType.messageTypes.contains(next.type),
                       next.type != JournalEventType.sessionStatus { continue }
                    let nextPayload = next.journalEvent.payload
                    guard next.type == JournalEventType.text, next.sender == row.sender,
                          nextPayload["message_ref"] == nil, nextPayload["fallback_for"] == nil,
                          let more = nextPayload["body"] as? String else { break }
                    chunks.append(more)
                }
                return AgentReplyRow(seq: row.seq, messageRef: ref, body: chunks.joined(separator: "\n\n"))
            }
            return newestPlain
        }
    }

    /// The summary entry carrying the spoken lines for `reply`: the newest
    /// one whose `spoken_ref` is the reply's `message_ref`. The bridge
    /// sends `spoken` and `spoken_ref` together or not at all, and a
    /// summary can land after a newer reply has been published, so a
    /// spoken line is only ever used for the reply its ref names. `nil`
    /// until the summary pass lands, and for ever when there is none (no
    /// summary key on the box, an old bridge, a turn with no reply).
    public func spokenSummary(convoID: String, for reply: AgentReplyRow) throws -> SummaryEntryRecord? {
        guard let ref = reply.messageRef else { return nil }
        return try dbQueue.read { db in
            try SummaryEntryRecord.fetchOne(db, sql: """
                SELECT * FROM summary_entry
                WHERE convo_id = ? AND spoken IS NOT NULL AND spoken_ref = ?
                ORDER BY seq DESC LIMIT 1
                """, arguments: [convoID, ref])
        }
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.(JournalStoreVoiceTests|JournalStoreTests)'`
Expected: `Executed 14 tests, with 0 failures` (voice) and `Executed 81 tests, with 0 failures` (store).

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore.swift MatronShared/Sources/Journal/JournalStore+Voice.swift \
        MatronShared/Tests/JournalTests/JournalStoreVoiceTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: store reads for the newest reply, its spoken summary and unanswered prompts" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `SpeechCleaner` — Markdown to speakable text

**Files:**
- Create: `MatronShared/Sources/DesignSystem/SpeechCleaner.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/SpeechCleanerTests.swift` (new; logic tests live in this target beside `MarkdownSourceTests`)

**Interfaces:**
- Consumes (all internal to `MatronDesignSystem`, which is why the cleaner lives here): `MarkdownSource.prepared(_:)` (`MarkdownSource.swift:34` — escapes `[label]: text` lines and autolinks bare `matron://item/<n>`), `BlockKind(_ intent: PresentationIntent?)` (`MarkdownAttributed.swift:959-1055`), `MatronItemLink.itemNumber(from:)` (`MatronItemLink.swift:109`). The parse is the renderers' own: `AttributedString(markdown:options:)` with `.full` syntax (`MarkdownAttributed.swift:441-448`).
- Produces (public): `SpeechCleaner.speakable(_:) -> String`, `.fallbackShort(_:) -> String`, `.sections(_:wordsPerSection:) -> [String]`, `.blocks(_:) -> [Block]`, `.spelled(_:) -> String`; constants `tableNotice`, `codeNotice`, `diffNotice`, `wordsPerSection` (150), `shortLimit` (400).
- Imports Foundation only: no UIKit, no SwiftUI.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/DesignSystemSnapshotTests/SpeechCleanerTests.swift`:

```swift
import XCTest
@testable import MatronDesignSystem

/// Voice mode's cleaner (spec 2026-10-03 §3): what a message sounds like
/// once everything that cannot be said is taken out.
final class SpeechCleanerTests: XCTestCase {
    // MARK: speakable

    func testPlainProseIsUnchanged() {
        XCTAssertEqual(SpeechCleaner.speakable("The build is green."), "The build is green.")
    }

    func testHeadingsAndListMarkersAreRemoved() {
        let body = """
        ## Next steps

        - Merge the branch
        - Deploy to **staging**
        1. Then tell Dan
        """
        XCTAssertEqual(SpeechCleaner.speakable(body),
                       "Next steps. Merge the branch. Deploy to staging. Then tell Dan.")
    }

    func testEmphasisAndInlineCodeKeepTheirWords() {
        XCTAssertEqual(SpeechCleaner.speakable("Run `make test` and it *should* pass."),
                       "Run make test and it should pass.")
    }

    func testACodeBlockBecomesOneNotice() {
        let body = "I changed the handler:\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nIt works now."
        XCTAssertEqual(SpeechCleaner.speakable(body),
                       "I changed the handler. There's code in the chat. It works now.")
    }

    func testADiffBlockSaysDiff() {
        let body = "Here is the change.\n\n```diff\n- old\n+ new\n```"
        XCTAssertEqual(SpeechCleaner.speakable(body), "Here is the change. There's a diff in the chat.")
    }

    func testATableBecomesOneNoticeHoweverManyCells() {
        let body = """
        Timings:

        | Run | Seconds |
        |---|---|
        | 1 | 12 |
        | 2 | 14 |

        Both are fine.
        """
        XCTAssertEqual(SpeechCleaner.speakable(body), "Timings. There's a table in the chat. Both are fine.")
    }

    func testLinkTextIsKeptAndTheAddressDropped() {
        XCTAssertEqual(SpeechCleaner.speakable("See [the pull request](https://github.com/Matronhq/matron-apple/pull/305) for more."),
                       "See the pull request for more.")
    }

    func testABareAddressIsDropped() {
        XCTAssertEqual(SpeechCleaner.speakable("It is live at https://example.com/a/b?c=1 now."), "It is live at now.")
        XCTAssertEqual(SpeechCleaner.speakable("Docs: <https://example.com/docs>"), "Docs.")
    }

    func testImagesAreDropped() {
        XCTAssertEqual(SpeechCleaner.speakable("Before ![screenshot](https://example.com/a.png) after."), "Before after.")
    }

    func testAnItemLinkReadsAsTheItem() {
        XCTAssertEqual(SpeechCleaner.speakable("I filed [#12](matron://item/12) for the copy."),
                       "I filed item twelve for the copy.")
        XCTAssertEqual(SpeechCleaner.speakable("The steps are on matron://item/5685."),
                       "The steps are on item five thousand six hundred eighty-five.")
    }

    /// `[label]: text` is a link reference definition to CommonMark and
    /// renders as nothing; the bridge's voice-note mirror has that shape.
    func testALabelColonLineKeepsItsWords() {
        XCTAssertEqual(SpeechCleaner.speakable("[blocked]: waiting on Dan"), "[blocked]: waiting on Dan.")
    }

    func testABlockQuoteIsRead() {
        XCTAssertEqual(SpeechCleaner.speakable("The draft:\n\n> Dear parents, the books are late."),
                       "The draft. Dear parents, the books are late.")
    }

    func testAnEmptyOrCodeOnlyMessage() {
        XCTAssertEqual(SpeechCleaner.speakable(""), "")
        XCTAssertEqual(SpeechCleaner.speakable("```\nls\n```"), "There's code in the chat.")
    }

    // MARK: fallbackShort

    func testFallbackKeepsTheFirstTwoSentences() {
        let body = "The deploy finished. All 412 tests passed. The cache was rebuilt. Nothing else changed."
        XCTAssertEqual(SpeechCleaner.fallbackShort(body), "The deploy finished. All 412 tests passed.")
    }

    func testFallbackAddsAClosingQuestion() {
        let body = "The deploy finished. All tests passed. The cache was rebuilt. Shall I merge it now?"
        XCTAssertEqual(SpeechCleaner.fallbackShort(body),
                       "The deploy finished. All tests passed. Shall I merge it now?")
    }

    func testFallbackDoesNotRepeatAQuestionAlreadyInTheFirstTwo() {
        XCTAssertEqual(SpeechCleaner.fallbackShort("It failed. Shall I retry?"), "It failed. Shall I retry?")
    }

    func testFallbackSkipsHeadingsAndUnsayableBlocks() {
        let body = "# Report\n\n```\nlog\n```\n\nThe job failed on step three. I have not retried it."
        XCTAssertEqual(SpeechCleaner.fallbackShort(body),
                       "There's code in the chat. The job failed on step three.")
    }

    func testFallbackStaysUnderTheContractCap() {
        let long = String(repeating: "word ", count: 120) + "end. Second sentence."
        XCTAssertLessThanOrEqual(SpeechCleaner.fallbackShort(long).count, SpeechCleaner.shortLimit)
        XCTAssertFalse(SpeechCleaner.fallbackShort(long).isEmpty)
    }

    func testFallbackOfNothingIsEmpty() {
        XCTAssertEqual(SpeechCleaner.fallbackShort("   "), "")
    }

    // MARK: sections

    func testAShortMessageIsOneSection() {
        XCTAssertEqual(SpeechCleaner.sections("One. Two."), ["One. Two."])
    }

    func testAHeadingStartsANewSection() {
        let body = "Intro paragraph.\n\n## Risks\n\nIt may be slow.\n\n## Plan\n\nShip on Monday."
        XCTAssertEqual(SpeechCleaner.sections(body),
                       ["Intro paragraph.", "Risks. It may be slow.", "Plan. Ship on Monday."])
    }

    func testParagraphsFillASectionUpToTheLimit() {
        let body = "one two three.\n\nfour five six.\n\nseven eight nine."
        XCTAssertEqual(SpeechCleaner.sections(body, wordsPerSection: 6),
                       ["one two three. four five six.", "seven eight nine."])
    }

    func testALongParagraphIsCutAtSentences() {
        let body = "Alpha beta gamma. Delta epsilon zeta. Eta theta iota."
        XCTAssertEqual(SpeechCleaner.sections(body, wordsPerSection: 4),
                       ["Alpha beta gamma.", "Delta epsilon zeta.", "Eta theta iota."])
    }

    func testSectionsOfNothing() {
        XCTAssertEqual(SpeechCleaner.sections(""), [])
    }

    func testSpelledNumbers() {
        XCTAssertEqual(SpeechCleaner.spelled(1), "one")
        XCTAssertEqual(SpeechCleaner.spelled(21), "twenty-one")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter 'DesignSystemSnapshotTests.SpeechCleanerTests'`
Expected: build FAILS — `cannot find 'SpeechCleaner' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/DesignSystem/SpeechCleaner.swift`:

```swift
import Foundation

/// Markdown → words worth saying out loud (voice mode, spec 2026-10-03 §3,
/// "The cleaner"). Deterministic, no model: the same parse both renderers
/// use (`MarkdownSource.prepared` + Foundation's full Markdown syntax, read
/// through `BlockKind`), so what the cleaner leaves out of speech is exactly
/// what a later stage can put on screen (§8).
///
/// Dropped: code blocks, diffs, tables, images and URLs. A table, a code
/// block and a diff each leave one short sentence saying it is in the chat.
/// Kept: link text, heading and list-item text (without their markers).
/// `[#12](matron://item/12)` reads "item twelve".
///
/// Foundation only: no UIKit, no SwiftUI, so every platform's voice engine
/// can call it.
public enum SpeechCleaner {
    /// One block of a message, as speech.
    public struct Block: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case heading, prose, notice }
        public let kind: Kind
        public let text: String
    }

    public static let tableNotice = "There's a table in the chat."
    public static let codeNotice = "There's code in the chat."
    public static let diffNotice = "There's a diff in the chat."

    /// About a minute of speech at 150 words a minute.
    public static let wordsPerSection = 150
    /// The contract's cap on a level-1 line (`spoken`, 400 characters).
    public static let shortLimit = 400

    // MARK: Whole message

    /// The whole message as one speakable string.
    public static func speakable(_ markdown: String) -> String {
        blocks(markdown).map(\.text).joined(separator: " ")
    }

    /// Level 1 when the bridge sent no `spoken` line: the first two
    /// sentences and, when the message ends with a question that those two
    /// did not already include, that question.
    public static func fallbackShort(_ markdown: String) -> String {
        let all = blocks(markdown).filter { $0.kind != .heading }.map(\.text).joined(separator: " ")
        let parts = sentences(all)
        guard !parts.isEmpty else { return "" }
        var picked = Array(parts.prefix(2))
        if parts.count > 2, let last = parts.last, last.hasSuffix("?") { picked.append(last) }
        return clipped(picked.joined(separator: " "), to: shortLimit)
    }

    /// Level 3: the message itself, about a minute at a time. A heading
    /// starts a new section; paragraphs fill a section up to
    /// `wordsPerSection`; a paragraph longer than that is cut at sentences.
    public static func sections(_ markdown: String, wordsPerSection limit: Int = wordsPerSection) -> [String] {
        var out: [String] = []
        var current: [String] = []
        var count = 0
        func flush() {
            if !current.isEmpty { out.append(current.joined(separator: " ")) }
            current = []
            count = 0
        }
        for block in blocks(markdown) {
            if block.kind == .heading { flush() }
            for piece in pieces(of: block.text, limit: limit) {
                let words = wordCount(piece)
                if count > 0, count + words > limit { flush() }
                current.append(piece)
                count += words
            }
        }
        flush()
        return out
    }

    // MARK: Blocks

    /// The message block by block, in order, with everything unsayable
    /// removed. Consecutive table cells are one notice; so is each code
    /// block.
    public static func blocks(_ markdown: String) -> [Block] {
        let source = MarkdownSource.prepared(markdown)
        guard let attributed = try? AttributedString(
            markdown: source,
            options: .init(allowsExtendedAttributes: true, interpretedSyntax: .full,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            let plain = tidy(strippingURLs(markdown))
            return plain.isEmpty ? [] : [Block(kind: .prose, text: plain)]
        }

        var out: [Block] = []
        var openIntent: PresentationIntent?
        var openKind: BlockKind?
        var openText = ""
        var started = false
        var lastWasTable = false

        func close() {
            guard started, let kind = openKind else { return }
            switch kind {
            case .tableCell:
                if !lastWasTable { out.append(Block(kind: .notice, text: tableNotice)) }
                lastWasTable = true
            case .codeBlock(let language):
                out.append(Block(kind: .notice, text: language?.lowercased() == "diff" ? diffNotice : codeNotice))
                lastWasTable = false
            case .header:
                let text = sentence(tidy(strippingURLs(openText)))
                if !text.isEmpty { out.append(Block(kind: .heading, text: text)) }
                lastWasTable = false
            case .paragraph, .blockQuote, .listItem:
                let text = sentence(tidy(strippingURLs(openText)))
                if !text.isEmpty { out.append(Block(kind: .prose, text: text)) }
                lastWasTable = false
            }
        }

        for run in attributed.runs {
            let intent = run.presentationIntent
            if !started || intent != openIntent {
                close()
                openIntent = intent
                openKind = BlockKind(intent)
                openText = ""
                started = true
            }
            if run.imageURL != nil { continue }
            let text = String(attributed[run.range].characters)
            if let link = run.link {
                if let number = MatronItemLink.itemNumber(from: link) {
                    openText += "item \(spelled(number))"
                } else if !looksLikeURL(text) {
                    openText += text
                }
                continue
            }
            openText += text
        }
        close()
        return out
    }

    // MARK: Pieces

    /// `text` whole when it fits `limit` words, else cut at sentence ends
    /// into runs that do.
    private static func pieces(of text: String, limit: Int) -> [String] {
        guard wordCount(text) > limit else { return [text] }
        var out: [String] = []
        var current: [String] = []
        var count = 0
        for part in sentences(text) {
            let words = wordCount(part)
            if count > 0, count + words > limit {
                out.append(current.joined(separator: " "))
                current = []
                count = 0
            }
            current.append(part)
            count += words
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { part, _, _, _ in
            let trimmed = (part ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        return out
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }

    /// Cuts at the last sentence end that fits, else at the last word.
    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        var kept = ""
        for part in sentences(text) {
            let next = kept.isEmpty ? part : kept + " " + part
            if next.count > limit { break }
            kept = next
        }
        if !kept.isEmpty { return kept }
        let cut = String(text.prefix(limit))
        guard let space = cut.lastIndex(of: " ") else { return cut }
        return String(cut[..<space])
    }

    // MARK: Text

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>()]+"#, options: [.caseInsensitive])

    /// A link whose text is its own address (an autolink): nothing to say.
    private static func looksLikeURL(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = urlPattern.firstMatch(in: text, range: range) else { return false }
        return match.range == range
    }

    /// Bare addresses the parser left as text.
    private static func strippingURLs(_ text: String) -> String {
        urlPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// One line, single spaces, and no space left stranded before the
    /// punctuation a removed link or image sat next to.
    private static func tidy(_ text: String) -> String {
        var collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for mark in [".", ",", ";", ":", "!", "?", ")"] {
            collapsed = collapsed.replacingOccurrences(of: " \(mark)", with: mark)
        }
        collapsed = collapsed.replacingOccurrences(of: "( ", with: "(")
        collapsed = collapsed.replacingOccurrences(of: "()", with: "")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// Ends the block like a sentence so blocks joined by a space do not
    /// run together ("Next steps Ship it" → "Next steps. Ship it.").
    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        if ".!?".contains(last) { return text }
        if last == ":" { return String(text.dropLast()) + "." }
        return text + "."
    }

    private static let speller: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()

    /// 12 → "twelve".
    public static func spelled(_ number: Int) -> String {
        speller.string(from: NSNumber(value: number)) ?? String(number)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter 'DesignSystemSnapshotTests.(SpeechCleanerTests|MarkdownSourceTests|MarkdownSourceItemLinkTests)'`
Expected: `SpeechCleanerTests` — `Executed 25 tests, with 0 failures`; the two existing Markdown suites still pass (the cleaner changes neither).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/SpeechCleaner.swift MatronShared/Tests/DesignSystemSnapshotTests/SpeechCleanerTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: SpeechCleaner turns a message into what can be said" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The `MatronVoice` target, and `VoiceCommand`

**Files:**
- Modify: `MatronShared/Package.swift` (products at line 21; targets before the `StorageTests` test target at line 178)
- Create: `MatronShared/Sources/Voice/VoiceCommand.swift`
- Test: `MatronShared/Tests/VoiceTests/VoiceCommandTests.swift` (new)

**Interfaces:**
- Produces: library product and target `MatronVoice` (path `Sources/Voice`), test target `VoiceTests`.
- Produces (MatronVoice): `enum VoiceCommand: String { repeat, more, skip, stop, cancel, yes, no }` with `static func parse(_ utterance: String) -> VoiceCommand?`; `enum VoiceText` with `static func words(_:) -> [String]` (lowercase words, punctuation, emoji and apostrophes removed) — the one normalisation every matcher in this plan uses.

- [ ] **Step 1: Add the target**

In `Package.swift`, add to `products` after the `MatronJournal` library:

```swift
        .library(name: "MatronVoice", targets: ["MatronVoice"]),
```

and to `targets`, directly before `.testTarget(name: "StorageTests", …)`:

```swift
        // Voice mode (spec 2026-10-03 §3): the engine every surface drives
        // (iPhone screen now; the Mac stage and CarPlay later). Foundation,
        // AVFoundation and Speech only: it must never import UIKit, AppKit
        // or SwiftUI, and knows nothing about screens. MatronChat is here
        // for the prompt decoding and title rules the timeline already has.
        .target(
            name: "MatronVoice",
            dependencies: [
                "MatronModels",
                "MatronEvents",
                "MatronJournal",
                "MatronChat",
            ],
            path: "Sources/Voice"
        ),
        .testTarget(name: "VoiceTests", dependencies: ["MatronVoice", "MatronModels", "MatronEvents", "MatronJournal", "MatronChat"], path: "Tests/VoiceTests"),
```

- [ ] **Step 2: Write the failing test**

Create `MatronShared/Tests/VoiceTests/VoiceCommandTests.swift`:

```swift
import XCTest
@testable import MatronVoice

final class VoiceCommandTests: XCTestCase {
    func testCommandTable() {
        let table: [(String, VoiceCommand?)] = [
            // repeat
            ("repeat", .repeat), ("Repeat that.", .repeat), ("Say that again", .repeat), ("again", .repeat),
            ("Sorry, what?", .repeat), ("Can you repeat that please?", .repeat), ("pardon", .repeat),
            // more
            ("more", .more), ("Tell me more.", .more), ("I want to know more", .more), ("Go on", .more),
            ("keep going", .more), ("More detail please", .more), ("um, carry on", .more), ("continue", .more),
            ("read the rest", .more),
            // skip / next
            ("skip", .skip), ("Next.", .skip), ("skip this one", .skip), ("next one please", .skip), ("move on", .skip),
            // stop
            ("stop", .stop), ("Stop talking", .stop), ("OK, stop.", .stop), ("that's enough", .stop),
            ("That\u{2019}s enough, thanks", .stop), ("be quiet", .stop),
            // cancel
            ("cancel", .cancel), ("Cancel that", .cancel), ("never mind", .cancel), ("Don't send that", .cancel),
            ("do not send it", .cancel),
            // yes / no
            ("yes", .yes), ("Yeah.", .yes), ("okay", .yes), ("OK", .yes), ("that's right", .yes), ("go ahead", .yes),
            ("yes please", .yes),
            ("no", .no), ("Nope", .no), ("no, wait", .no), ("No thanks", .no), ("that's wrong", .no),
            // not commands: a command with anything else is a message
            ("tell me more about the tests", nil), ("stop the deploy on bev", nil), ("next week is fine", nil),
            ("repeat the migration on staging", nil), ("yes, go with the second option", nil),
            ("no, use Postgres instead", nil), ("cancel the order for the school", nil),
            ("more or less", nil), ("skip the tests and merge", nil), ("", nil), ("   ", nil), ("please", nil),
        ]
        for (utterance, expected) in table {
            XCTAssertEqual(VoiceCommand.parse(utterance), expected, "\u{201C}\(utterance)\u{201D}")
        }
    }

    func testWordsNormalise() {
        XCTAssertEqual(VoiceText.words("That\u{2019}s RIGHT — go, now!"), ["thats", "right", "go", "now"])
        XCTAssertEqual(VoiceText.words("Don't  send #12 ✅"), ["dont", "send", "12"])
        XCTAssertEqual(VoiceText.words(""), [])
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceCommandTests'`
Expected: build FAILS — `cannot find 'VoiceCommand' in scope` (SwiftPM also reports the empty `Sources/Voice` directory until Step 4 creates a file in it).

- [ ] **Step 4: Implement**

Create `MatronShared/Sources/Voice/VoiceCommand.swift`:

```swift
import Foundation

/// A whole-utterance command (spec 2026-10-03 §3, "What happens to what Dan
/// said", and §4's confirmations). An utterance is a command only when it
/// is the command and nothing else, in any natural phrasing: "tell me
/// more" is `.more`; "tell me more about the tests" is a message for the
/// agent.
public enum VoiceCommand: String, Equatable, Sendable, CaseIterable {
    case `repeat`, more, skip, stop, cancel, yes, no

    /// The command `utterance` is, or `nil` when it is anything else.
    public static func parse(_ utterance: String) -> VoiceCommand? {
        let words = core(VoiceText.words(utterance))
        guard !words.isEmpty else { return nil }
        return table[words.joined(separator: " ")]
    }

    /// Words that may wrap a command without changing it ("um, stop
    /// please"). Stripped from both ends, never from the middle, and never
    /// down to nothing: "okay" alone is still `.yes`.
    private static let leading: Set<String> = ["um", "uh", "er", "erm", "hey", "ok", "okay", "so", "well", "and", "now", "please", "matron", "just"]
    private static let trailing: Set<String> = ["please", "thanks", "thank", "you", "now", "matron", "then"]

    private static func core(_ words: [String]) -> [String] {
        var slice = words[...]
        while slice.count > 1, let first = slice.first, leading.contains(first) { slice = slice.dropFirst() }
        while slice.count > 1, let last = slice.last, trailing.contains(last) { slice = slice.dropLast() }
        return Array(slice)
    }

    private static let phrases: [VoiceCommand: [String]] = [
        .repeat: ["repeat", "repeat that", "repeat it", "say that again", "say it again", "again", "one more time",
                  "come again", "what was that", "pardon", "sorry what", "can you repeat that", "could you repeat that",
                  "what did you say"],
        .more: ["more", "tell me more", "i want to know more", "id like to know more", "go on", "carry on", "continue",
                "keep going", "more detail", "more details", "give me more", "say more", "yes more", "what else",
                "read on", "read the rest", "read it", "read the message", "read it out", "and then"],
        .skip: ["skip", "next", "skip it", "skip this", "skip that", "skip this one", "skip that one", "next one",
                "the next one", "move on", "pass"],
        .stop: ["stop", "stop talking", "be quiet", "quiet", "enough", "thats enough", "shut up", "pause", "hush",
                "stop it", "stop there"],
        .cancel: ["cancel", "cancel that", "cancel it", "never mind", "nevermind", "dont send", "dont send that",
                  "dont send it", "do not send", "do not send that", "do not send it", "scrap that", "forget it",
                  "forget that"],
        .yes: ["yes", "yeah", "yep", "yup", "correct", "thats right", "right", "do it", "sure", "ok", "okay",
               "affirmative", "go ahead", "yes do", "yes it is", "thats it", "thats the one"],
        .no: ["no", "nope", "nah", "wrong", "thats wrong", "no wait", "wait no", "not that", "no its not",
              "thats not it", "no thanks", "no thank"],
    ]

    private static let table: [String: VoiceCommand] = {
        var out: [String: VoiceCommand] = [:]
        for (command, list) in phrases {
            for phrase in list {
                precondition(out[phrase] == nil, "\(phrase) names two commands")
                out[phrase] = command
            }
        }
        return out
    }()
}

/// How voice mode compares what was heard with what it expects: lowercase
/// words with punctuation, emoji and apostrophes gone ("That's right." →
/// `["thats", "right"]`), so a recogniser's capitals and full stops never
/// decide a match.
public enum VoiceText {
    public static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceCommandTests'`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Package.swift MatronShared/Sources/Voice/VoiceCommand.swift MatronShared/Tests/VoiceTests/VoiceCommandTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: MatronVoice target and whole-utterance commands" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `ActionLabelMatcher` — an utterance against an item's or prompt's labels

**Files:**
- Create: `MatronShared/Sources/Voice/ActionLabelMatcher.swift`
- Test: `MatronShared/Tests/VoiceTests/ActionLabelMatcherTests.swift` (new)

**Interfaces:**
- Consumes: Task 4's `VoiceText.words`.
- Produces: `enum ActionMatch { clear(String), unsure(String), none }`; `ActionLabelMatcher.match(_ utterance: String, labels: [String]) -> ActionMatch` (the associated value is always one of `labels` exactly as written — the journal accepts an `action` only on an exact label); `ActionLabelMatcher.PermissionVerdict { allow, always, deny }` and `permissionVerdict(_:) -> PermissionVerdict?`.

The rules (spec §4), in order:
1. **Clear** — the utterance is a label, or is one once filler is removed from both ("yes, go", "merge it now" for "Merge now"). A word that a label needs is never filler: every word of a label made only of filler ("Go", "Yes"), and the telling words of the others.
2. **Clear** — a position: "option one", "the second one", "number two", "the last one". The whole utterance must be the reference.
3. **Unsure** — part of a label ("merge" for "Merge now"), the label inside at most three other words with no refusal or question among them ("go, after lunch"), or a near-spelling (similarity ≥ 0.8). The best wins; a tie goes to the earlier label.
4. **None** — anything else, including a refusal ("don't go") and a question ("what does wait mean").

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/VoiceTests/ActionLabelMatcherTests.swift`:

```swift
import XCTest
@testable import MatronVoice

final class ActionLabelMatcherTests: XCTestCase {
    private func check(_ labels: [String], _ table: [(String, ActionMatch)], file: StaticString = #filePath, line: UInt = #line) {
        for (utterance, expected) in table {
            XCTAssertEqual(ActionLabelMatcher.match(utterance, labels: labels), expected,
                           "\u{201C}\(utterance)\u{201D} against \(labels)", file: file, line: line)
        }
    }

    func testTwoShortLabels() {
        check(["Go", "Wait"], [
            // Clear: the label, or the label with filler.
            ("go", .clear("Go")), ("Go.", .clear("Go")), ("Yes, go", .clear("Go")), ("go please", .clear("Go")),
            ("OK let's go", .clear("Go")), ("I'd say go", .clear("Go")), ("wait", .clear("Wait")),
            ("Let's wait.", .clear("Wait")), ("I think we should wait", .clear("Wait")),
            // Clear: by position.
            ("option one", .clear("Go")), ("Option two.", .clear("Wait")), ("the first one", .clear("Go")),
            ("the second one", .clear("Wait")), ("number two", .clear("Wait")), ("the last one", .clear("Wait")),
            ("I'll take the second", .clear("Wait")), ("second option please", .clear("Wait")),
            // Unsure: close to one, or close to two.
            ("go, after lunch", .unsure("Go")), ("go wait", .unsure("Go")), ("wait a minute", .unsure("Wait")),
            // None: a position that is not there, a refusal, a question, a sentence.
            ("option three", .none), ("the fourth one", .none), ("don't go", .none), ("not wait", .none),
            ("what does wait mean", .none), ("go but check the tests first", .none),
            ("why would we go now", .none), ("tell me about the risk", .none), ("", .none), ("yes", .none),
        ])
    }

    func testLongerLabels() {
        check(["Merge now", "Wait until Monday", "Close it"], [
            ("merge now", .clear("Merge now")), ("Merge it now.", .clear("Merge now")),
            ("yes merge now please", .clear("Merge now")), ("wait until Monday", .clear("Wait until Monday")),
            ("close it", .clear("Close it")), ("the third one", .clear("Close it")), ("the last one", .clear("Close it")),
            ("option 2", .clear("Wait until Monday")),
            // Part of a label, or a slip of one.
            ("merge", .unsure("Merge now")), ("Monday", .unsure("Wait until Monday")), ("close", .clear("Close it")),
            ("wait until Mondays", .unsure("Wait until Monday")), ("merge now on bev", .unsure("Merge now")),
            ("don't merge now", .none), ("merge now unless the tests fail", .none), ("what about Tuesday", .none),
        ])
    }

    func testLabelsThatAreAlsoFillerOrCommands() {
        check(["Yes", "No"], [
            ("yes", .clear("Yes")), ("Yes please", .clear("Yes")), ("no", .clear("No")), ("No thanks.", .clear("No")),
            ("the first one", .clear("Yes")), ("okay", .none),
        ])
        check(["Skip", "Stop the run", "Go with option one"], [
            ("skip", .clear("Skip")), ("stop the run", .clear("Stop the run")),
            ("go with option one", .clear("Go with option one")), ("option one", .clear("Skip")),
            ("stop", .unsure("Stop the run")),
        ])
    }

    func testEmojiAndPunctuationInLabelsDoNotMatter() {
        check(["⚡ Send all now", "🕓 Keep queued"], [
            ("send all now", .clear("⚡ Send all now")), ("keep queued", .clear("🕓 Keep queued")),
            ("send all", .unsure("⚡ Send all now")),
        ])
    }

    func testNoLabelsMeansNoMatch() {
        XCTAssertEqual(ActionLabelMatcher.match("go", labels: []), .none)
    }

    func testPermissionVerdicts() {
        let table: [(String, ActionLabelMatcher.PermissionVerdict?)] = [
            ("allow", .allow), ("Allow it.", .allow), ("yes", .allow), ("OK", .allow), ("go ahead", .allow),
            ("allow once please", .allow), ("yes, allow it", .allow), ("approve", .allow),
            ("always", .always), ("always allow", .always), ("Always allow it", .always),
            ("deny", .deny), ("Deny it.", .deny), ("no", .deny), ("don't", .deny), ("do not allow that", .deny),
            ("reject", .deny), ("no, deny it", .deny),
            ("what does it do", nil), ("allow it but only this once in the repo", nil), ("", nil), ("maybe", nil),
        ]
        for (utterance, expected) in table {
            XCTAssertEqual(ActionLabelMatcher.permissionVerdict(utterance), expected, "\u{201C}\(utterance)\u{201D}")
        }
    }

    func testSimilarity() {
        XCTAssertEqual(ActionLabelMatcher.similarity("postgres", "postgres"), 1)
        XCTAssertEqual(ActionLabelMatcher.similarity("postgress", "postgres"), 1 - 1.0 / 9, accuracy: 0.0001)
        XCTAssertEqual(ActionLabelMatcher.similarity("", "go"), 0)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'VoiceTests.ActionLabelMatcherTests'`
Expected: build FAILS — `cannot find 'ActionLabelMatcher' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/Voice/ActionLabelMatcher.swift`:

```swift
import Foundation

/// What an utterance says about a set of labels (spec 2026-10-03 §4).
public enum ActionMatch: Equatable, Sendable {
    /// The utterance is this label, or this label with filler: send it,
    /// with a read-back and a moment to cancel.
    case clear(String)
    /// Close to this label: ask "Did you mean …?" and send only on yes.
    case unsure(String)
    /// Not an answer to the options: send it as a spoken reply.
    case none
}

/// Matches what was heard against the labels of the item or prompt just
/// read out. The journal accepts an action only when it equals one of the
/// item's labels exactly, so the result is always one of `labels` as
/// written: a wrong match can pick the wrong real label, never invent one.
public enum ActionLabelMatcher {
    public static func match(_ utterance: String, labels: [String]) -> ActionMatch {
        let heard = VoiceText.words(utterance)
        guard !heard.isEmpty, !labels.isEmpty else { return .none }
        let labelWords = labels.map(VoiceText.words)
        // Filler never includes a word a label needs: every word of a label
        // made only of filler ("Go", "Yes"), and the telling words of the
        // others ("close" in "Close it", whose "it" stays filler).
        var protected: Set<String> = []
        for words in labelWords {
            let telling = words.filter { !baseFiller.contains($0) }
            protected.formUnion(telling.isEmpty ? words : telling)
        }
        let filler = baseFiller.subtracting(protected)
        let core = heard.filter { !filler.contains($0) }
        let labelCores = labelWords.map { $0.filter { !filler.contains($0) } }

        // 1. The label itself, with or without filler around it.
        if let exact = labelWords.firstIndex(of: heard) { return .clear(labels[exact]) }
        let sameCore = labelCores.indices.filter { !labelCores[$0].isEmpty && labelCores[$0] == core }
        if sameCore.count == 1 { return .clear(labels[sameCore[0]]) }
        if let first = sameCore.first { return .unsure(labels[first]) }
        // 2. "Option one", "the second one", "the last one".
        if let index = ordinal(heard, count: labels.count) { return .clear(labels[index]) }
        guard !core.isEmpty else { return .none }

        // 3. Near misses, best first. A tie goes to the earlier label.
        var best: (score: Double, index: Int)?
        func offer(_ score: Double, _ index: Int) {
            if best == nil || score > best!.score { best = (score, index) }
        }
        for (index, words) in labelCores.enumerated() where !words.isEmpty {
            if core.count < words.count, contains(words, run: core) {
                // Part of a label: "merge" for "Merge now".
                offer(0.9 * Double(core.count) / Double(words.count) + 0.05, index)
            } else if let extras = extras(in: core, around: words) {
                // The label inside a few more words: "go, I think".
                if extras.count <= maxExtras, !extras.contains(where: blockers.contains) {
                    offer(0.8 - 0.05 * Double(extras.count), index)
                }
            } else {
                let similarity = similarity(core.joined(separator: " "), words.joined(separator: " "))
                if similarity >= fuzzyThreshold { offer(0.7 * similarity, index) }
            }
        }
        if let best { return .unsure(labels[best.index]) }
        return .none
    }

    // MARK: Tool permissions

    /// What was said to a tool-permission prompt. Its three buttons are
    /// "Allow once", "Always allow <tool> (session)" and "Deny"; nobody
    /// says those labels, so the verdict is read from the words instead.
    public enum PermissionVerdict: String, Equatable, Sendable { case allow, always, deny }

    public static func permissionVerdict(_ utterance: String) -> PermissionVerdict? {
        let words = VoiceText.words(utterance).filter { !politeness.contains($0) }
        return permissionTable[words.joined(separator: " ")]
    }

    private static let politeness: Set<String> = ["please", "um", "uh", "er", "thanks", "thank", "you", "just", "it", "that", "this"]
    private static let permissionTable: [String: PermissionVerdict] = {
        let phrases: [PermissionVerdict: [String]] = [
            .allow: ["allow", "allow once", "yes", "yeah", "yep", "ok", "okay", "approve", "approved", "go ahead",
                     "do", "run", "fine", "sure", "permit", "yes allow", "let"],
            .always: ["always", "always allow", "allow always", "yes always"],
            .deny: ["deny", "denied", "no", "nope", "reject", "refuse", "block", "dont", "dont allow", "do not allow",
                    "dont run", "do not run", "stop", "cancel", "no deny", "no dont"],
        ]
        var out: [String: PermissionVerdict] = [:]
        for (verdict, list) in phrases { for phrase in list { out[phrase] = verdict } }
        return out
    }()

    // MARK: Rules

    static let maxExtras = 3
    static let fuzzyThreshold = 0.8

    /// Words that carry no choice. Deliberately broad: anything here that
    /// is also in a label stops being filler for that set of labels.
    static let baseFiller: Set<String> = [
        "yes", "yeah", "yep", "ok", "okay", "please", "um", "uh", "er", "erm", "thanks", "thank", "you",
        "i", "id", "ill", "we", "would", "like", "want", "choose", "pick", "select", "take", "say", "said",
        "lets", "go", "with", "for", "the", "that", "this", "one", "option", "answer", "it", "is", "its",
        "to", "do", "a", "an", "just", "think", "should", "definitely", "probably", "then", "and", "so",
    ]

    /// An utterance with one of these beside the label is not a choice:
    /// "don't go", "what does wait mean".
    static let blockers: Set<String> = [
        "not", "dont", "never", "neither", "nor", "cant", "wont", "shouldnt", "no", "without", "instead",
        "why", "what", "how", "when", "which", "who", "does", "explain", "mean", "means", "but", "if", "unless",
    ]

    private static let ordinals: [String: Int] = ["first": 0, "second": 1, "third": 2, "fourth": 3]
    private static let numbers: [String: Int] = ["one": 0, "two": 1, "three": 2, "four": 3, "1": 0, "2": 1, "3": 2, "4": 3]
    private static let ordinalLead: Set<String> = [
        "yes", "yeah", "ok", "okay", "please", "um", "uh", "i", "ill", "id", "take", "pick", "choose", "go",
        "with", "for", "lets", "the", "say", "think", "like", "would", "want",
    ]

    /// The index named by "option two", "the second one", "the last".
    /// The whole utterance must be the reference: "check the tests first"
    /// names nothing.
    private static func ordinal(_ heard: [String], count: Int) -> Int? {
        let words = heard.filter { !ordinalLead.contains($0) }
        let index: Int?
        switch words.count {
        case 1:
            index = words[0] == "last" ? count - 1 : ordinals[words[0]]
        case 2:
            if ["option", "number", "choice", "answer"].contains(words[0]) {
                index = numbers[words[1]]
            } else if ["one", "option", "choice", "answer"].contains(words[1]) {
                index = words[0] == "last" ? count - 1 : ordinals[words[0]]
            } else {
                index = nil
            }
        default:
            index = nil
        }
        guard let index, index >= 0, index < count else { return nil }
        return index
    }

    private static func contains(_ words: [String], run: [String]) -> Bool {
        guard !run.isEmpty, run.count <= words.count else { return false }
        return (0...(words.count - run.count)).contains { Array(words[$0..<($0 + run.count)]) == run }
    }

    /// The words of `core` outside the first place `label` appears in it,
    /// or `nil` when it does not appear (or is all of it).
    private static func extras(in core: [String], around label: [String]) -> [String]? {
        guard core.count > label.count else { return nil }
        for start in 0...(core.count - label.count) where Array(core[start..<(start + label.count)]) == label {
            return Array(core[..<start]) + Array(core[(start + label.count)...])
        }
        return nil
    }

    /// 1 for the same string, 0 for nothing in common (Levenshtein
    /// distance over the longer length).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'VoiceTests.ActionLabelMatcherTests'`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Voice/ActionLabelMatcher.swift MatronShared/Tests/VoiceTests/ActionLabelMatcherTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: match what was said against an item's or prompt's labels" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Voice value types and the fixed phrases

**Files:**
- Create: `MatronShared/Sources/Voice/VoiceTypes.swift`, `MatronShared/Sources/Voice/VoicePhrases.swift`
- Test: `MatronShared/Tests/VoiceTests/VoiceTypesTests.swift` (new)

**Interfaces:**
- Consumes: `JournalTimelineMapper.askUserEvent(fromPrompt:)` (`JournalTimelineMapper.swift:295`, the timeline's own prompt decoding), `TrackerItem` (`TrackerItem.swift:78`, `offeredActions` at 181), `ConsentLink.parse` (`ConsentLink.swift:25`), Task 5's `PermissionVerdict`.
- Produces (MatronVoice):
  - `struct SpokenReply { convoID, seq: Int64, short, more: String?, sections: [String] }`.
  - `struct VoiceItem { id, kind: ItemKind, convoID, title, labels, sections, needsScreen }` with `init(_ item: TrackerItem, sections:)` and `static func needsScreen(_:)`.
  - `struct VoicePrompt { convoID, seq, question, options: [Option{label,value}], allowsFreeText, permission: Permission{tool,detail}? }` with `init?(event: JournalEvent)`, `isPermission`, `labels`, `option(for:)`.
  - `enum VoiceSubject { reply, item, prompt }`; `struct VoiceEntry: Identifiable { id, convoID, convoTitle, boxName, subject }` with factories `.reply`, `.item`, `.prompt` and `labels`.
  - `enum VoicePhrases` — every fixed line, `fixed: [String]`, `needsYou(_:)`, `sending(_:)`, `didYouMean(_:)`, `busy(_:)`, `options(_:)`, `item(_:)`, `prompt(_:boxName:)`, `reading(_:inQueue:)`.

The test for `VoicePrompt` reuses `NeedsYouQueueTests.permissionID`, which Task 7 creates; until then this task's test file declares the same constant locally (Step 1's code does), and Task 7 Step 1 switches it over.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/VoiceTests/VoiceTypesTests.swift` with the code below, but with `let id = NeedsYouQueueTests.permissionID` in `testPermissionDetailIsCutAtEightyCharacters` written as `let id = "0b6f4c3e-8a7d-4e21-9f2a-3c5d7e9a1b2c"` for now:

```swift
import XCTest
import MatronJournal
import MatronModels
@testable import MatronVoice

final class VoiceTypesTests: XCTestCase {
    private func promptEvent(_ payload: [String: Any], type: String = "prompt") -> JournalEvent {
        JournalEvent(seq: 9, convoID: "c1", ts: Date(timeIntervalSince1970: 1), sender: "agent:bev", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    func testAskPromptDecodes() throws {
        let prompt = try XCTUnwrap(VoicePrompt(event: promptEvent([
            "question": "Which database?", "allows_free_text": true,
            "options": ["Postgres", ["id": "s", "label": "SQLite", "value": "sqlite"]],
        ])))
        XCTAssertEqual(prompt.seq, 9); XCTAssertEqual(prompt.convoID, "c1")
        XCTAssertEqual(prompt.labels, ["Postgres", "SQLite"])
        XCTAssertEqual(prompt.options.map(\.value), ["Postgres", "sqlite"])
        XCTAssertTrue(prompt.allowsFreeText); XCTAssertFalse(prompt.isPermission)
    }

    func testAPromptWithNoOptionsTakesFreeText() throws {
        let prompt = try XCTUnwrap(VoicePrompt(event: promptEvent(["question": "What should the title be?"])))
        XCTAssertEqual(prompt.options, []); XCTAssertTrue(prompt.allowsFreeText)
    }

    func testOnlyAPromptRowIsAPrompt() {
        XCTAssertNil(VoicePrompt(event: promptEvent(["body": "hi"], type: "text")))
    }

    /// Ordinary buttons whose values merely start with `perm` are not a
    /// permission card.
    func testPermissionNeedsTheBridgesButtonValues() throws {
        let fake = try XCTUnwrap(VoicePrompt(event: promptEvent([
            "question": "Permission to proceed?",
            "options": [["id": "a", "label": "Allow", "value": "perm:allow"], ["id": "b", "label": "Deny", "value": "perm:deny"]],
        ])))
        XCTAssertFalse(fake.isPermission)
    }

    func testPermissionDetailIsCutAtEightyCharacters() throws {
        let id = NeedsYouQueueTests.permissionID
        let long = String(repeating: "x", count: 200)
        let prompt = try XCTUnwrap(VoicePrompt(event: promptEvent([
            "question": "🔐 Permission: Claude wants to run Bash\n\(long)",
            "options": [["id": "a", "label": "Allow once", "value": "perm:\(id):allow"],
                        ["id": "d", "label": "Deny", "value": "perm:\(id):deny"]],
        ])))
        XCTAssertEqual(prompt.permission?.detail.count, 80)
    }

    func testItemNeedsTheScreenForSecretsAndConsent() {
        func item(labels: [String] = [], links: [TrackerLink] = []) -> TrackerItem {
            TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "T", labels: labels, links: links,
                        originConvoID: "c1", actions: ["Go"])
        }
        XCTAssertFalse(VoiceItem.needsScreen(item()))
        XCTAssertTrue(VoiceItem.needsScreen(item(labels: ["secret"])))
        XCTAssertTrue(VoiceItem.needsScreen(item(labels: ["consent"])))
        XCTAssertTrue(VoiceItem.needsScreen(item(links: [TrackerLink(url: "matron://consent/spawn/req_1")])))
        let voice = VoiceItem(item(labels: ["secret"]), sections: [])
        XCTAssertEqual(VoiceEntry.item(voice, convoTitle: "T").labels, [], "nothing to tap for a screen-only item")
        XCTAssertEqual(VoiceItem(item(), sections: ["Body."]).labels, ["Go"])
    }

    func testPhrases() {
        XCTAssertEqual(VoicePhrases.needsYou(0), "Nothing needs you.")
        XCTAssertEqual(VoicePhrases.needsYou(1), "One thing needs you.")
        XCTAssertEqual(VoicePhrases.needsYou(3), "Three things need you.")
        XCTAssertEqual(VoicePhrases.needsYou(21), "Twenty-one things need you.")
        XCTAssertEqual(VoicePhrases.sending("Go"), "Sending: Go.")
        XCTAssertEqual(VoicePhrases.didYouMean("Allow once"), "Did you mean Allow once?")
        XCTAssertEqual(VoicePhrases.busy("bev"), "bev is busy. It will get this when it finishes.")
        XCTAssertEqual(VoicePhrases.busy(nil), "The agent is busy. It will get this when it finishes.")
        XCTAssertEqual(VoicePhrases.options(["Go", "Wait"]), "Options: Go, Wait.")
        XCTAssertTrue(VoicePhrases.fixed.contains("Three things need you."))
    }

    func testReadings() {
        let reply = VoiceEntry.reply(SpokenReply(convoID: "c1", seq: 5, short: "The deploy finished."), convoTitle: "Auth refactor")
        XCTAssertEqual(VoicePhrases.reading(reply, inQueue: false), "The deploy finished.")
        XCTAssertEqual(VoicePhrases.reading(reply, inQueue: true), "Auth refactor. The deploy finished.")

        let item = VoiceEntry.item(VoiceItem(id: "it_1", kind: .decision, convoID: "c1", title: "Ship the promo page",
                                             labels: ["Go", "Wait"]), convoTitle: "Promo")
        XCTAssertEqual(VoicePhrases.reading(item, inQueue: true), "A decision: Ship the promo page. Options: Go, Wait.")
        let secret = VoiceEntry.item(VoiceItem(id: "it_2", kind: .question, convoID: "c1", title: "AWS key", needsScreen: true),
                                     convoTitle: "Promo")
        XCTAssertEqual(VoicePhrases.reading(secret, inQueue: true), "That one needs the screen. It's in your tracker.")

        let ask = VoiceEntry.prompt(VoicePrompt(convoID: "c1", seq: 9, question: "Which database?",
                                                options: [.init(label: "Postgres", value: "p"), .init(label: "SQLite", value: "s")]),
                                    convoTitle: "Auth refactor", boxName: "bev")
        XCTAssertEqual(VoicePhrases.reading(ask, inQueue: false), "Which database? Options: Postgres, SQLite.")
        XCTAssertEqual(VoicePhrases.reading(ask, inQueue: true), "Auth refactor. Which database? Options: Postgres, SQLite.")

        let permission = VoicePrompt(convoID: "c1", seq: 10, question: "", options: [],
                                     permission: .init(tool: "Bash", detail: "git push origin main"))
        XCTAssertEqual(VoicePhrases.reading(.prompt(permission, convoTitle: "Auth refactor", boxName: "bev"), inQueue: false),
                       "bev wants to run a command: git push origin main. Allow or deny?")
        XCTAssertEqual(VoicePhrases.reading(.prompt(permission, convoTitle: "Auth refactor", boxName: "bev"), inQueue: true),
                       "In Auth refactor. bev wants to run a command: git push origin main. Allow or deny?")
        let edit = VoicePrompt(convoID: "c1", seq: 11, question: "", permission: .init(tool: "Edit", detail: ""))
        XCTAssertEqual(VoicePhrases.reading(.prompt(edit, convoTitle: "", boxName: nil), inQueue: true),
                       "The agent wants to use Edit. Allow or deny?")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceTypesTests'`
Expected: build FAILS — `cannot find 'VoicePrompt' in scope`.

- [ ] **Step 3: Implement the types**

Create `MatronShared/Sources/Voice/VoiceTypes.swift`:

```swift
import Foundation
import MatronChat
import MatronEvents
import MatronJournal
import MatronModels

/// One reply as voice mode says it, in the three levels of spec 2026-10-03
/// §1: `short` when the turn ends, `more` on the first "more", then
/// `sections` (the message itself, about a minute each).
public struct SpokenReply: Equatable, Sendable {
    public let convoID: String
    /// The reply's journal seq: what "already heard" is measured against.
    public let seq: Int64
    public let short: String
    public let more: String?
    public let sections: [String]

    public init(convoID: String, seq: Int64, short: String, more: String? = nil, sections: [String] = []) {
        self.convoID = convoID; self.seq = seq; self.short = short; self.more = more; self.sections = sections
    }
}

/// A tracker item as voice mode reads and answers it.
public struct VoiceItem: Equatable, Sendable {
    public let id: String
    public let kind: ItemKind
    public let convoID: String
    public let title: String
    /// The item's action labels while it is open; `[]` when it has none.
    public let labels: [String]
    /// The body through the cleaner, for "more".
    public let sections: [String]
    /// A secret request or a consent card: it cannot be answered by voice.
    public let needsScreen: Bool

    public init(id: String, kind: ItemKind, convoID: String, title: String, labels: [String] = [],
                sections: [String] = [], needsScreen: Bool = false) {
        self.id = id; self.kind = kind; self.convoID = convoID; self.title = title
        self.labels = labels; self.sections = sections; self.needsScreen = needsScreen
    }

    /// `sections` come from the caller because the cleaner lives beside the
    /// Markdown renderers, which this module does not import.
    public init(_ item: TrackerItem, sections: [String]) {
        self.init(id: item.id, kind: item.kind, convoID: item.originConvoID, title: item.title,
                  labels: item.offeredActions, sections: sections, needsScreen: Self.needsScreen(item))
    }

    /// Secret requests carry the `secret` label (matron-bridge
    /// `lib/secret-requests.js`); consent asks carry a consent link and
    /// the `consent` label (matron-journal `src/consent-items.js`).
    public static func needsScreen(_ item: TrackerItem) -> Bool {
        item.labels.contains("secret") || item.labels.contains("consent")
            || item.links.contains { ConsentLink.parse($0.url) != nil }
    }
}

/// An ask-user or tool-permission prompt as voice mode reads and answers
/// it. Answered with the `prompt_reply` op: `choice` is an option's
/// `value`, or `text` for a free answer.
public struct VoicePrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    /// A tool-permission card's two facts: the tool, and what it would run.
    public struct Permission: Equatable, Sendable {
        public let tool: String
        public let detail: String
        public init(tool: String, detail: String) { self.tool = tool; self.detail = detail }
    }

    public let convoID: String
    /// The prompt's journal seq: `prompt_reply.target_seq`.
    public let seq: Int64
    public let question: String
    public let options: [Option]
    public let allowsFreeText: Bool
    public let permission: Permission?

    public init(convoID: String, seq: Int64, question: String, options: [Option] = [],
                allowsFreeText: Bool = false, permission: Permission? = nil) {
        self.convoID = convoID; self.seq = seq; self.question = question; self.options = options
        self.allowsFreeText = allowsFreeText; self.permission = permission
    }

    public var isPermission: Bool { permission != nil }
    public var labels: [String] { options.map(\.label) }

    /// The option a spoken verdict stands for: the bridge's permission
    /// buttons carry `perm:<request id>:allow|always|deny` as their value.
    public func option(for verdict: ActionLabelMatcher.PermissionVerdict) -> Option? {
        options.first { $0.value.hasSuffix(":\(verdict.rawValue)") }
    }

    /// From a `prompt` journal row, through the decoding the timeline uses
    /// (`JournalTimelineMapper.askUserEvent(fromPrompt:)`).
    public init?(event: JournalEvent) {
        guard event.type == JournalEventType.prompt else { return nil }
        let ask = JournalTimelineMapper.askUserEvent(fromPrompt: event.payload)
        let options: [Option]
        var allowsFreeText = false
        switch ask.kind {
        case .choice(let list, let other), .multiChoice(let list, let other):
            options = list.map { Option(label: $0.label, value: $0.value) }
            allowsFreeText = other
        case .text, .boolean:
            options = []
            allowsFreeText = true
        }
        self.init(convoID: event.convoID, seq: event.seq, question: ask.prompt, options: options,
                  allowsFreeText: allowsFreeText, permission: Self.permission(question: ask.prompt, options: options))
    }

    private static let permissionValue = try! NSRegularExpression(
        pattern: #"^perm:[0-9a-f-]{36}:(allow|always|deny)$"#)
    /// The command a permission card shows is cut here before it is said
    /// (spec §3, "What is spoken").
    public static let permissionDetailLimit = 80

    /// A tool-permission card is a `prompt` whose every button answers
    /// `perm:<uuid>:<verdict>` (matron-bridge `lib/permission-prompt.js`,
    /// `permissionButtons`). Its text is "🔐 Permission: Claude wants to
    /// run <tool>" and, on the lines after, a preview of the input.
    static func permission(question: String, options: [Option]) -> Permission? {
        guard options.count >= 2, options.allSatisfy({ option in
            permissionValue.firstMatch(in: option.value, range: NSRange(option.value.startIndex..., in: option.value)) != nil
        }) else { return nil }
        let lines = question.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let head = lines.first ?? ""
        let tool = head.range(of: "wants to run ").map { String(head[$0.upperBound...]) } ?? "a tool"
        let detail = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return Permission(tool: tool.trimmingCharacters(in: .whitespaces),
                          detail: String(detail.prefix(permissionDetailLimit)))
    }
}

/// What voice mode can read out and take an answer to.
public enum VoiceSubject: Equatable, Sendable {
    case reply(SpokenReply)
    case item(VoiceItem)
    case prompt(VoicePrompt)
}

/// One thing for voice mode to say: a subject, plus where it came from.
/// `id` is stable across rebuilds (`prompt:<seq>`, `item:<id>`,
/// `reply:<convo>:<seq>`), so a thing already said is not said twice.
public struct VoiceEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let convoID: String
    public let convoTitle: String
    public let boxName: String?
    public let subject: VoiceSubject

    public init(id: String, convoID: String, convoTitle: String, boxName: String? = nil, subject: VoiceSubject) {
        self.id = id; self.convoID = convoID; self.convoTitle = convoTitle; self.boxName = boxName; self.subject = subject
    }

    public static func reply(_ reply: SpokenReply, convoTitle: String, boxName: String? = nil) -> VoiceEntry {
        VoiceEntry(id: "reply:\(reply.convoID):\(reply.seq)", convoID: reply.convoID, convoTitle: convoTitle,
                   boxName: boxName, subject: .reply(reply))
    }

    public static func item(_ item: VoiceItem, convoTitle: String, boxName: String? = nil) -> VoiceEntry {
        VoiceEntry(id: "item:\(item.id)", convoID: item.convoID, convoTitle: convoTitle, boxName: boxName, subject: .item(item))
    }

    public static func prompt(_ prompt: VoicePrompt, convoTitle: String, boxName: String? = nil) -> VoiceEntry {
        VoiceEntry(id: "prompt:\(prompt.seq)", convoID: prompt.convoID, convoTitle: convoTitle, boxName: boxName,
                   subject: .prompt(prompt))
    }

    /// The labels on offer, for the screen's buttons and the matcher.
    public var labels: [String] {
        switch subject {
        case .reply: return []
        case .item(let item): return item.needsScreen ? [] : item.labels
        case .prompt(let prompt): return prompt.labels
        }
    }
}
```

- [ ] **Step 4: Implement the phrases**

Create `MatronShared/Sources/Voice/VoicePhrases.swift`:

```swift
import Foundation
import MatronModels

/// Every fixed thing voice mode says. One place, so the wording can be
/// read and changed without hunting through the engine, and so the player
/// knows which lines are worth caching (`fixed`).
public enum VoicePhrases {
    public static let sent = "Sent."
    public static let cancelled = "Cancelled."
    public static let notSent = "OK, not sent."
    public static let denied = "Denied."
    public static let queueDone = "That's everything."
    public static let moreHint = "Say more for the detail."
    public static let goOn = "Go on?"
    public static let wholeMessage = "That's the whole message."
    public static let nothingToRepeat = "There's nothing to repeat."
    public static let needsScreen = "That one needs the screen. It's in your tracker."
    public static let noConnection = "No connection. I'll send it when you're back online."
    public static let notSentOffline = "No connection. That wasn't sent."
    public static let permissionExpired = "That permission request timed out and was denied."
    public static let allowOrDeny = "Say allow or deny."
    public static let nowhereToSend = "There's no conversation to send that to."
    public static let talkOverOff = "I keep hearing myself on this speaker, so talking over me is off. Tap the screen to interrupt."
    public static let microphoneFailed = "I can't use the microphone."

    /// The lines said often enough to keep on the phone after first use
    /// (spec §3, "Playing").
    public static let fixed: [String] = [
        sent, cancelled, notSent, denied, queueDone, moreHint, goOn, wholeMessage, nothingToRepeat, needsScreen,
        noConnection, notSentOffline, permissionExpired, allowOrDeny, nowhereToSend, talkOverOff, microphoneFailed,
    ] + (0...12).map(needsYou)

    /// "Nothing needs you." / "One thing needs you." / "Three things need you."
    public static func needsYou(_ count: Int) -> String {
        switch count {
        case ..<1: return "Nothing needs you."
        case 1: return "One thing needs you."
        default: return "\(capitalised(spelled(count))) things need you."
        }
    }

    public static func sending(_ label: String) -> String { "Sending: \(label)." }
    public static func didYouMean(_ label: String) -> String { "Did you mean \(label)?" }

    public static func busy(_ boxName: String?) -> String {
        "\(boxName ?? "The agent") is busy. It will get this when it finishes."
    }

    /// "Options: Go, Wait." Empty for no labels.
    public static func options(_ labels: [String]) -> String {
        labels.isEmpty ? "" : "Options: \(labels.joined(separator: ", "))."
    }

    public static func item(_ item: VoiceItem) -> String {
        if item.needsScreen { return needsScreen }
        let lead: String
        switch item.kind {
        case .question: lead = "A question"
        case .decision: lead = "A decision"
        case .task: lead = "A task"
        }
        return joined(["\(lead): \(ended(item.title))", options(item.labels)])
    }

    public static func prompt(_ prompt: VoicePrompt, boxName: String?) -> String {
        if let permission = prompt.permission {
            let who = boxName ?? "The agent"
            let what = permission.tool == "Bash" ? "run a command" : "use \(permission.tool)"
            let detail = permission.detail.isEmpty ? "." : ": \(ended(permission.detail))"
            return "\(who) wants to \(what)\(detail) Allow or deny?"
        }
        return joined([ended(prompt.question), options(prompt.labels)])
    }

    /// What is said for an entry. In the queue the conversation is named
    /// first, since each entry may come from a different one.
    public static func reading(_ entry: VoiceEntry, inQueue: Bool) -> String {
        let place = inQueue && !entry.convoTitle.isEmpty ? "\(ended(entry.convoTitle))" : ""
        switch entry.subject {
        case .reply(let reply): return joined([place, reply.short])
        case .item(let item): return self.item(item)
        case .prompt(let prompt):
            let lead = prompt.isPermission && !place.isEmpty ? "In \(place)" : place
            return joined([lead, self.prompt(prompt, boxName: entry.boxName)])
        }
    }

    // MARK: Helpers

    private static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `text` ending like a sentence.
    static func ended(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    private static let speller: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()

    static func spelled(_ number: Int) -> String {
        speller.string(from: NSNumber(value: number)) ?? String(number)
    }

    private static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceTypesTests'`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Voice/VoiceTypes.swift MatronShared/Sources/Voice/VoicePhrases.swift MatronShared/Tests/VoiceTests/VoiceTypesTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: what voice mode reads out, and every fixed line it says" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `NeedsYouQueue` — what voice mode opens to

**Files:**
- Create: `MatronShared/Sources/Voice/NeedsYouQueue.swift`
- Modify: `MatronShared/Tests/VoiceTests/VoiceTypesTests.swift` (the local id becomes `NeedsYouQueueTests.permissionID`)
- Test: `MatronShared/Tests/VoiceTests/NeedsYouQueueTests.swift` (new)

**Interfaces:**
- Consumes: Task 2's `unansweredPrompts(since:)`; `JournalStore.items(scope: .all)` (`JournalStore+Items.swift:279`, ordered `rank`, `num`); `JournalStore.conversations(now:)` (`JournalStore.swift:1527`, visible top-level rows, newest activity first) with `ConversationRecord.unreadCount`, `sessionState`, `muted`, `lastActivityTS`, `agentDeviceID`; `JournalStore.agentNames()`; `SessionTag.splitTitle` (`SessionTag.swift:41`, peels the `[ab] ` session short); `TrackerItem.needsUser` (`TrackerItem.swift:176`).
- Produces (MatronVoice):
  - `struct NeedsYouEntry: Identifiable { kind: Kind{permission(VoicePrompt), prompt(VoicePrompt), item(TrackerItem), unseenReply}, convoID, convoTitle, boxName, title; id }` — ids `prompt:<seq>`, `item:<id>`, `convo:<id>`.
  - `struct QueueConversation { id, title, boxName, unreadCount, sessionState, lastActivity, muted }`.
  - `NeedsYouQueue.build(prompts:items:conversations:now:) -> [NeedsYouEntry]`, `.summary(_:) -> String`, `.permissionTTL` (300), `.promptMaxAge` (86,400), `cleanTitle(_:)`.
  - `JournalStore.needsYouEntries(now:) throws -> [NeedsYouEntry]`.

Where each of the four kinds lives today: prompts are `prompt` rows in the event mirror (no index of pending ones exists; Task 2 added the read); items awaiting the user are `item` rows with `state = 'open' AND awaiting = 'user'` (the Decisions tab's `ItemsPanelViewModel.awaitingYou`); "a reply he has not seen" is `conversation.unread_count`, maintained by `applyOne` (`JournalStore.swift:1329-1331`) and cleared by `read_marker`.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/VoiceTests/NeedsYouQueueTests.swift`:

```swift
import XCTest
import MatronJournal
import MatronModels
@testable import MatronVoice

final class NeedsYouQueueTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 10_000)
    static let permissionID = "0b6f4c3e-8a7d-4e21-9f2a-3c5d7e9a1b2c"

    static func promptRow(_ seq: Int64, convo: String = "c1", age: TimeInterval = 10, title: String = "[ab] Auth refactor",
                          agent: String? = "bev", payload: [String: Any]) -> UnansweredPromptRow {
        let event = JournalEvent(seq: seq, convoID: convo, ts: now.addingTimeInterval(-age), sender: "agent:bev",
                                 type: "prompt", payloadData: try! JSONSerialization.data(withJSONObject: payload))
        return UnansweredPromptRow(event: event, convoTitle: title, agentName: agent)
    }

    static func ask(_ seq: Int64, convo: String = "c1", age: TimeInterval = 10) -> UnansweredPromptRow {
        promptRow(seq, convo: convo, age: age, payload: ["question": "Which database?\nPick one.", "options": ["Postgres", "SQLite"]])
    }

    static func permission(_ seq: Int64, convo: String = "c1", age: TimeInterval = 10, tool: String = "Bash") -> UnansweredPromptRow {
        promptRow(seq, convo: convo, age: age, payload: [
            "question": "🔐 Permission: Claude wants to run \(tool)\ngit push origin main",
            "mode": "pick_one",
            "options": [
                ["id": "perm-allow", "label": "Allow once", "value": "perm:\(permissionID):allow"],
                ["id": "perm-always", "label": "Always allow \(tool) (session)", "value": "perm:\(permissionID):always"],
                ["id": "perm-deny", "label": "Deny", "value": "perm:\(permissionID):deny"],
            ],
        ])
    }

    static func item(_ id: String, num: Int, rank: Double, awaiting: ItemAwaiting? = .user, state: ItemState = .open,
                     convo: String = "c1", title: String? = nil) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: .question, state: state, awaiting: awaiting, rank: rank,
                    title: title ?? "Item \(num)", originConvoID: convo)
    }

    static func convo(_ id: String, unread: Int = 1, state: String = "waiting", activity: TimeInterval = 100,
                      muted: Bool = false, title: String? = nil) -> QueueConversation {
        QueueConversation(id: id, title: title ?? "[\(id.prefix(2))] Chat \(id)", boxName: "bev", unreadCount: unread,
                          sessionState: state, lastActivity: Date(timeIntervalSince1970: activity), muted: muted)
    }

    /// Spec §5: permissions, then prompts, then items in tracker order,
    /// then conversations with an unseen reply.
    func testOrderIsPermissionsPromptsItemsThenConversations() {
        let entries = NeedsYouQueue.build(
            prompts: [Self.ask(7, convo: "c2"), Self.permission(9, convo: "c3"), Self.permission(8, convo: "c4")],
            items: [Self.item("it_b", num: 12, rank: 2048), Self.item("it_a", num: 30, rank: 1024),
                    Self.item("it_c", num: 5, rank: 1024)],
            conversations: [Self.convo("c8", activity: 100), Self.convo("c9", activity: 200)],
            now: Self.now)
        XCTAssertEqual(entries.map(\.id),
                       ["prompt:8", "prompt:9", "prompt:7", "item:it_c", "item:it_a", "item:it_b", "convo:c9", "convo:c8"])
    }

    func testTitlesAndConversationNames() {
        let entries = NeedsYouQueue.build(
            prompts: [Self.permission(1), Self.permission(2, tool: "Edit"), Self.ask(3)],
            items: [Self.item("it_a", num: 1, rank: 1, title: "Leavers' page copy")],
            conversations: [Self.convo("c1", unread: 0), Self.convo("c5", title: "[zz] Promo launch")],
            now: Self.now)
        XCTAssertEqual(entries.map(\.title), [
            "bev wants to run a command", "bev wants to use Edit", "Which database?", "Leavers' page copy", "Promo launch",
        ])
        XCTAssertEqual(entries[0].convoTitle, "Auth refactor", "the session short is not said")
        XCTAssertEqual(entries[3].convoTitle, "Chat c1", "an item names its origin conversation")
        XCTAssertEqual(entries[3].boxName, "bev")
        if case .permission(let prompt) = entries[0].kind {
            XCTAssertEqual(prompt.permission, VoicePrompt.Permission(tool: "Bash", detail: "git push origin main"))
            XCTAssertEqual(prompt.option(for: .deny)?.label, "Deny")
            XCTAssertEqual(prompt.option(for: .allow)?.value, "perm:\(Self.permissionID):allow")
        } else {
            XCTFail("the first entry is the permission prompt")
        }
    }

    /// A permission card is denied by the bridge after five minutes; an
    /// ask-user prompt stops being a question after a day.
    func testExpiredPromptsAreLeftOut() {
        let entries = NeedsYouQueue.build(
            prompts: [Self.permission(1, age: 299), Self.permission(2, age: 300), Self.ask(3, age: 86_399), Self.ask(4, age: 86_400)],
            items: [], conversations: [], now: Self.now)
        XCTAssertEqual(entries.map(\.id), ["prompt:1", "prompt:3"])
    }

    func testOnlyOpenItemsAwaitingTheUserCount() {
        let entries = NeedsYouQueue.build(prompts: [], items: [
            Self.item("it_a", num: 1, rank: 1, awaiting: .agent), Self.item("it_b", num: 2, rank: 2, awaiting: nil),
            Self.item("it_c", num: 3, rank: 3, state: .closed), Self.item("it_d", num: 4, rank: 4),
        ], conversations: [], now: Self.now)
        XCTAssertEqual(entries.map(\.id), ["item:it_d"])
    }

    /// A reply is unseen when the conversation has unread messages and its
    /// turn has ended. Muted conversations are left alone, and one already
    /// in the queue for a prompt is not listed twice.
    func testWhichConversationsCountAsAnUnseenReply() {
        let entries = NeedsYouQueue.build(
            prompts: [Self.ask(3, convo: "asked")],
            items: [],
            conversations: [
                Self.convo("read", unread: 0), Self.convo("working", state: "running"), Self.convo("muted", muted: true),
                Self.convo("asked"), Self.convo("done", state: "done"), Self.convo("waiting"),
            ],
            now: Self.now)
        XCTAssertEqual(entries.map(\.id), ["prompt:3", "convo:done", "convo:waiting"])
    }

    func testSummaryForSiri() {
        XCTAssertEqual(NeedsYouQueue.summary([]), "Nothing needs you.")
        let one = NeedsYouQueue.build(prompts: [], items: [Self.item("it_a", num: 1, rank: 1, title: "Approve the claims copy")],
                                      conversations: [], now: Self.now)
        XCTAssertEqual(NeedsYouQueue.summary(one), "One thing needs you. Approve the claims copy.")
        let several = NeedsYouQueue.build(prompts: [Self.permission(1)], items: [Self.item("it_a", num: 1, rank: 1)],
                                          conversations: [Self.convo("c9")], now: Self.now)
        XCTAssertEqual(NeedsYouQueue.summary(several), "Three things need you. The first: bev wants to run a command.")
    }

    /// The store adapter: the same answer from a real mirror.
    func testStoreAdapterReadsTheMirror() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        func event(_ seq: Int64, convo: String, sender: String = "agent:bev", type: String, payload: [String: Any]) -> JournalEvent {
            JournalEvent(seq: seq, convoID: convo, ts: Self.now.addingTimeInterval(-60), sender: sender, type: type,
                         payloadData: try! JSONSerialization.data(withJSONObject: payload))
        }
        _ = try store.applyJournalBatch([
            event(1, convo: "c1", type: "convo_meta", payload: ["title": "[ab] Auth refactor"]),
            event(2, convo: "c1", type: "text", payload: ["body": "Done."]),
            event(3, convo: "c1", type: "session_status", payload: ["state": "waiting"]),
            event(4, convo: "c2", type: "convo_meta", payload: ["title": "[cd] Promo"]),
            event(5, convo: "c2", type: "prompt", payload: ["question": "Ship it?", "options": ["Yes", "No"]]),
        ])
        try store.upsertItems([Self.item("it_a", num: 7, rank: 1, convo: "c1", title: "Pick a colour")])
        let entries = try store.needsYouEntries(now: Self.now)
        XCTAssertEqual(entries.map(\.id), ["prompt:5", "item:it_a", "convo:c1"])
        XCTAssertEqual(entries.map(\.title), ["Ship it?", "Pick a colour", "Auth refactor"])
    }
}
```

In `VoiceTypesTests.testPermissionDetailIsCutAtEightyCharacters`, change the local id to `let id = NeedsYouQueueTests.permissionID`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'VoiceTests.NeedsYouQueueTests'`
Expected: build FAILS — `cannot find 'NeedsYouQueue' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/Voice/NeedsYouQueue.swift`:

```swift
import Foundation
import MatronChat
import MatronJournal
import MatronModels

/// One thing that needs the user, before it is turned into speech: what
/// the queue orders, the app shell counts, and Siri names.
public struct NeedsYouEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case permission(VoicePrompt)
        case prompt(VoicePrompt)
        case item(TrackerItem)
        /// A conversation whose last turn ended with a reply not yet seen.
        case unseenReply
    }

    public let kind: Kind
    public let convoID: String
    /// The conversation's title without its session short.
    public let convoTitle: String
    public let boxName: String?
    /// One line naming the thing: Siri's "the first is …".
    public let title: String

    public var id: String {
        switch kind {
        case .permission(let prompt), .prompt(let prompt): return "prompt:\(prompt.seq)"
        case .item(let item): return "item:\(item.id)"
        case .unseenReply: return "convo:\(convoID)"
        }
    }
}

/// A conversation as the queue sees it: the columns of `ConversationRecord`
/// that decide whether its last reply is waiting to be heard.
public struct QueueConversation: Equatable, Sendable {
    public let id: String
    public let title: String
    public let boxName: String?
    public let unreadCount: Int
    public let sessionState: String
    public let lastActivity: Date?
    public let muted: Bool

    public init(id: String, title: String, boxName: String? = nil, unreadCount: Int, sessionState: String,
                lastActivity: Date? = nil, muted: Bool = false) {
        self.id = id; self.title = title; self.boxName = boxName; self.unreadCount = unreadCount
        self.sessionState = sessionState; self.lastActivity = lastActivity; self.muted = muted
    }
}

/// "What needs you" (spec 2026-10-03 §5), built on the device from what it
/// already syncs:
///
/// 1. tool-permission prompts (they are denied after five minutes),
/// 2. ask-user prompts,
/// 3. tracker items awaiting the user, in tracker order,
/// 4. conversations whose last turn ended with a reply not yet seen.
public enum NeedsYouQueue {
    /// The bridge denies an unanswered permission card after this long
    /// (matron-bridge `DEFAULT_PERMISSION_TIMEOUT_MS`).
    public static let permissionTTL: TimeInterval = 300
    /// An ask-user prompt older than this is history, not a question.
    public static let promptMaxAge: TimeInterval = 24 * 60 * 60

    public static func build(prompts: [UnansweredPromptRow], items: [TrackerItem],
                             conversations: [QueueConversation], now: Date) -> [NeedsYouEntry] {
        var permissions: [NeedsYouEntry] = []
        var asks: [NeedsYouEntry] = []
        var promptConvos: Set<String> = []
        for row in prompts.sorted(by: { $0.event.seq < $1.event.seq }) {
            guard let prompt = VoicePrompt(event: row.event) else { continue }
            let age = now.timeIntervalSince(row.event.ts)
            let title = cleanTitle(row.convoTitle)
            if let permission = prompt.permission {
                guard age < permissionTTL else { continue }
                let what = permission.tool == "Bash" ? "run a command" : "use \(permission.tool)"
                permissions.append(NeedsYouEntry(kind: .permission(prompt), convoID: row.event.convoID, convoTitle: title,
                                                 boxName: row.agentName,
                                                 title: "\(row.agentName ?? "An agent") wants to \(what)"))
            } else {
                guard age < promptMaxAge else { continue }
                asks.append(NeedsYouEntry(kind: .prompt(prompt), convoID: row.event.convoID, convoTitle: title,
                                          boxName: row.agentName, title: firstLine(prompt.question)))
            }
            promptConvos.insert(row.event.convoID)
        }

        let titles = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let awaiting = items.filter(\.needsUser).sorted { ($0.rank, $0.num) < ($1.rank, $1.num) }.map { item in
            NeedsYouEntry(kind: .item(item), convoID: item.originConvoID,
                          convoTitle: cleanTitle(titles[item.originConvoID]?.title ?? ""),
                          boxName: titles[item.originConvoID]?.boxName, title: item.title)
        }

        let unseen = conversations
            .filter { $0.unreadCount > 0 && $0.sessionState != "running" && !$0.muted && !promptConvos.contains($0.id) }
            .sorted { ($0.lastActivity ?? .distantPast, $1.id) > ($1.lastActivity ?? .distantPast, $0.id) }
            .map { convo -> NeedsYouEntry in
                let title = cleanTitle(convo.title)
                return NeedsYouEntry(kind: .unseenReply, convoID: convo.id, convoTitle: title, boxName: convo.boxName,
                                     title: title.isEmpty ? "A reply" : title)
            }

        return permissions + asks + awaiting + unseen
    }

    /// What Siri says for "what needs me" (spec §10): the count and the
    /// first thing's title.
    public static func summary(_ entries: [NeedsYouEntry]) -> String {
        guard let first = entries.first else { return VoicePhrases.needsYou(0) }
        let lead = VoicePhrases.needsYou(entries.count)
        return entries.count == 1 ? "\(lead) \(VoicePhrases.ended(first.title))"
            : "\(lead) The first: \(VoicePhrases.ended(first.title))"
    }

    /// A stored title without the bridge's `[ab] ` session short.
    static func cleanTitle(_ raw: String) -> String {
        SessionTag.splitTitle(raw).title
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return String(line.prefix(80))
    }
}

extension JournalStore {
    /// The queue's inputs, read from this store in one go.
    public func needsYouEntries(now: Date = Date()) throws -> [NeedsYouEntry] {
        let prompts = try unansweredPrompts(since: now.addingTimeInterval(-NeedsYouQueue.promptMaxAge))
        let names = try agentNames()
        let conversations = try conversations(now: now).map { record in
            QueueConversation(id: record.id, title: record.title,
                              boxName: record.agentDeviceID.flatMap { names[$0] },
                              unreadCount: record.unreadCount, sessionState: record.sessionState,
                              lastActivity: record.lastActivityTS.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                              muted: record.muted)
        }
        return NeedsYouQueue.build(prompts: prompts, items: try items(scope: .all),
                                   conversations: conversations, now: now)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'VoiceTests.(NeedsYouQueueTests|VoiceTypesTests)'`
Expected: `Executed 7 tests` and `Executed 8 tests`, both with 0 failures.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Voice/NeedsYouQueue.swift MatronShared/Tests/VoiceTests/NeedsYouQueueTests.swift \
        MatronShared/Tests/VoiceTests/VoiceTypesTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: the what-needs-you queue, built from the local mirror" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `VoiceModeEngine` — the reducer

**Files:**
- Create: `MatronShared/Sources/Voice/VoiceModeEngine.swift`
- Test: `MatronShared/Tests/VoiceTests/VoiceModeEngineTests.swift` (new)

**Interfaces:**
- Consumes: Tasks 4–6 (`VoiceCommand`, `ActionLabelMatcher`, `VoiceEntry`, `VoicePhrases`).
- Produces (MatronVoice): `enum VoiceModeEngine` with
  - `static func reduce(_ state: State, _ event: Event) -> (State, [Effect])` — pure;
  - `Config` (every timing above, `talkOver`, `offerMore`, `falseTriggerLimit` 3, `moreHintLimit` 3);
  - `Phase { idle, listening, sending, confirming, waiting, speaking }`;
  - `Event` — `start(Start)`, `end`, `tap`, `sendTapped`, `actionTapped(String)`, `speechStarted`, `speechEnded`, `words(String)`, `captureFailed`, `transcript(String?)`, `uploadFailed`, `sendFailed`, `arrived(VoiceEntry)`, `resolved(id:expired:)`, `turnStarted(convoID:)`, `turnEnded(convoID:)`, `playbackFinished(Int)`, `timerFired(TimerID)`, `interruption(Interruption)`, `appBackgrounded`, `appForegrounded`, `routeChanged(String)`, `configChanged(Config)`;
  - `Effect` — `activateAudio`, `releaseAudio`, `startCapture(CaptureMode)`, `promoteCapture`, `stopCapture(keep:)`, `play(Utterance)`, `stopPlayback`, `duck`, `restoreVolume`, `earcon(Earcon)`, `upload`, `sendVoiceNote(SendTarget)`, `sendItemAction(itemID:label:)`, `sendPromptReply(convoID:seq:choice:text:)`, `discardRecording`, `startTimer(TimerID, TimeInterval)`, `cancelTimer(TimerID)`, `watch(convoID:)`, `keepScreenAwake(Bool)`, `ended(EndReason)`;
  - `State` (public fields a screen reads: `phase`, `caption`, `labels`, `title`, `boxName`, `current`, `isAgentWorking`, `talkOverAllowed`, `route`);
  - `static func isEcho(_ heard: String, of clip: String) -> Bool` (public: the spike uses it).

How the pieces of the spec map onto it:

| Spec | In the reducer |
|---|---|
| §3 states | `Phase`; `say` → speaking, `listen` → listening, `finishUtterance` → sending, `startConfirm` → speaking then confirming, `wait` → waiting |
| Audio released between turns | `wait()` emits `stopCapture(keep: false)` then `releaseAudio`; `say`/`listen` emit `activateAudio` only when it is not held |
| End of speech | `speechEnded` → `startTimer(.silence, 1.5)` (0.6 when the words so far are a command); `timerFired(.silence)` → `finishUtterance` |
| Talk-over step 1 | speaking + `speechStarted` → `startTimer(.talkOverOnset, 0.3)`; its firing → `duck`, `startTimer(.talkOverWords, 1)` |
| Talk-over step 2 | ducked + words that are not the clip's own → `stopPlayback`, `restoreVolume`, `promoteCapture` (the pre-roll), listening |
| Talk-over step 3 | `timerFired(.talkOverWords)` → `restoreVolume`, `falseTriggers += 1`; at 3 the route joins `talkOverOffRoutes`, the microphone closes, and "…talking over me is off…" is said after the clip |
| Three levels | `level` 1 → `more` → 2 (`SpokenReply.more`) → 3 (`sections[n]` + "Go on?"); `repeat` replays the level |
| §4 | `transcript(_:)`: `ActionLabelMatcher` → `startConfirm(.sending)` / `startConfirm(.didYouMean)` / plain; permissions via `permissionVerdict` |
| §5 | `start(.queue)` says the count and the first entry; `next()` moves on after a send or "skip"; "That's everything." then listens on the last conversation |
| §11 idle end | `startTimer(.idle, 1800)` restarted by every exchange; its firing → `ended(.idle)` |
| §12 | `uploadFailed` → error earcon, `sendVoiceNote` (kept and retried by the runner), "No connection…"; `resolved(expired: true)` on a permission → "That permission request timed out and was denied." |

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/VoiceTests/VoiceModeEngineTests.swift`:

```swift
import XCTest
import MatronModels
@testable import MatronVoice

/// The voice engine, event by event (spec 2026-10-03 §3, §4, §5, §11, §12).
/// No audio, no network, no clock: effects are values.
final class VoiceModeEngineTests: XCTestCase {
    typealias Engine = VoiceModeEngine
    typealias Effect = VoiceModeEngine.Effect

    // MARK: Fixtures

    static let permissionID = "0b6f4c3e-8a7d-4e21-9f2a-3c5d7e9a1b2c"

    static let reply = VoiceEntry.reply(
        SpokenReply(convoID: "c1", seq: 10, short: "The deploy finished. Shall I merge?",
                    more: "Every test passed and the cache was rebuilt.",
                    sections: ["Section one.", "Section two.", "Section three."]),
        convoTitle: "Auth refactor", boxName: "bev")
    static let plainReply = VoiceEntry.reply(SpokenReply(convoID: "c1", seq: 11, short: "Done."),
                                             convoTitle: "Auth refactor", boxName: "bev")
    static let item = VoiceEntry.item(
        VoiceItem(id: "it_1", kind: .decision, convoID: "c2", title: "Ship the promo page", labels: ["Go", "Wait"],
                  sections: ["The page is ready."]),
        convoTitle: "Promo", boxName: "pat")
    static let secret = VoiceEntry.item(
        VoiceItem(id: "it_2", kind: .question, convoID: "c2", title: "AWS key", needsScreen: true), convoTitle: "Promo")
    static let ask = VoiceEntry.prompt(
        VoicePrompt(convoID: "c3", seq: 30, question: "Which database?",
                    options: [.init(label: "Postgres", value: "pg"), .init(label: "SQLite", value: "lite")],
                    allowsFreeText: true),
        convoTitle: "Schema", boxName: "bev")
    static let permission = VoiceEntry.prompt(
        VoicePrompt(convoID: "c1", seq: 40, question: "",
                    options: [.init(label: "Allow once", value: "perm:\(permissionID):allow"),
                              .init(label: "Always allow Bash (session)", value: "perm:\(permissionID):always"),
                              .init(label: "Deny", value: "perm:\(permissionID):deny")],
                    permission: .init(tool: "Bash", detail: "git push origin main")),
        convoTitle: "Auth refactor", boxName: "bev")

    /// Feeds `events` in order; returns the final state and the effects of
    /// the LAST event.
    func run(_ state: Engine.State = Engine.State(), _ events: Engine.Event...) -> (Engine.State, [Effect]) {
        var state = state
        var effects: [Effect] = []
        for event in events { (state, effects) = Engine.reduce(state, event) }
        return (state, effects)
    }

    func started(config: Engine.Config = Engine.Config()) -> Engine.State {
        var state = Engine.State()
        state.config = config
        return run(state, .routeChanged("Speaker"),
                   .start(.conversation(id: "c1", title: "Auth refactor", boxName: "bev"))).0
    }

    /// In `waiting`, as after sending a message.
    func waiting(config: Engine.Config = Engine.Config()) -> Engine.State {
        run(started(config: config), .timerFired(.noSpeech)).0
    }

    /// `entry` has been read out and the engine is listening for an answer.
    func heard(_ entry: VoiceEntry, config: Engine.Config = Engine.Config()) -> Engine.State {
        let (state, _) = run(waiting(config: config), .arrived(entry))
        return run(state, .playbackFinished(state.playing!.id)).0
    }

    /// The user said `text` after `state` started listening; the engine
    /// is now `sending`.
    func said(_ text: String, in state: Engine.State) -> Engine.State {
        run(state, .speechStarted, .words(text), .speechEnded, .timerFired(.silence)).0
    }

    func utterance(_ state: Engine.State) -> String? { state.playing?.text }

    // MARK: Start

    func testStartingInAConversationListens() {
        let (state, effects) = run(Engine.State(), .start(.conversation(id: "c1", title: "Auth refactor", boxName: "bev")))
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(state.title, "Auth refactor")
        XCTAssertEqual(effects, [
            .keepScreenAwake(true), .startTimer(.idle, 1_800), .watch(convoID: "c1"), .activateAudio,
            .earcon(.micOpen), .startCapture(.record), .startTimer(.noSpeech, 8), .startTimer(.maxUtterance, 120),
        ])
    }

    func testStartingTwiceIsIgnored() {
        let state = started()
        let (again, effects) = run(state, .start(.conversation(id: "c9", title: "Other", boxName: nil)))
        XCTAssertEqual(again, state)
        XCTAssertEqual(effects, [])
    }

    func testEventsBeforeStartDoNothing() {
        let (state, effects) = run(Engine.State(), .tap, .speechStarted, .words("hello"), .timerFired(.silence), .arrived(Self.reply))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(effects, [])
    }

    // MARK: Listening and sending

    func testNothingSaidForEightSecondsClosesTheMicrophone() {
        let (state, effects) = run(started(), .timerFired(.noSpeech))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertEqual(effects, [.cancelTimer(.maxUtterance), .stopCapture(keep: false), .releaseAudio])
        XCTAssertFalse(state.audioActive)
    }

    func testSpeechThenSilenceEndsTheUtteranceAndUploadsIt() {
        var (state, effects) = run(started(), .speechStarted)
        XCTAssertEqual(effects, [.cancelTimer(.noSpeech)])
        (state, effects) = run(state, .words("merge it when the tests pass"), .speechEnded)
        XCTAssertEqual(effects, [.startTimer(.silence, 1.5)])
        // He carries on: the count starts again.
        (state, effects) = run(state, .speechStarted)
        XCTAssertEqual(effects, [.cancelTimer(.silence)])
        (state, effects) = run(state, .speechEnded, .timerFired(.silence))
        XCTAssertEqual(state.phase, .sending)
        XCTAssertEqual(effects, [.cancelTimer(.maxUtterance), .startTimer(.idle, 1_800), .stopCapture(keep: true), .upload,
                                 .startTimer(.transcript, 8)])
    }

    func testTheSendButtonAndTheTwoMinuteLimitEndTheUtteranceToo() {
        XCTAssertEqual(run(started(), .speechStarted, .sendTapped).0.phase, .sending)
        XCTAssertEqual(run(started(), .speechStarted, .timerFired(.maxUtterance)).0.phase, .sending)
    }

    /// The detector may say nothing at all: words alone start the count.
    func testWordsWithoutADetectorEventStillEndTheUtterance() {
        let (state, effects) = run(started(), .words("hello there"))
        XCTAssertEqual(effects, [.cancelTimer(.noSpeech), .startTimer(.silence, 1.5)])
        XCTAssertEqual(run(state, .timerFired(.silence)).0.phase, .sending)
    }

    func testATranscriptThatAnswersNothingIsSentAsAVoiceNote() {
        let (state, effects) = run(said("merge it when the tests pass", in: started()), .transcript("Merge it when the tests pass."))
        XCTAssertEqual(effects, [.cancelTimer(.transcript), .sendVoiceNote(.conversation("c1")), .earcon(.sent), .releaseAudio])
        XCTAssertEqual(state.phase, .waiting)
    }

    /// Spec §3: no transcript within eight seconds, or none at all: an
    /// ordinary voice note, and the engine says "Sent".
    func testNoTranscriptSendsAPlainVoiceNoteAndSaysSent() {
        for event in [Engine.Event.timerFired(.transcript), .transcript(nil), .transcript("  ")] {
            let (state, effects) = run(said("hello", in: heard(Self.item)), event)
            XCTAssertTrue(effects.contains(.sendVoiceNote(.item("it_1"))), "\(event): option matching is skipped")
            XCTAssertEqual(utterance(state), "Sent.")
            XCTAssertFalse(effects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        }
    }

    func testTheAgentBeingBusyIsSaid() {
        let (state, _) = run(said("and another thing", in: run(started(), .turnStarted(convoID: "c1")).0), .transcript("And another thing."))
        XCTAssertEqual(utterance(state), "bev is busy. It will get this when it finishes.")
        XCTAssertEqual(run(state, .playbackFinished(state.playing!.id)).0.phase, .waiting)
        XCTAssertTrue(state.isAgentWorking)
    }

    func testOfflineKeepsTheRecordingAndSaysSo() {
        let (state, effects) = run(said("merge it", in: started()), .uploadFailed)
        XCTAssertEqual(Array(effects.prefix(3)), [.cancelTimer(.transcript), .earcon(.error), .sendVoiceNote(.conversation("c1"))])
        XCTAssertEqual(utterance(state), "No connection. I'll send it when you're back online.")
    }

    func testAFailedSendIsSaidWhenTheEngineIsFree() {
        let (state, effects) = run(waiting(), .sendFailed)
        XCTAssertEqual(effects.first, .earcon(.error))
        XCTAssertEqual(utterance(state), "No connection. That wasn't sent.")
        // Busy: said after the clip in progress.
        var busy = run(waiting(), .arrived(Self.plainReply)).0
        busy = run(busy, .sendFailed).0
        XCTAssertEqual(utterance(busy), "Done.")
        busy = run(busy, .playbackFinished(busy.playing!.id)).0
        XCTAssertEqual(utterance(busy), "No connection. That wasn't sent.")
    }

    func testAMicrophoneFailureIsSaid() {
        let (state, effects) = run(started(), .captureFailed)
        XCTAssertEqual(effects.first, .earcon(.error))
        XCTAssertEqual(utterance(state), "I can't use the microphone.")
        XCTAssertNil(state.capture)
    }

    // MARK: Commands

    func testACommandIsHandledOnTheDeviceAndNothingIsUploaded() {
        let (state, effects) = run(heard(Self.reply), .speechStarted, .words("Tell me more."), .speechEnded)
        XCTAssertEqual(effects, [.startTimer(.silence, 0.6)], "a command needs less silence than a sentence")
        let (after, fx) = run(state, .timerFired(.silence))
        XCTAssertFalse(fx.contains(.upload))
        XCTAssertTrue(fx.contains(.stopCapture(keep: false)))
        XCTAssertEqual(utterance(after), "Every test passed and the cache was rebuilt.")
        XCTAssertEqual(after.playing?.level, .more)
    }

    /// The on-device words may miss a command the journal's transcript has.
    func testACommandFoundOnlyInTheTranscriptIsStillACommand() {
        let (state, effects) = run(said("mower", in: heard(Self.reply)), .transcript("More."))
        XCTAssertEqual(Array(effects.prefix(2)), [.cancelTimer(.transcript), .discardRecording])
        XCTAssertEqual(state.level, 2)
    }

    func testTheThreeLevelsOfMore() {
        var state = heard(Self.reply)
        XCTAssertEqual(state.level, 1)
        func more(_ words: String = "more") {
            state = run(state, .words(words), .timerFired(.silence)).0
        }
        func finishClip() { state = run(state, .playbackFinished(state.playing!.id)).0 }
        more()
        XCTAssertEqual(utterance(state), "Every test passed and the cache was rebuilt.")
        finishClip(); more("go on")
        XCTAssertEqual(utterance(state), "Section one. Go on?")
        XCTAssertEqual(state.playing?.level, .section)
        // "Yes" answers "Go on?".
        finishClip(); more("yes")
        XCTAssertEqual(utterance(state), "Section two. Go on?")
        finishClip(); more()
        XCTAssertEqual(utterance(state), "Section three.", "the last section asks nothing")
        finishClip(); more()
        XCTAssertEqual(utterance(state), "That's the whole message.")
    }

    func testNoToGoOnStops() {
        var state = heard(Self.reply)
        state = run(state, .words("more"), .timerFired(.silence)).0
        state = run(state, .playbackFinished(state.playing!.id)).0
        state = run(state, .words("more"), .timerFired(.silence)).0
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertTrue(state.askedGoOn)
        XCTAssertEqual(run(state, .words("no"), .timerFired(.silence)).0.phase, .waiting)
    }

    /// No `spoken_more` (the cleaner's fallback, or the bridge wrote NONE):
    /// "more" goes straight to the message.
    func testMoreWithoutALongerVersionReadsTheMessage() {
        let entry = VoiceEntry.reply(SpokenReply(convoID: "c1", seq: 12, short: "Short.", sections: ["Whole message."]),
                                     convoTitle: "T")
        let state = run(heard(entry), .words("more"), .timerFired(.silence)).0
        XCTAssertEqual(utterance(state), "Whole message.")
        XCTAssertEqual(state.level, 3)
    }

    func testRepeatReplaysTheLevelJustHeard() {
        var state = heard(Self.reply)
        state = run(state, .words("repeat that"), .timerFired(.silence)).0
        XCTAssertEqual(utterance(state), "The deploy finished. Shall I merge?", "no second hint on a repeat")
        state = run(state, .playbackFinished(state.playing!.id)).0
        state = run(state, .words("more"), .timerFired(.silence)).0
        state = run(state, .playbackFinished(state.playing!.id)).0
        state = run(state, .words("say that again"), .timerFired(.silence)).0
        XCTAssertEqual(utterance(state), "Every test passed and the cache was rebuilt.")
        let nothing = run(started(), .words("repeat"), .timerFired(.silence)).0
        XCTAssertEqual(utterance(nothing), "There's nothing to repeat.")
    }

    func testStopGoesQuietAndATapOpensTheMicrophoneAgain() {
        let (state, effects) = run(heard(Self.reply), .words("stop"), .timerFired(.silence))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertEqual(effects.last, .releaseAudio)
        XCTAssertEqual(state.current, Self.reply, "still the thing an answer would be about")
        let (again, fx) = run(state, .tap)
        XCTAssertEqual(again.phase, .listening)
        XCTAssertEqual(fx, [.startTimer(.idle, 1_800), .activateAudio, .earcon(.micOpen), .startCapture(.record),
                            .startTimer(.noSpeech, 8), .startTimer(.maxUtterance, 120)])
    }

    /// "Yes" is a command only to a question the engine asked itself.
    func testYesWithNothingAskedIsAMessage() {
        let state = run(heard(Self.plainReply), .words("yes"), .timerFired(.silence)).0
        XCTAssertEqual(state.phase, .sending)
    }

    /// An item may offer "Skip": the label wins over the command.
    func testALabelWinsOverACommandWord() {
        let entry = VoiceEntry.item(VoiceItem(id: "it_9", kind: .question, convoID: "c1", title: "Run the slow tests?",
                                              labels: ["Skip", "Run"]), convoTitle: "T")
        let state = run(heard(entry), .words("skip"), .timerFired(.silence)).0
        XCTAssertEqual(state.phase, .sending)
        let confirming = run(state, .transcript("Skip.")).0
        XCTAssertEqual(utterance(confirming), "Sending: Skip.")
    }

    // MARK: Speaking

    func testAReplyIsSpokenWithTheMicrophoneOpenUnderneath() {
        let (state, effects) = run(waiting(), .arrived(Self.reply))
        XCTAssertEqual(state.phase, .speaking)
        let expected = Engine.Utterance(id: 1, text: "The deploy finished. Shall I merge? Say more for the detail.", level: .short)
        XCTAssertEqual(effects, [.startTimer(.idle, 1_800), .activateAudio, .play(expected), .startCapture(.monitor)])
        XCTAssertEqual(state.caption, expected.text)
        let (listening, fx) = run(state, .playbackFinished(1))
        XCTAssertEqual(listening.phase, .listening)
        XCTAssertEqual(fx, [.earcon(.micOpen), .promoteCapture, .startTimer(.noSpeech, 8), .startTimer(.maxUtterance, 120)])
    }

    func testTheMoreHintStopsAfterAFewTimes() {
        var state = waiting()
        var texts: [String] = []
        for seq in 1...4 {
            let entry = VoiceEntry.reply(SpokenReply(convoID: "c1", seq: Int64(seq), short: "Reply \(seq).", more: "More."),
                                         convoTitle: "T")
            state = run(state, .arrived(entry)).0
            texts.append(state.playing!.text)
            state = run(state, .playbackFinished(state.playing!.id), .timerFired(.noSpeech)).0
        }
        XCTAssertEqual(texts, ["Reply 1. Say more for the detail.", "Reply 2. Say more for the detail.",
                               "Reply 3. Say more for the detail.", "Reply 4."])
        var config = Engine.Config()
        config.offerMore = false
        XCTAssertEqual(run(waiting(config: config), .arrived(Self.reply)).0.playing?.text, "The deploy finished. Shall I merge?")
        XCTAssertEqual(run(waiting(), .arrived(Self.plainReply)).0.playing?.text, "Done.", "nothing more to offer")
    }

    func testTheSameThingIsNeverSaidTwice() {
        let state = heard(Self.reply)
        let (again, effects) = run(state, .arrived(Self.reply))
        XCTAssertEqual(again, state)
        XCTAssertEqual(effects, [])
    }

    func testSomethingArrivingWhileHeIsTalkingWaitsItsTurn() {
        var state = run(heard(Self.reply), .speechStarted, .arrived(Self.ask)).0
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(state.inbox, [Self.ask])
        state = run(state, .words("merge it"), .speechEnded, .timerFired(.silence), .transcript("Merge it.")).0
        XCTAssertEqual(utterance(state), "Which database? Options: Postgres, SQLite.", "said once his message has gone")
        XCTAssertEqual(state.inbox, [])
    }

    func testSomethingArrivingWhileTheMicrophoneIsOpenButSilentIsSaidAtOnce() {
        let (state, effects) = run(started(), .arrived(Self.plainReply))
        XCTAssertEqual(state.phase, .speaking)
        XCTAssertTrue(effects.contains(.stopCapture(keep: false)))
    }

    func testATapInterruptsAClip() {
        let speaking = run(waiting(), .arrived(Self.reply)).0
        let (state, effects) = run(speaking, .tap)
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(effects, [.stopPlayback, .earcon(.micOpen), .promoteCapture, .startTimer(.idle, 1_800),
                                 .startTimer(.maxUtterance, 120), .startTimer(.noSpeech, 8)])
        XCTAssertNil(state.playing)
    }

    // MARK: Talking over the agent

    func testSpeechThenWordsStopsTheClip() {
        var (state, effects) = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted)
        XCTAssertEqual(effects, [.startTimer(.talkOverOnset, 0.3)])
        (state, effects) = run(state, .timerFired(.talkOverOnset))
        XCTAssertEqual(effects, [.duck, .startTimer(.talkOverWords, 1)], "300 ms of speech: the clip drops, nothing lost yet")
        XCTAssertTrue(state.ducked)
        (state, effects) = run(state, .words("actually wait"))
        XCTAssertEqual(effects, [.cancelTimer(.talkOverWords), .stopPlayback, .restoreVolume, .promoteCapture,
                                 .startTimer(.idle, 1_800), .startTimer(.maxUtterance, 120)])
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(state.heard, "actually wait")
        // He is still talking: silence ends it as usual.
        (state, effects) = run(state, .words("actually wait for the tests"), .speechEnded)
        XCTAssertEqual(effects, [.startTimer(.silence, 1.5)])
        XCTAssertEqual(run(state, .timerFired(.silence)).0.phase, .sending)
    }

    func testSpeechWithoutWordsResumesTheClip() {
        var state = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .timerFired(.talkOverOnset)).0
        let (resumed, effects) = run(state, .speechEnded, .timerFired(.talkOverWords))
        XCTAssertEqual(effects, [.restoreVolume], "a cough: the volume comes back and the clip carries on")
        XCTAssertEqual(resumed.phase, .speaking)
        XCTAssertFalse(resumed.ducked)
        XCTAssertEqual(resumed.falseTriggers, 1)
        // The clip then finishes as normal.
        state = run(resumed, .playbackFinished(resumed.playing!.id)).0
        XCTAssertEqual(state.phase, .listening)
    }

    func testABlipShorterThanTheOnsetDoesNothing() {
        let (state, effects) = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .speechEnded)
        XCTAssertEqual(effects, [.cancelTimer(.talkOverOnset)])
        XCTAssertFalse(state.ducked)
        XCTAssertEqual(run(state, .timerFired(.talkOverOnset)).1, [], "a timer already cancelled does nothing")
    }

    /// One word can be over before the recogniser reports it: the words
    /// then start the end-of-speech count themselves.
    func testAOneWordInterruptionAfterSpeechHasEnded() {
        let ducked = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .timerFired(.talkOverOnset), .speechEnded).0
        let (state, effects) = run(ducked, .words("stop"))
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(effects.last, .startTimer(.silence, 0.6))
        XCTAssertEqual(run(state, .timerFired(.silence)).0.phase, .waiting, "a command, acted on with no upload")
    }

    /// Words that arrive before the duck are kept and judged at the duck.
    func testWordsThatArriveBeforeTheDuckInterruptAtTheDuck() {
        let (state, effects) = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .words("hang on"), .timerFired(.talkOverOnset))
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(Array(effects.prefix(2)), [.duck, .startTimer(.talkOverWords, 1)])
        XCTAssertTrue(effects.contains(.stopPlayback))
    }

    /// The clip's own words coming back through the microphone are not him.
    func testTheClipsOwnWordsDoNotInterruptIt() {
        let ducked = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .timerFired(.talkOverOnset)).0
        let (state, effects) = run(ducked, .words("the deploy finished"))
        XCTAssertEqual(state.phase, .speaking)
        XCTAssertEqual(effects, [])
        XCTAssertTrue(Engine.isEcho("Shall I merge", of: "The deploy finished. Shall I merge?"))
        XCTAssertFalse(Engine.isEcho("merge it now", of: "The deploy finished. Shall I merge?"))
        XCTAssertFalse(Engine.isEcho("", of: "anything"))
    }

    func testRepeatedSelfTriggersSwitchTalkingOverOffForTheRoute() {
        var state = run(waiting(), .arrived(Self.reply)).0
        var effects: [Effect] = []
        for _ in 1...3 {
            (state, effects) = run(state, .speechStarted, .timerFired(.talkOverOnset), .words("the deploy finished"),
                                   .speechEnded, .timerFired(.talkOverWords))
        }
        XCTAssertEqual(effects, [.restoreVolume, .stopCapture(keep: false)])
        XCTAssertEqual(state.talkOverOffRoutes, ["Speaker"])
        XCTAssertFalse(state.talkOverAllowed)
        // It says so after the clip, then listens as usual.
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertEqual(utterance(state), VoicePhrases.talkOverOff)
        let (listening, fx) = run(state, .playbackFinished(state.playing!.id))
        XCTAssertEqual(listening.phase, .listening)
        XCTAssertTrue(fx.contains(.startCapture(.record)))
        // Later clips on this route play with the microphone closed; a tap still interrupts.
        let next = run(run(listening, .timerFired(.noSpeech)).0, .arrived(Self.plainReply))
        XCTAssertFalse(next.1.contains(.startCapture(.monitor)))
        XCTAssertEqual(run(next.0, .speechStarted).1, [])
        XCTAssertEqual(run(next.0, .tap).0.phase, .listening)
        // Another route starts with it on again.
        XCTAssertTrue(run(next.0, .routeChanged("AirPods Pro")).0.talkOverAllowed)
    }

    func testTheCountOfFalseStartsBeginsAgainWithEachClip() {
        var state = run(waiting(), .arrived(Self.reply)).0
        for _ in 1...2 { state = run(state, .speechStarted, .timerFired(.talkOverOnset), .timerFired(.talkOverWords)).0 }
        XCTAssertEqual(state.falseTriggers, 2)
        state = run(state, .playbackFinished(state.playing!.id), .timerFired(.noSpeech), .arrived(Self.plainReply)).0
        XCTAssertEqual(state.falseTriggers, 0)
    }

    func testWithTalkingOverSwitchedOffOnlyATapInterrupts() {
        var config = Engine.Config()
        config.talkOver = false
        let (state, effects) = run(waiting(config: config), .arrived(Self.reply))
        XCTAssertFalse(effects.contains(.startCapture(.monitor)))
        XCTAssertEqual(run(state, .speechStarted, .words("hello")).0.phase, .speaking)
        let (tapped, fx) = run(state, .tap)
        XCTAssertEqual(tapped.phase, .listening)
        XCTAssertTrue(fx.contains(.startCapture(.record)))
    }

    func testSwitchingTalkingOverOffMidClipClosesTheMicrophone() {
        var config = Engine.Config()
        config.talkOver = false
        let ducked = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .timerFired(.talkOverOnset)).0
        let (state, effects) = run(ducked, .configChanged(config))
        XCTAssertEqual(effects, [.cancelTimer(.talkOverWords), .restoreVolume, .stopCapture(keep: false)])
        XCTAssertNil(state.capture)
    }

    // MARK: Answering items and prompts (§4)

    func testAClearMatchIsReadBackThenSentAfterThreeSeconds() {
        var (state, effects) = run(said("yes go", in: heard(Self.item)), .transcript("Yes, go."))
        XCTAssertEqual(utterance(state), "Sending: Go.")
        XCTAssertFalse(effects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        (state, effects) = run(state, .playbackFinished(state.playing!.id))
        XCTAssertEqual(state.phase, .confirming)
        XCTAssertEqual(effects, [.startTimer(.confirm, 3)])
        (state, effects) = run(state, .timerFired(.confirm))
        XCTAssertEqual(effects, [.sendItemAction(itemID: "it_1", label: "Go"), .discardRecording, .earcon(.sent),
                                 .startTimer(.idle, 1_800), .stopCapture(keep: false), .releaseAudio])
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertNil(state.current)
    }

    func testCancelInsideTheWindowStopsTheSend() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        state = run(state, .playbackFinished(state.playing!.id)).0
        let (cancelled, effects) = run(state, .words("cancel"))
        XCTAssertEqual(Array(effects.prefix(2)), [.cancelTimer(.confirm), .discardRecording])
        XCTAssertFalse(effects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        XCTAssertEqual(utterance(cancelled), "Cancelled.")
        XCTAssertNil(cancelled.confirm)
        // Then it listens again, for the same item.
        let listening = run(cancelled, .playbackFinished(cancelled.playing!.id)).0
        XCTAssertEqual(listening.phase, .listening)
        XCTAssertEqual(listening.current, Self.item)
    }

    func testCancelSpokenOverTheReadBackStopsTheSendToo() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        state = run(state, .speechStarted, .timerFired(.talkOverOnset), .words("cancel"), .speechEnded).0
        XCTAssertEqual(state.phase, .listening)
        XCTAssertNotNil(state.confirm, "still pending until the utterance is understood")
        let (after, effects) = run(state, .timerFired(.silence))
        XCTAssertFalse(effects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        XCTAssertEqual(utterance(after), "Cancelled.")
    }

    /// Anything else said over a confirmation: not sent, and what he said
    /// is taken as a new utterance.
    func testTalkingOverAConfirmationWithSomethingElseDropsIt() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        state = run(state, .speechStarted, .timerFired(.talkOverOnset), .words("no I meant wait"), .speechEnded).0
        let (after, effects) = run(state, .timerFired(.silence))
        XCTAssertEqual(after.phase, .sending)
        XCTAssertNil(after.confirm)
        XCTAssertEqual(Array(effects.suffix(4)), [.discardRecording, .stopCapture(keep: true), .upload, .startTimer(.transcript, 8)])
    }

    func testATapCancelsAConfirmation() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        XCTAssertEqual(utterance(run(state, .tap).0), "Cancelled.")
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertEqual(utterance(run(state, .tap).0), "Cancelled.")
    }

    func testAnUnsureMatchAsksAndSendsOnlyOnYes() {
        var state = run(said("go after lunch", in: heard(Self.item)), .transcript("Go, after lunch.")).0
        XCTAssertEqual(utterance(state), "Did you mean Go?")
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertEqual(state.phase, .confirming)
        XCTAssertTrue(state.timers.contains(.confirm))
        let (yes, yesEffects) = run(state, .words("yes"))
        XCTAssertEqual(yesEffects.first, .cancelTimer(.confirm))
        XCTAssertTrue(yesEffects.contains(.sendItemAction(itemID: "it_1", label: "Go")))
        XCTAssertEqual(yes.phase, .waiting)
        let (no, noEffects) = run(state, .words("no"))
        XCTAssertFalse(noEffects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        XCTAssertEqual(utterance(no), "OK, not sent.")
        // Words that are neither are ignored; silence means no.
        let (ignored, _) = run(state, .words("hmm let me think"))
        XCTAssertEqual(ignored.phase, .confirming)
        let (timedOut, timeoutEffects) = run(state, .timerFired(.confirm))
        XCTAssertFalse(timeoutEffects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        XCTAssertEqual(utterance(timedOut), "OK, not sent.")
        XCTAssertEqual(run(timedOut, .playbackFinished(timedOut.playing!.id)).0.phase, .waiting)
    }

    func testNoMatchOnAnItemIsAVoiceNoteComment() {
        let (state, effects) = run(said("why not next week", in: heard(Self.item)), .transcript("Why not next week?"))
        XCTAssertEqual(Array(effects.prefix(3)), [.cancelTimer(.transcript), .sendVoiceNote(.item("it_1")), .earcon(.sent)])
        XCTAssertEqual(state.phase, .waiting)
    }

    func testAPromptOptionIsSentAsItsValue() {
        var state = run(said("the second one", in: heard(Self.ask)), .transcript("The second one.")).0
        XCTAssertEqual(utterance(state), "Sending: SQLite.")
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertTrue(run(state, .timerFired(.confirm)).1.contains(
            .sendPromptReply(convoID: "c3", seq: 30, choice: "lite", text: nil)))
    }

    func testNoMatchOnAPromptIsFreeText() {
        let (_, effects) = run(said("use mysql", in: heard(Self.ask)), .transcript("Use MySQL instead."))
        XCTAssertEqual(Array(effects.prefix(4)), [
            .cancelTimer(.transcript), .discardRecording,
            .sendPromptReply(convoID: "c3", seq: 30, choice: nil, text: "Use MySQL instead."), .earcon(.sent),
        ])
    }

    /// Tool permissions always ask, whatever was heard.
    func testAllowingAPermissionAlwaysAsksFirst() {
        var state = run(said("allow", in: heard(Self.permission)), .transcript("Allow.")).0
        XCTAssertEqual(utterance(state), "Did you mean Allow once?")
        state = run(state, .playbackFinished(state.playing!.id)).0
        let (_, effects) = run(state, .words("yes"))
        XCTAssertTrue(effects.contains(.sendPromptReply(convoID: "c1", seq: 40, choice: "perm:\(Self.permissionID):allow", text: nil)))
        let always = run(said("always allow", in: heard(Self.permission)), .transcript("Always allow.")).0
        XCTAssertEqual(utterance(always), "Did you mean Always allow Bash (session)?")
    }

    func testDenyingAPermissionNeedsNoConfirmation() {
        let (state, effects) = run(said("deny", in: heard(Self.permission)), .transcript("Deny."))
        XCTAssertEqual(Array(effects.prefix(4)), [
            .cancelTimer(.transcript), .discardRecording,
            .sendPromptReply(convoID: "c1", seq: 40, choice: "perm:\(Self.permissionID):deny", text: nil), .earcon(.sent),
        ])
        XCTAssertEqual(utterance(state), "Denied.")
    }

    func testAnythingElseSaidToAPermissionAsksAgain() {
        let (state, effects) = run(said("what does it do", in: heard(Self.permission)), .transcript("What does it do?"))
        XCTAssertEqual(utterance(state), "Say allow or deny.")
        XCTAssertFalse(effects.contains { if case .sendPromptReply = $0 { return true } else { return false } })
        XCTAssertEqual(run(state, .playbackFinished(state.playing!.id)).0.phase, .listening)
    }

    func testAPermissionThatTimesOutIsSaid() {
        let (state, _) = run(heard(Self.permission), .resolved(id: "prompt:40", expired: true))
        XCTAssertEqual(utterance(state), "That permission request timed out and was denied.")
        XCTAssertNil(state.current)
    }

    func testSomethingAnsweredElsewhereIsDropped() {
        var state = run(heard(Self.reply), .speechStarted, .arrived(Self.ask), .arrived(Self.item)).0
        state = run(state, .resolved(id: "prompt:30", expired: false)).0
        XCTAssertEqual(state.inbox, [Self.item])
        // The thing being read out: it stops and the engine moves on.
        let speaking = run(waiting(), .arrived(Self.ask)).0
        let (after, effects) = run(speaking, .resolved(id: "prompt:30", expired: false))
        XCTAssertTrue(effects.contains(.stopPlayback))
        XCTAssertEqual(after.phase, .waiting)
    }

    func testAButtonTapSendsAtOnce() {
        let (state, effects) = run(heard(Self.item), .actionTapped("Wait"))
        XCTAssertEqual(Array(effects.prefix(2)), [.sendItemAction(itemID: "it_1", label: "Wait"), .earcon(.sent)])
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertEqual(run(heard(Self.item), .actionTapped("Nope")).1, [], "not one of its labels")
        let (_, prompt) = run(heard(Self.permission), .actionTapped("Allow once"))
        XCTAssertEqual(prompt.first, .sendPromptReply(convoID: "c1", seq: 40, choice: "perm:\(Self.permissionID):allow", text: nil))
        // Mid-send: the recording is dropped and its transcript ignored.
        let sending = said("erm", in: heard(Self.item))
        let (tapped, fx) = run(sending, .actionTapped("Go"))
        XCTAssertEqual(Array(fx.prefix(3)), [.cancelTimer(.transcript), .discardRecording, .sendItemAction(itemID: "it_1", label: "Go")])
        XCTAssertEqual(run(tapped, .transcript("Erm.")).1, [])
    }

    func testAThingThatNeedsTheScreenIsRefusedAndPassedOver() {
        let (state, _) = run(waiting(), .arrived(Self.secret))
        XCTAssertEqual(utterance(state), "That one needs the screen. It's in your tracker.")
        XCTAssertEqual(state.labels, [])
        XCTAssertEqual(run(state, .playbackFinished(state.playing!.id)).0.phase, .waiting)
    }

    // MARK: The queue (§5)

    func queueStart(_ entries: [VoiceEntry], last: String? = "c9") -> (Engine.State, [Effect]) {
        run(Engine.State(), .start(.queue(entries: entries, lastConvoID: last, lastTitle: "Last chat", lastBoxName: "bev")))
    }

    func testTheQueueSaysTheCountReadsTheFirstAndListens() {
        let (state, effects) = queueStart([Self.permission, Self.item, Self.reply])
        XCTAssertEqual(utterance(state),
                       "Three things need you. In Auth refactor. bev wants to run a command: git push origin main. Allow or deny?")
        XCTAssertEqual(Array(effects.prefix(4)), [.keepScreenAwake(true), .startTimer(.idle, 1_800), .watch(convoID: "c9"),
                                                 .watch(convoID: "c1")])
        XCTAssertEqual(state.queue, [Self.item, Self.reply])
        XCTAssertEqual(state.labels, ["Allow once", "Always allow Bash (session)", "Deny"])
        XCTAssertEqual(run(state, .playbackFinished(1)).0.phase, .listening)
    }

    func testSkipMovesOnAndAnAnswerMovesOnAfterItIsSent() {
        var state = queueStart([Self.item, Self.ask, Self.reply]).0
        state = run(state, .playbackFinished(state.playing!.id), .words("skip"), .timerFired(.silence)).0
        XCTAssertEqual(utterance(state), "Schema. Which database? Options: Postgres, SQLite.")
        state = run(state, .playbackFinished(state.playing!.id)).0
        state = run(said("postgres", in: state), .transcript("Postgres.")).0
        state = run(state, .playbackFinished(state.playing!.id), .timerFired(.confirm)).0
        XCTAssertEqual(utterance(state), "Auth refactor. The deploy finished. Shall I merge? Say more for the detail.")
        // A plain answer to a reply goes to that reply's conversation.
        state = run(state, .playbackFinished(state.playing!.id)).0
        let (done, effects) = run(said("yes merge it", in: state), .transcript("Yes, merge it."))
        XCTAssertTrue(effects.contains(.sendVoiceNote(.conversation("c1"))))
        XCTAssertEqual(utterance(done), "That's everything.")
        // Then it listens on the conversation used last.
        let listening = run(done, .playbackFinished(done.playing!.id)).0
        XCTAssertEqual(listening.phase, .listening)
        XCTAssertFalse(listening.inQueue)
        let (_, last) = run(said("anything new", in: listening), .transcript("Anything new?"))
        XCTAssertTrue(last.contains(.sendVoiceNote(.conversation("c9"))))
    }

    func testAnEmptyQueueSaysSoAndListensOnTheLastConversation() {
        let (state, _) = queueStart([])
        XCTAssertEqual(utterance(state), "Nothing needs you.")
        XCTAssertEqual(run(state, .playbackFinished(1)).0.phase, .listening)
        let (none, _) = queueStart([], last: nil)
        XCTAssertEqual(run(none, .playbackFinished(1)).0.phase, .waiting, "nowhere to listen")
        let (nowhere, effects) = run(run(none, .playbackFinished(1), .tap).0, .words("hello there"), .timerFired(.silence),
                                     .transcript("Hello there."))
        XCTAssertTrue(effects.contains(.discardRecording))
        XCTAssertEqual(utterance(nowhere), "There's no conversation to send that to.")
    }

    func testSomethingNewJumpsTheQueue() {
        var state = queueStart([Self.item, Self.reply]).0
        state = run(state, .arrived(Self.permission)).0
        state = run(state, .playbackFinished(state.playing!.id), .actionTapped("Go")).0
        XCTAssertTrue(utterance(state)!.hasPrefix("In Auth refactor. bev wants to run a command"))
    }

    // MARK: Pausing, idling, ending (§6, §11, §12)

    func testACallPausesAndWhatWasCutOffIsSaidAgainAfterwards() {
        let speaking = run(waiting(), .arrived(Self.reply)).0
        let (paused, effects) = run(speaking, .interruption(.began))
        XCTAssertEqual(effects, [.stopCapture(keep: false), .stopPlayback, .releaseAudio])
        XCTAssertEqual(paused.phase, .waiting)
        XCTAssertTrue(paused.paused)
        // What lands meanwhile waits.
        let more = run(paused, .arrived(Self.ask)).0
        XCTAssertEqual(more.phase, .waiting)
        let (resumed, _) = run(more, .interruption(.ended(shouldResume: true)))
        XCTAssertEqual(utterance(resumed), "The deploy finished. Shall I merge? Say more for the detail.")
        XCTAssertEqual(resumed.inbox, [Self.ask])
    }

    func testLeavingTheAppPausesAndComingBackSaysWhatLanded() {
        let (paused, effects) = run(started(), .speechStarted, .appBackgrounded)
        XCTAssertEqual(effects, [.cancelTimer(.maxUtterance), .stopCapture(keep: false), .releaseAudio])
        let landed = run(paused, .arrived(Self.plainReply)).0
        XCTAssertEqual(landed.inbox, [Self.plainReply])
        XCTAssertEqual(utterance(run(landed, .appForegrounded).0), "Done.")
        XCTAssertEqual(run(paused, .appForegrounded).0.phase, .waiting, "nothing landed: stay quiet")
    }

    func testAnInterruptionThatDoesNotResumeWaitsForATap() {
        let paused = run(run(waiting(), .arrived(Self.reply)).0, .interruption(.began), .interruption(.ended(shouldResume: false))).0
        XCTAssertTrue(paused.paused)
        XCTAssertEqual(run(paused, .tap).0.phase, .listening)
    }

    /// A call arriving mid-send: the message still goes, silently.
    func testPausedMidSendStillSends() {
        let sending = said("merge it", in: started())
        let (state, effects) = run(sending, .interruption(.began), .transcript("Merge it."))
        XCTAssertTrue(effects.contains(.sendVoiceNote(.conversation("c1"))))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertNil(state.playing)
    }

    func testThirtyMinutesWithoutAnExchangeEndsVoiceMode() {
        let (state, effects) = run(waiting(), .timerFired(.idle))
        XCTAssertEqual(effects, [.keepScreenAwake(false), .ended(.idle)])
        XCTAssertEqual(state.phase, .idle)
        // An exchange starts the thirty minutes again.
        XCTAssertTrue(run(waiting(), .tap).1.contains(.startTimer(.idle, 1_800)))
        XCTAssertTrue(run(waiting(), .arrived(Self.reply)).1.contains(.startTimer(.idle, 1_800)))
    }

    func testEndStopsEverything() {
        let ducked = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .timerFired(.talkOverOnset)).0
        let (state, effects) = run(ducked, .end)
        XCTAssertEqual(effects, [.cancelTimer(.talkOverWords), .cancelTimer(.idle), .stopPlayback, .restoreVolume,
                                 .stopCapture(keep: false), .releaseAudio, .keepScreenAwake(false), .ended(.user)])
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.route, "Speaker", "the route and what was learned about it survive")
    }

    func testEndingMidSendStillSendsWhatHeSaid() {
        let (_, effects) = run(said("merge it", in: started()), .end)
        XCTAssertEqual(effects.first, .sendVoiceNote(.conversation("c1")))
        XCTAssertEqual(effects.last, .ended(.user))
    }

    func testTurnEventsTrackWhoIsWorking() {
        var state = run(started(), .turnStarted(convoID: "c1")).0
        XCTAssertTrue(state.isAgentWorking)
        state = run(state, .turnEnded(convoID: "c1")).0
        XCTAssertFalse(state.isAgentWorking)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceModeEngineTests'`
Expected: build FAILS — `cannot find 'VoiceModeEngine' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/Voice/VoiceModeEngine.swift`:

```swift
import Foundation

/// Voice mode's state machine (spec 2026-10-03 §3): a pure function from a
/// state and an event to the next state and the things to do. It never
/// touches audio, the network or a clock: capture, playback, uploads,
/// sends and timers are `Effect` values a runner carries out, and what
/// they produce comes back as `Event`s. One engine drives the iPhone
/// screen, the Mac's stage and CarPlay; it knows about none of them.
///
/// ```
/// idle ─► listening ─► sending ─► waiting ─► speaking ─► listening …
///                         │                      ▲
///                         └─► confirming ────────┘
/// ```
public enum VoiceModeEngine {
    // MARK: Values

    public struct Config: Equatable, Sendable {
        /// "Talk over the agent": the microphone stays open under a clip.
        public var talkOver = true
        /// Whether "Say more for the detail" follows a reply (the first few times).
        public var offerMore = true
        /// Silence after speech that ends an utterance.
        public var endOfSpeechSilence: TimeInterval = 1.5
        /// The same, when the words so far are a command and nothing else.
        public var commandSilence: TimeInterval = 0.6
        /// Nothing said at all: the microphone closes.
        public var noSpeechTimeout: TimeInterval = 8
        public var maxUtterance: TimeInterval = 120
        /// No transcript by now: the recording goes as a plain voice note.
        public var transcriptTimeout: TimeInterval = 8
        /// How long "Sending: Go" waits for "cancel".
        public var confirmWindow: TimeInterval = 3
        /// Speech must last this long under a clip before the clip ducks.
        public var talkOverOnset: TimeInterval = 0.3
        /// Words must follow within this long, or the clip carries on.
        public var talkOverWords: TimeInterval = 1
        /// This many false starts inside one clip switch talking-over off
        /// for the audio route.
        public var falseTriggerLimit = 3
        public var moreHintLimit = 3
        /// Voice mode ends itself after this long without an exchange (§11).
        public var idleEnd: TimeInterval = 30 * 60

        public init() {}
    }

    public enum Phase: String, Equatable, Sendable { case idle, listening, sending, confirming, waiting, speaking }

    public enum TimerID: String, Hashable, Sendable, CaseIterable {
        case noSpeech, silence, maxUtterance, transcript, confirm, talkOverOnset, talkOverWords, idle
    }

    /// `record` writes the utterance to a file; `monitor` only watches for
    /// speech and words under a clip, keeping a rolling half second.
    public enum CaptureMode: String, Equatable, Sendable { case record, monitor }
    public enum Earcon: String, Equatable, Sendable, CaseIterable { case micOpen, sent, error }
    public enum SpeechLevel: String, Equatable, Sendable { case short, more, section, system }
    public enum SendTarget: Equatable, Sendable { case conversation(String), item(String) }
    public enum EndReason: String, Equatable, Sendable { case user, idle }
    public enum Interruption: Equatable, Sendable { case began, ended(shouldResume: Bool) }

    public struct Utterance: Equatable, Sendable {
        public let id: Int
        public let text: String
        public let level: SpeechLevel
        public init(id: Int, text: String, level: SpeechLevel) { self.id = id; self.text = text; self.level = level }
    }

    public enum Effect: Equatable, Sendable {
        case activateAudio
        case releaseAudio
        case startCapture(CaptureMode)
        /// Monitor becomes record, keeping the half second already heard.
        case promoteCapture
        /// `keep`: the file becomes the current recording. Otherwise it is deleted.
        case stopCapture(keep: Bool)
        case play(Utterance)
        case stopPlayback
        case duck
        case restoreVolume
        case earcon(Earcon)
        /// Upload the current recording and answer with `.transcript` or `.uploadFailed`.
        case upload
        /// Send the current recording as a voice note (uploading it first
        /// if need be; kept and retried when offline).
        case sendVoiceNote(SendTarget)
        case sendItemAction(itemID: String, label: String)
        case sendPromptReply(convoID: String, seq: Int64, choice: String?, text: String?)
        case discardRecording
        case startTimer(TimerID, TimeInterval)
        case cancelTimer(TimerID)
        /// Tell the engine when this conversation's turns start and end
        /// and what they end with.
        case watch(convoID: String)
        case keepScreenAwake(Bool)
        case ended(EndReason)
    }

    public enum Start: Equatable, Sendable {
        /// From inside a conversation: voice mode talks to it.
        case conversation(id: String, title: String, boxName: String?)
        /// From anywhere else: what needs the user, then the conversation
        /// used last (spec §5).
        case queue(entries: [VoiceEntry], lastConvoID: String?, lastTitle: String, lastBoxName: String?)
    }

    public enum Event: Equatable, Sendable {
        case start(Start)
        case end
        /// A tap anywhere on the voice screen.
        case tap
        case sendTapped
        /// One of the current thing's label buttons.
        case actionTapped(String)
        case speechStarted
        case speechEnded
        /// The on-device recogniser's words for the utterance so far.
        case words(String)
        case captureFailed
        /// The journal's transcript, or `nil` when it has none to give.
        case transcript(String?)
        case uploadFailed
        /// A send could not leave: offline.
        case sendFailed
        case arrived(VoiceEntry)
        /// Answered elsewhere, closed, or (`expired`) timed out.
        case resolved(id: String, expired: Bool)
        case turnStarted(convoID: String)
        case turnEnded(convoID: String)
        case playbackFinished(Int)
        case timerFired(TimerID)
        case interruption(Interruption)
        case appBackgrounded
        case appForegrounded
        /// The audio route's identity ("Speaker", "AirPods Pro", a car).
        case routeChanged(String)
        case configChanged(Config)
    }

    public enum AfterPlayback: String, Equatable, Sendable { case listen, confirm, wait, next }

    public struct Confirm: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable { case sending, didYouMean }
        public let kind: Kind
        public let label: String
        public let send: Effect
    }

    public struct State: Equatable, Sendable {
        public var config = Config()
        public var phase: Phase = .idle
        /// Where plain speech goes when nothing else claims it.
        public var convoID: String?
        public var convoTitle = ""
        public var boxName: String?
        /// Still reading "what needs you".
        public var inQueue = false
        public var queue: [VoiceEntry] = []
        /// Things that arrived while the engine was busy, oldest first.
        public var inbox: [VoiceEntry] = []
        /// The thing last read out: what an answer is matched against.
        public var current: VoiceEntry?
        /// 1 short, 2 longer, 3 the message in sections.
        public var level = 0
        public var section = 0
        public var askedGoOn = false
        public var playing: Utterance?
        public var after: AfterPlayback = .listen
        /// The line being spoken, for a phone screen. Never for a car's.
        public var caption: String?
        public var capture: CaptureMode?
        public var audioActive = false
        public var heard = ""
        public var speechSeen = false
        public var speechActive = false
        public var ducked = false
        public var confirm: Confirm?
        public var timers: Set<TimerID> = []
        public var working: Set<String> = []
        public var watched: Set<String> = []
        public var route = ""
        public var talkOverOffRoutes: Set<String> = []
        public var falseTriggers = 0
        public var pendingNotice: String?
        public var moreHints = 0
        public var paused = false
        public var nextUtterance = 1
        /// Entry ids already read out, so nothing is said twice.
        public var said: Set<String> = []

        public init() {}

        /// The labels to offer as buttons right now.
        public var labels: [String] { current?.labels ?? [] }
        public var talkOverAllowed: Bool { config.talkOver && !talkOverOffRoutes.contains(route) }
        /// The conversation a screen should name.
        public var title: String { current?.convoTitle.isEmpty == false ? current!.convoTitle : convoTitle }
        public var isAgentWorking: Bool {
            guard let id = current?.convoID ?? convoID else { return false }
            return working.contains(id)
        }
    }

    public static func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        var machine = Machine(s: state)
        machine.handle(event)
        return (machine.s, machine.fx)
    }

    /// Whether `heard` is the clip's own words coming back through the
    /// microphone: every word of it, in order, inside the clip's text.
    public static func isEcho(_ heard: String, of clip: String) -> Bool {
        let words = VoiceText.words(heard)
        let spoken = VoiceText.words(clip)
        guard !words.isEmpty, words.count <= spoken.count else { return false }
        return (0...(spoken.count - words.count)).contains { Array(spoken[$0..<($0 + words.count)]) == words }
    }
}

// MARK: - The machine

private struct Machine {
    typealias Engine = VoiceModeEngine
    var s: Engine.State
    var fx: [Engine.Effect] = []

    mutating func handle(_ event: Engine.Event) {
        switch event {
        case .start(let start):
            begin(start)
            return
        case .configChanged(let config):
            s.config = config
            if s.phase == .speaking, s.capture == .monitor, !s.talkOverAllowed { closeMonitor() }
            return
        case .routeChanged(let route):
            s.route = route
            s.falseTriggers = 0
            return
        default:
            break
        }
        guard s.phase != .idle else { return }

        switch event {
        case .start, .configChanged, .routeChanged:
            break
        case .end:
            finish(.user)
        case .tap:
            tap()
        case .sendTapped:
            if s.phase == .listening { finishUtterance() }
        case .actionTapped(let label):
            actionTapped(label)
        case .speechStarted:
            s.speechActive = true
            speechStarted()
        case .speechEnded:
            s.speechActive = false
            speechEnded()
        case .words(let text):
            words(text)
        case .captureFailed:
            captureFailed()
        case .transcript(let text):
            guard s.phase == .sending else { return }
            cancel(.transcript)
            transcript(text)
        case .uploadFailed:
            guard s.phase == .sending else { return }
            cancel(.transcript)
            fx.append(.earcon(.error))
            guard let target = plainTarget() else {
                fx.append(.discardRecording)
                say(VoicePhrases.nowhereToSend, .system, then: .wait)
                return
            }
            fx.append(.sendVoiceNote(target.send))
            watch(target.convoID)
            if s.paused { wait() } else { say(VoicePhrases.noConnection, .system, then: .next) }
        case .sendFailed:
            fx.append(.earcon(.error))
            if s.phase == .waiting, !s.paused {
                say(VoicePhrases.notSentOffline, .system, then: .wait)
            } else {
                s.pendingNotice = VoicePhrases.notSentOffline
            }
        case .arrived(let entry):
            arrived(entry)
        case .resolved(let id, let expired):
            resolved(id, expired: expired)
        case .turnStarted(let convoID):
            s.working.insert(convoID)
        case .turnEnded(let convoID):
            s.working.remove(convoID)
        case .playbackFinished(let id):
            playbackFinished(id)
        case .timerFired(let id):
            guard s.timers.remove(id) != nil else { return }
            timerFired(id)
        case .interruption(.began), .appBackgrounded:
            pause()
        case .interruption(.ended(let shouldResume)):
            if shouldResume { resume() }
        case .appForegrounded:
            resume()
        }
    }

    // MARK: Start and end

    mutating func begin(_ start: Engine.Start) {
        guard s.phase == .idle else { return }
        var fresh = Engine.State()
        fresh.config = s.config
        fresh.route = s.route
        fresh.talkOverOffRoutes = s.talkOverOffRoutes
        s = fresh
        fx.append(.keepScreenAwake(true))
        timer(.idle, s.config.idleEnd)
        switch start {
        case .conversation(let id, let title, let boxName):
            s.convoID = id
            s.convoTitle = title
            s.boxName = boxName
            watch(id)
            listen()
        case .queue(let entries, let lastConvoID, let lastTitle, let lastBoxName):
            s.convoID = lastConvoID
            s.convoTitle = lastTitle
            s.boxName = lastBoxName
            if let lastConvoID { watch(lastConvoID) }
            let lead = VoicePhrases.needsYou(entries.count)
            guard let first = entries.first else {
                say(lead, .system, then: lastConvoID == nil ? .wait : .listen)
                return
            }
            s.inQueue = true
            s.queue = Array(entries.dropFirst())
            present(first, lead: lead)
        }
    }

    mutating func finish(_ reason: Engine.EndReason) {
        if s.phase == .sending, let target = plainTarget() {
            // Nothing he said is lost: it goes as a voice note.
            fx.append(.sendVoiceNote(target.send))
        } else if s.phase == .sending || s.confirm != nil {
            fx.append(.discardRecording)
        }
        for id in Engine.TimerID.allCases where s.timers.contains(id) { fx.append(.cancelTimer(id)) }
        if s.playing != nil { fx.append(.stopPlayback) }
        if s.ducked { fx.append(.restoreVolume) }
        if s.capture != nil { fx.append(.stopCapture(keep: false)) }
        if s.audioActive { fx.append(.releaseAudio) }
        fx.append(.keepScreenAwake(false))
        fx.append(.ended(reason))
        var fresh = Engine.State()
        fresh.config = s.config
        fresh.route = s.route
        fresh.talkOverOffRoutes = s.talkOverOffRoutes
        s = fresh
    }

    // MARK: Moving between phases

    /// `openMicrophone: false` plays with the microphone closed whatever
    /// the setting says (it has just failed).
    mutating func say(_ text: String, _ level: Engine.SpeechLevel, then: Engine.AfterPlayback, openMicrophone: Bool = true) {
        cancelListeningTimers()
        if s.capture == .record {
            fx.append(.stopCapture(keep: false))
            s.capture = nil
        }
        if !s.audioActive {
            fx.append(.activateAudio)
            s.audioActive = true
        }
        if s.playing != nil { fx.append(.stopPlayback) }
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        let utterance = Engine.Utterance(id: s.nextUtterance, text: text, level: level)
        s.nextUtterance += 1
        s.playing = utterance
        s.after = then
        s.caption = text
        s.phase = .speaking
        s.heard = ""
        s.speechSeen = false
        s.askedGoOn = false
        s.falseTriggers = 0
        fx.append(.play(utterance))
        if s.talkOverAllowed, openMicrophone {
            if s.capture == nil {
                fx.append(.startCapture(.monitor))
                s.capture = .monitor
            }
        } else if s.capture == .monitor {
            fx.append(.stopCapture(keep: false))
            s.capture = nil
        }
    }

    /// Reads an entry out and makes it the thing answers are matched against.
    mutating func present(_ entry: VoiceEntry, lead: String? = nil) {
        s.current = entry
        s.level = 1
        s.section = 0
        s.said.insert(entry.id)
        watch(entry.convoID)
        timer(.idle, s.config.idleEnd)
        var text = VoicePhrases.reading(entry, inQueue: s.inQueue)
        var then = Engine.AfterPlayback.listen
        switch entry.subject {
        case .item(let item) where item.needsScreen:
            then = .next
        case .reply(let reply):
            s.working.remove(reply.convoID)
            if s.config.offerMore, s.moreHints < s.config.moreHintLimit, reply.more != nil || !reply.sections.isEmpty {
                text += " " + VoicePhrases.moreHint
                s.moreHints += 1
            }
        case .item, .prompt:
            break
        }
        if let lead { text = lead + " " + text }
        say(text, .short, then: then)
    }

    mutating func listen() {
        cancelListeningTimers()
        if !s.audioActive {
            fx.append(.activateAudio)
            s.audioActive = true
        }
        if s.playing != nil {
            fx.append(.stopPlayback)
            s.playing = nil
        }
        fx.append(.earcon(.micOpen))
        openRecording()
        s.phase = .listening
        s.caption = nil
        s.heard = ""
        s.speechSeen = false
        timer(.noSpeech, s.config.noSpeechTimeout)
        timer(.maxUtterance, s.config.maxUtterance)
    }

    mutating func openRecording() {
        switch s.capture {
        case .monitor: fx.append(.promoteCapture)
        case nil: fx.append(.startCapture(.record))
        case .record: break
        }
        s.capture = .record
    }

    /// Nothing to say and nobody talking: let go of the audio.
    mutating func wait() {
        cancelListeningTimers()
        if s.capture != nil {
            fx.append(.stopCapture(keep: false))
            s.capture = nil
        }
        if s.playing != nil {
            fx.append(.stopPlayback)
            s.playing = nil
        }
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        s.caption = nil
        if !s.paused {
            if let notice = s.pendingNotice {
                s.pendingNotice = nil
                say(notice, .system, then: .wait)
                return
            }
            if !s.inbox.isEmpty {
                present(s.inbox.removeFirst())
                return
            }
        }
        if s.audioActive {
            fx.append(.releaseAudio)
            s.audioActive = false
        }
        s.phase = .waiting
    }

    /// The current thing is dealt with: what arrived meanwhile, then the
    /// rest of the queue, then waiting.
    mutating func next() {
        s.current = nil
        s.level = 0
        if !s.paused {
            if !s.inbox.isEmpty {
                present(s.inbox.removeFirst())
                return
            }
            if s.inQueue {
                if !s.queue.isEmpty {
                    present(s.queue.removeFirst())
                    return
                }
                s.inQueue = false
                say(VoicePhrases.queueDone, .system, then: s.convoID == nil ? .wait : .listen)
                return
            }
        }
        wait()
    }

    // MARK: Taps

    mutating func tap() {
        s.paused = false
        switch s.phase {
        case .speaking:
            if let confirm = s.confirm {
                cancelConfirm(confirm.kind == .sending ? VoicePhrases.cancelled : VoicePhrases.notSent)
            } else {
                interrupt(heard: "")
            }
        case .waiting:
            timer(.idle, s.config.idleEnd)
            listen()
        case .confirming:
            if let confirm = s.confirm {
                cancelConfirm(confirm.kind == .sending ? VoicePhrases.cancelled : VoicePhrases.notSent)
            }
        case .listening, .sending, .idle:
            break
        }
    }

    mutating func actionTapped(_ label: String) {
        guard let entry = s.current, entry.labels.contains(label) else { return }
        let send: Engine.Effect
        switch entry.subject {
        case .item(let item):
            send = .sendItemAction(itemID: item.id, label: label)
        case .prompt(let prompt):
            guard let option = prompt.options.first(where: { $0.label == label }) else { return }
            send = .sendPromptReply(convoID: prompt.convoID, seq: prompt.seq, choice: option.value, text: nil)
        case .reply:
            return
        }
        if s.confirm != nil || s.phase == .sending {
            cancel(.confirm)
            cancel(.transcript)
            s.confirm = nil
            fx.append(.discardRecording)
        }
        fx.append(send)
        fx.append(.earcon(.sent))
        timer(.idle, s.config.idleEnd)
        next()
    }

    // MARK: Hearing

    mutating func speechStarted() {
        switch s.phase {
        case .listening:
            s.speechSeen = true
            cancel(.noSpeech)
            cancel(.silence)
        case .speaking:
            guard s.capture == .monitor, s.talkOverAllowed, !s.ducked else { return }
            timer(.talkOverOnset, s.config.talkOverOnset)
        case .idle, .sending, .confirming, .waiting:
            break
        }
    }

    mutating func speechEnded() {
        switch s.phase {
        case .listening:
            guard s.speechSeen else { return }
            startSilenceTimer()
        case .speaking:
            cancel(.talkOverOnset)
        case .idle, .sending, .confirming, .waiting:
            break
        }
    }

    mutating func startSilenceTimer() {
        let isCommand = command(for: s.heard) != nil
        timer(.silence, isCommand ? s.config.commandSilence : s.config.endOfSpeechSilence)
    }

    mutating func words(_ text: String) {
        switch s.phase {
        case .listening:
            s.heard = text
            guard !VoiceText.words(text).isEmpty else { return }
            s.speechSeen = true
            cancel(.noSpeech)
            // The detector may already have reported the end (or nothing
            // at all): the words then start the count themselves.
            if !s.speechActive { startSilenceTimer() }
        case .speaking:
            guard s.capture == .monitor else { return }
            s.heard = text
            if s.ducked { interruptIfGenuine() }
        case .confirming:
            guard let confirm = s.confirm, let command = VoiceCommand.parse(text) else { return }
            switch (confirm.kind, command) {
            case (_, .yes):
                commitConfirm()
            case (.sending, .cancel), (.sending, .no), (.sending, .stop):
                cancelConfirm(VoicePhrases.cancelled)
            case (.didYouMean, .cancel), (.didYouMean, .no), (.didYouMean, .stop):
                cancelConfirm(VoicePhrases.notSent)
            default:
                break
            }
        case .idle, .sending, .waiting:
            break
        }
    }

    /// Words under a ducked clip stop it, unless they are the clip's own.
    mutating func interruptIfGenuine() {
        guard let playing = s.playing, !VoiceText.words(s.heard).isEmpty,
              !Engine.isEcho(s.heard, of: playing.text) else { return }
        interrupt(heard: s.heard)
    }

    /// The clip stops and the engine is listening. With `heard` empty this
    /// is a tap; otherwise he is already mid-sentence and the recording
    /// keeps the half second before he started.
    mutating func interrupt(heard: String) {
        cancelListeningTimers()
        fx.append(.stopPlayback)
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        s.playing = nil
        s.caption = nil
        s.falseTriggers = 0
        if !s.audioActive {
            fx.append(.activateAudio)
            s.audioActive = true
        }
        if heard.isEmpty { fx.append(.earcon(.micOpen)) }
        openRecording()
        s.phase = .listening
        s.heard = heard
        s.speechSeen = !heard.isEmpty
        timer(.idle, s.config.idleEnd)
        timer(.maxUtterance, s.config.maxUtterance)
        if heard.isEmpty {
            timer(.noSpeech, s.config.noSpeechTimeout)
        } else if !s.speechActive {
            startSilenceTimer()
        }
    }

    mutating func captureFailed() {
        fx.append(.earcon(.error))
        s.capture = nil
        cancel(.talkOverOnset)
        cancel(.talkOverWords)
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        if s.phase == .listening { say(VoicePhrases.microphoneFailed, .system, then: .wait, openMicrophone: false) }
    }

    mutating func closeMonitor() {
        cancel(.talkOverOnset)
        cancel(.talkOverWords)
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        fx.append(.stopCapture(keep: false))
        s.capture = nil
    }

    // MARK: The end of an utterance

    /// The command these words are, given what is on offer: a label wins
    /// over a command word (an item may offer "Skip"), and "yes" and "no"
    /// are commands only to a question the engine itself asked.
    func command(for words: String) -> VoiceCommand? {
        guard let command = VoiceCommand.parse(words) else { return nil }
        let heard = VoiceText.words(words)
        if s.labels.contains(where: { VoiceText.words($0) == heard }) { return nil }
        if command == .yes || command == .no, s.confirm == nil, !s.askedGoOn { return nil }
        return command
    }

    mutating func finishUtterance() {
        cancel(.noSpeech)
        cancel(.silence)
        cancel(.maxUtterance)
        timer(.idle, s.config.idleEnd)
        let command = command(for: s.heard)
        if let confirm = s.confirm {
            // He talked over "Sending: Go" or "Did you mean Go?".
            s.confirm = nil
            fx.append(.discardRecording)
            switch command {
            case .yes?:
                fx.append(.stopCapture(keep: false))
                s.capture = nil
                fx.append(confirm.send)
                fx.append(.earcon(.sent))
                next()
                return
            case .cancel?, .no?, .stop?:
                fx.append(.stopCapture(keep: false))
                s.capture = nil
                say(confirm.kind == .sending ? VoicePhrases.cancelled : VoicePhrases.notSent, .system, then: .listen)
                return
            default:
                break   // not sent; what he said instead is handled below
            }
        }
        if let command {
            fx.append(.stopCapture(keep: false))
            s.capture = nil
            run(command)
            return
        }
        fx.append(.stopCapture(keep: true))
        s.capture = nil
        fx.append(.upload)
        s.phase = .sending
        timer(.transcript, s.config.transcriptTimeout)
    }

    mutating func run(_ command: VoiceCommand) {
        switch command {
        case .repeat: repeatCurrent()
        case .more: more()
        case .skip: next()
        case .stop, .cancel: wait()
        case .yes: if s.askedGoOn { more() } else { wait() }
        case .no: wait()
        }
    }

    func readable(_ entry: VoiceEntry) -> (more: String?, sections: [String]) {
        switch entry.subject {
        case .reply(let reply): return (reply.more, reply.sections)
        case .item(let item): return (nil, item.needsScreen ? [] : item.sections)
        case .prompt: return (nil, [])
        }
    }

    mutating func more() {
        guard let entry = s.current else {
            say(VoicePhrases.wholeMessage, .system, then: .listen)
            return
        }
        let parts = readable(entry)
        if s.level <= 1, let more = parts.more {
            s.level = 2
            say(more, .more, then: .listen)
            return
        }
        let index = s.level >= 3 ? s.section + 1 : 0
        guard index < parts.sections.count else {
            say(VoicePhrases.wholeMessage, .system, then: .listen)
            return
        }
        s.level = 3
        s.section = index
        saySection(parts.sections, index)
    }

    mutating func saySection(_ sections: [String], _ index: Int) {
        let isLast = index == sections.count - 1
        say(isLast ? sections[index] : sections[index] + " " + VoicePhrases.goOn, .section, then: .listen)
        s.askedGoOn = !isLast
    }

    mutating func repeatCurrent() {
        guard let entry = s.current else {
            say(VoicePhrases.nothingToRepeat, .system, then: .listen)
            return
        }
        let parts = readable(entry)
        if s.level == 2, let more = parts.more {
            say(more, .more, then: .listen)
        } else if s.level >= 3, s.section < parts.sections.count {
            saySection(parts.sections, s.section)
        } else {
            var then = Engine.AfterPlayback.listen
            if case .item(let item) = entry.subject, item.needsScreen { then = .next }
            say(VoicePhrases.reading(entry, inQueue: s.inQueue), .short, then: then)
        }
    }

    // MARK: The transcript

    /// Where a plain spoken reply goes: the item just read, else the
    /// conversation of the reply or prompt just read, else the
    /// conversation voice mode was started on.
    func plainTarget() -> (send: Engine.SendTarget, convoID: String)? {
        switch s.current?.subject {
        case .item(let item)? where !item.needsScreen:
            return (.item(item.id), item.convoID)
        case .prompt(let prompt)?:
            return (.conversation(prompt.convoID), prompt.convoID)
        case .reply(let reply)?:
            return (.conversation(reply.convoID), reply.convoID)
        case .item?, nil:
            return s.convoID.map { (.conversation($0), $0) }
        }
    }

    mutating func sendPlain(announce: Bool) {
        guard let target = plainTarget() else {
            fx.append(.discardRecording)
            say(VoicePhrases.nowhereToSend, .system, then: .wait)
            return
        }
        fx.append(.sendVoiceNote(target.send))
        sent(to: target.convoID, announce: announce)
    }

    mutating func sent(to convoID: String, announce: Bool) {
        fx.append(.earcon(.sent))
        watch(convoID)
        if s.paused {
            next()
        } else if announce {
            say(VoicePhrases.sent, .system, then: .next)
        } else if s.working.contains(convoID) {
            say(VoicePhrases.busy(s.current?.boxName ?? s.boxName), .system, then: .next)
        } else {
            next()
        }
    }

    mutating func transcript(_ raw: String?) {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // No transcript in time: a plain voice note, and say so. Paused
        // (a call came in mid-send): the same, silently.
        guard !text.isEmpty, !s.paused else {
            sendPlain(announce: !s.paused)
            return
        }
        if let command = command(for: text) {
            fx.append(.discardRecording)
            run(command)
            return
        }
        guard let entry = s.current else {
            sendPlain(announce: false)
            return
        }
        switch entry.subject {
        case .prompt(let prompt) where prompt.isPermission:
            guard let verdict = ActionLabelMatcher.permissionVerdict(text), let option = prompt.option(for: verdict) else {
                fx.append(.discardRecording)
                say(VoicePhrases.allowOrDeny, .system, then: .listen)
                return
            }
            let send = Engine.Effect.sendPromptReply(convoID: prompt.convoID, seq: prompt.seq, choice: option.value, text: nil)
            if verdict == .deny {
                // Denying by mistake costs nothing: no confirmation.
                fx.append(.discardRecording)
                fx.append(send)
                fx.append(.earcon(.sent))
                say(VoicePhrases.denied, .system, then: .next)
            } else {
                // Allowing by mistake does: always asked, whatever was heard.
                startConfirm(.didYouMean, label: option.label, send: send)
            }
        case .prompt(let prompt):
            func reply(_ label: String) -> Engine.Effect {
                let value = prompt.options.first { $0.label == label }?.value ?? label
                return .sendPromptReply(convoID: prompt.convoID, seq: prompt.seq, choice: value, text: nil)
            }
            switch ActionLabelMatcher.match(text, labels: prompt.labels) {
            case .clear(let label): startConfirm(.sending, label: label, send: reply(label))
            case .unsure(let label): startConfirm(.didYouMean, label: label, send: reply(label))
            case .none:
                fx.append(.discardRecording)
                fx.append(.sendPromptReply(convoID: prompt.convoID, seq: prompt.seq, choice: nil, text: text))
                sent(to: prompt.convoID, announce: false)
            }
        case .item(let item) where !item.needsScreen && !item.labels.isEmpty:
            switch ActionLabelMatcher.match(text, labels: item.labels) {
            case .clear(let label):
                startConfirm(.sending, label: label, send: .sendItemAction(itemID: item.id, label: label))
            case .unsure(let label):
                startConfirm(.didYouMean, label: label, send: .sendItemAction(itemID: item.id, label: label))
            case .none:
                sendPlain(announce: false)
            }
        case .item, .reply:
            sendPlain(announce: false)
        }
    }

    // MARK: Confirming

    mutating func startConfirm(_ kind: Engine.Confirm.Kind, label: String, send: Engine.Effect) {
        s.confirm = Engine.Confirm(kind: kind, label: label, send: send)
        say(kind == .sending ? VoicePhrases.sending(label) : VoicePhrases.didYouMean(label), .system, then: .confirm)
    }

    mutating func commitConfirm() {
        guard let confirm = s.confirm else { return }
        cancel(.confirm)
        s.confirm = nil
        fx.append(confirm.send)
        fx.append(.discardRecording)
        fx.append(.earcon(.sent))
        timer(.idle, s.config.idleEnd)
        next()
    }

    mutating func cancelConfirm(_ phrase: String, then: Engine.AfterPlayback = .listen) {
        cancel(.confirm)
        s.confirm = nil
        fx.append(.discardRecording)
        say(phrase, .system, then: then)
    }

    // MARK: Things arriving and going

    mutating func arrived(_ entry: VoiceEntry) {
        guard !s.said.contains(entry.id), !s.inbox.contains(where: { $0.id == entry.id }),
              !s.queue.contains(where: { $0.id == entry.id }) else { return }
        if case .reply(let reply) = entry.subject { s.working.remove(reply.convoID) }
        if s.paused {
            s.inbox.append(entry)
            return
        }
        switch s.phase {
        case .waiting:
            present(entry)
        case .listening where !s.speechSeen && s.confirm == nil:
            present(entry)
        case .idle, .listening, .sending, .confirming, .speaking:
            s.inbox.append(entry)
        }
    }

    mutating func resolved(_ id: String, expired: Bool) {
        s.inbox.removeAll { $0.id == id }
        s.queue.removeAll { $0.id == id }
        guard let current = s.current, current.id == id else { return }
        var wasPermission = false
        if case .prompt(let prompt) = current.subject { wasPermission = prompt.isPermission }
        if s.confirm != nil {
            cancel(.confirm)
            s.confirm = nil
            fx.append(.discardRecording)
        }
        // Mid-send or mid-sentence: what he is saying goes as a plain
        // message; only the thing it would have answered is gone.
        if s.phase == .sending || (s.phase == .listening && s.speechSeen) || s.paused {
            s.current = nil
            return
        }
        if expired, wasPermission {
            s.current = nil
            say(VoicePhrases.permissionExpired, .system, then: .next)
        } else if s.phase == .waiting {
            s.current = nil
        } else {
            next()
        }
    }

    // MARK: Playback and timers

    mutating func playbackFinished(_ id: Int) {
        guard s.phase == .speaking, s.playing?.id == id else { return }
        cancel(.talkOverOnset)
        cancel(.talkOverWords)
        if s.ducked {
            fx.append(.restoreVolume)
            s.ducked = false
        }
        s.playing = nil
        if let notice = s.pendingNotice {
            s.pendingNotice = nil
            let after = s.after
            let askedGoOn = s.askedGoOn
            say(notice, .system, then: after)
            s.askedGoOn = askedGoOn
            return
        }
        switch s.after {
        case .listen:
            if s.current == nil, !s.inbox.isEmpty {
                present(s.inbox.removeFirst())
            } else {
                let askedGoOn = s.askedGoOn
                listen()
                s.askedGoOn = askedGoOn
            }
        case .confirm:
            guard let confirm = s.confirm else {
                listen()
                return
            }
            s.phase = .confirming
            s.caption = nil
            s.heard = ""
            if s.capture == nil {
                fx.append(.startCapture(.monitor))
                s.capture = .monitor
            }
            timer(.confirm, confirm.kind == .sending ? s.config.confirmWindow : s.config.noSpeechTimeout)
        case .wait:
            wait()
        case .next:
            next()
        }
    }

    mutating func timerFired(_ id: Engine.TimerID) {
        switch id {
        case .idle:
            finish(.idle)
        case .noSpeech:
            guard s.phase == .listening else { return }
            if s.confirm != nil {
                s.confirm = nil
                fx.append(.discardRecording)
            }
            wait()
        case .silence, .maxUtterance:
            guard s.phase == .listening else { return }
            finishUtterance()
        case .transcript:
            guard s.phase == .sending else { return }
            transcript(nil)
        case .confirm:
            guard s.phase == .confirming, let confirm = s.confirm else { return }
            if confirm.kind == .sending {
                commitConfirm()
            } else {
                cancelConfirm(VoicePhrases.notSent, then: .wait)
            }
        case .talkOverOnset:
            guard s.phase == .speaking, s.capture == .monitor else { return }
            fx.append(.duck)
            s.ducked = true
            timer(.talkOverWords, s.config.talkOverWords)
            interruptIfGenuine()
        case .talkOverWords:
            guard s.phase == .speaking, s.ducked else { return }
            // A cough, a door, or the clip hearing itself: carry on.
            fx.append(.restoreVolume)
            s.ducked = false
            s.heard = ""
            s.falseTriggers += 1
            if s.falseTriggers >= s.config.falseTriggerLimit {
                s.falseTriggers = 0
                s.talkOverOffRoutes.insert(s.route)
                s.pendingNotice = VoicePhrases.talkOverOff
                if s.capture == .monitor {
                    fx.append(.stopCapture(keep: false))
                    s.capture = nil
                }
            }
        }
    }

    // MARK: Pausing

    /// A call, Siri, or the app leaving the front: stop everything and let
    /// go of the audio. A send already on its way carries on.
    mutating func pause() {
        guard !s.paused else { return }
        s.paused = true
        guard s.phase != .sending else { return }
        if s.confirm != nil {
            cancel(.confirm)
            s.confirm = nil
            fx.append(.discardRecording)
        }
        // Cut off mid-sentence: it is said again on return.
        if s.phase == .speaking, let entry = s.current, s.playing?.level == .short {
            s.inbox.insert(entry, at: 0)
            s.said.remove(entry.id)
            s.current = nil
        }
        wait()
    }

    mutating func resume() {
        guard s.paused else { return }
        s.paused = false
        if s.phase == .waiting { wait() }
    }

    // MARK: Small things

    mutating func watch(_ convoID: String) {
        guard s.watched.insert(convoID).inserted else { return }
        fx.append(.watch(convoID: convoID))
    }

    mutating func timer(_ id: Engine.TimerID, _ interval: TimeInterval) {
        s.timers.insert(id)
        fx.append(.startTimer(id, interval))
    }

    mutating func cancel(_ id: Engine.TimerID) {
        guard s.timers.remove(id) != nil else { return }
        fx.append(.cancelTimer(id))
    }

    mutating func cancelListeningTimers() {
        for id in [Engine.TimerID.noSpeech, .silence, .maxUtterance, .talkOverOnset, .talkOverWords] { cancel(id) }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceModeEngineTests'`
Expected: `Executed 66 tests, with 0 failures`.

- [ ] **Step 5: Check the engine imports nothing it must not**

Run: `grep -rn "^import" MatronShared/Sources/Voice | grep -v -E "import (Foundation|MatronChat|MatronEvents|MatronJournal|MatronModels)$"`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Voice/VoiceModeEngine.swift MatronShared/Tests/VoiceTests/VoiceModeEngineTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: the engine, a pure reducer from events to effects" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: PR 1 verification and pull request

**Files:** none new.

- [ ] **Step 1: Run the whole shared suite**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --skip test_fileLog 2>&1 | tee /tmp/shared-test.log | grep -E "Test Suite '.*\.xctest' (passed|failed)|Executed [0-9]+ tests"`
Expected: every bundle passes except `DesignSystemSnapshotTests`, whose only failures are the ones named in Global Constraints. `VoiceTests.xctest` passes with `Executed 90 tests, with 0 failures`.

- [ ] **Step 2: Check both apps still build**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`
Run: `xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.
Run: `xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/mac CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Push and open PR 1**

```bash
git push -u origin feat/voice-data
gh pr create --base main --title "Voice mode (1/4): data and pure logic" --body "$(cat <<'BODY'
Phase 1 of spec 2026-10-03 (voice mode), the part with no audio and nothing on screen: the summary event's spoken lines (migration summary_spoken; v7's insert spelled out so old caches still open), store reads for the newest reply and unanswered prompts, the Markdown cleaner, and a new MatronVoice target with the command and label matchers, the what-needs-you queue and the engine as a pure reducer with 66 tests.

Plan: docs/superpowers/plans/2026-10-03-voice-mode-phase1-apple.md (Tasks 1–9)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

# PR 2 — speaking

Branch: `git worktree add ../matron-apple-voice-2 -b feat/voice-speaking feat/voice-data`.

At the end of this PR a hidden list can speak any turn's spoken line in either cloud voice or the on-device one, so the voices can be judged on a phone before the app can listen.

### Task 10: `JournalAPI+TTS` — `GET /tts/voices` and `POST /tts`

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalAPI.swift` (line 754, `private func rawRequest`)
- Create: `MatronShared/Sources/Journal/JournalAPI+TTS.swift`
- Test: `MatronShared/Tests/JournalTests/TTSAPITests.swift` (new; uses `StubURLProtocol` from `JournalAPITests.swift`)

**Interfaces:**
- Produces (MatronJournal): `struct TTSVoice: Identifiable { id, name, locale, gender }`; `struct TTSVoices { voices, defaultVoiceID }`; `enum TTSError { unavailable, failed(status:code:) }`; `protocol SpeechSynthesising: Sendable { func ttsVoices() async throws -> TTSVoices; func tts(text: String, voice: String?) async throws -> Data }`; `extension JournalAPI: SpeechSynthesising`; `JournalAPI.ttsTextLimit` (2,000).
- `ttsVoices()` throws `.unavailable` for 404 and 501 only. `tts` throws `.failed` for every non-200 and for an empty 200 body. A network failure surfaces as the existing `JournalAPIError.transport`. The caller (Task 12) treats every throw the same way.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/JournalTests/TTSAPITests.swift`:

```swift
import XCTest
@testable import MatronJournal

final class TTSAPITests: XCTestCase {
    private func makeAPI() -> JournalAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    private func bodyJSON() -> [String: Any]? {
        StubURLProtocol.lastRequestBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func testVoicesDecode() async throws {
        StubURLProtocol.responses = ["/tts/voices": (200, #"""
        {"voices":[{"id":"en-GB-Harry","name":"Harry","locale":"en-GB","gender":"male"},
                   {"id":"en-GB-Emily","name":"Emily","locale":"en-GB","gender":"female"},
                   {"name":"no id"}],
         "default":"en-GB-Harry"}
        """#)]
        let voices = try await makeAPI().ttsVoices()
        XCTAssertEqual(voices.voices.map(\.id), ["en-GB-Harry", "en-GB-Emily"])
        XCTAssertEqual(voices.voices.first?.name, "Harry")
        XCTAssertEqual(voices.defaultVoiceID, "en-GB-Harry")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    /// An old journal (404) and one with no key (501) both mean "use the
    /// on-device voice"; anything else is a failure to ask again later.
    func testVoicesUnavailableAndFailed() async {
        for (status, body) in [(404, #"{"error":"not_found"}"#), (501, #"{"error":"tts_unconfigured"}"#)] {
            StubURLProtocol.responses = ["/tts/voices": (status, body)]
            do {
                _ = try await makeAPI().ttsVoices()
                XCTFail("expected a throw for \(status)")
            } catch {
                XCTAssertEqual(error as? TTSError, .unavailable, "\(status)")
            }
        }
        StubURLProtocol.responses = ["/tts/voices": (503, #"{"error":"tts_busy"}"#)]
        do {
            _ = try await makeAPI().ttsVoices()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? TTSError, .failed(status: 503, code: "tts_busy"))
        }
    }

    func testClipPostsTextAndVoiceAndReturnsTheBytes() async throws {
        StubURLProtocol.responses = ["/tts": (200, "ID3-audio-bytes")]
        let audio = try await makeAPI().tts(text: "The deploy finished.", voice: "en-GB-Emily")
        XCTAssertEqual(audio, Data("ID3-audio-bytes".utf8))
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(bodyJSON()?["text"] as? String, "The deploy finished.")
        XCTAssertEqual(bodyJSON()?["voice"] as? String, "en-GB-Emily")
        XCTAssertNil(bodyJSON()?["format"], "the journal's default (mp3) is what the phone plays")
    }

    func testClipOmitsAnUnchosenVoiceAndCutsLongText() async throws {
        StubURLProtocol.responses = ["/tts": (200, "x")]
        _ = try await makeAPI().tts(text: String(repeating: "a", count: 2_500), voice: nil)
        XCTAssertNil(bodyJSON()?["voice"])
        XCTAssertEqual((bodyJSON()?["text"] as? String)?.count, 2_000)
    }

    /// Every answer that is not a clip is one error the player falls back
    /// on: the status and the journal's code ride along for the log.
    func testEveryNonClipAnswerIsAFailure() async {
        let cases: [(Int, String, String?)] = [
            (400, #"{"error":"unknown_voice"}"#, "unknown_voice"), (403, #"{"error":"forbidden"}"#, "forbidden"),
            (404, #"{"error":"not_found"}"#, "not_found"), (413, "", nil),
            (429, #"{"error":"tts_budget_exceeded"}"#, "tts_budget_exceeded"),
            (501, #"{"error":"tts_unconfigured"}"#, "tts_unconfigured"), (502, #"{"error":"tts_failed"}"#, "tts_failed"),
            (503, #"{"error":"tts_busy"}"#, "tts_busy"), (200, "", nil),
        ]
        for (status, body, code) in cases {
            StubURLProtocol.responses = ["/tts": (status, body)]
            do {
                _ = try await makeAPI().tts(text: "hi", voice: nil)
                XCTFail("expected a throw for \(status)")
            } catch {
                XCTAssertEqual(error as? TTSError, .failed(status: status, code: code), "\(status)")
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.TTSAPITests'`
Expected: build FAILS — `value of type 'JournalAPI' has no member 'ttsVoices'`.

- [ ] **Step 3: Let the extension reach the raw request**

In `JournalAPI.swift`, change `private func rawRequest(` to:

```swift
    /// Not `private`: `JournalAPI+TTS.swift` reads raw audio bytes and
    /// its own status codes through this.
    func rawRequest(
```

- [ ] **Step 4: Implement**

Create `MatronShared/Sources/Journal/JournalAPI+TTS.swift`:

```swift
import Foundation

/// One cloud voice the journal offers (`GET /tts/voices`).
public struct TTSVoice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let locale: String
    public let gender: String

    public init(id: String, name: String, locale: String = "en-GB", gender: String = "") {
        self.id = id; self.name = name; self.locale = locale; self.gender = gender
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, name: json["name"] as? String ?? id, locale: json["locale"] as? String ?? "",
                  gender: json["gender"] as? String ?? "")
    }
}

public struct TTSVoices: Equatable, Sendable {
    public let voices: [TTSVoice]
    /// The journal's own default, used when the user has not chosen.
    public let defaultVoiceID: String?

    public init(voices: [TTSVoice], defaultVoiceID: String?) {
        self.voices = voices; self.defaultVoiceID = defaultVoiceID
    }
}

public enum TTSError: Error, Equatable, Sendable {
    /// `GET /tts/voices` answered 404 (a journal that predates `/tts`) or
    /// 501 (no Azure key): this journal has no cloud voice. The only
    /// answer worth remembering for the session.
    case unavailable
    /// Any other answer that is not a clip: 400 `bad_request` /
    /// `unknown_voice`, 403, 413, 429 `tts_budget_exceeded`, 502
    /// `tts_failed`, 503 `tts_busy`, an empty body. Say the same text with
    /// the on-device voice, and ask again next time.
    case failed(status: Int, code: String?)
}

/// The journal's text-to-speech surface (spec 2026-10-03 §2), as a
/// protocol so the player tests against a fake.
public protocol SpeechSynthesising: Sendable {
    func ttsVoices() async throws -> TTSVoices
    /// The clip for `text` as MP3 bytes. `voice` nil = the journal's default.
    func tts(text: String, voice: String?) async throws -> Data
}

extension JournalAPI: SpeechSynthesising {
    /// `POST /tts` refuses longer text.
    public static let ttsTextLimit = 2_000

    static func decodeVoices(_ obj: [String: Any]) -> TTSVoices {
        let voices = (obj["voices"] as? [[String: Any]] ?? []).compactMap(TTSVoice.init(json:))
        return TTSVoices(voices: voices, defaultVoiceID: obj["default"] as? String)
    }

    private static func errorCode(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
    }

    public func ttsVoices() async throws -> TTSVoices {
        let (data, response) = try await rawRequest(path: "/tts/voices", method: "GET", body: nil)
        switch response.statusCode {
        case 200:
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw TTSError.failed(status: 200, code: "malformed")
            }
            return Self.decodeVoices(obj)
        case 404, 501:
            throw TTSError.unavailable
        default:
            throw TTSError.failed(status: response.statusCode, code: Self.errorCode(data))
        }
    }

    /// `format` is left to the journal's default (MP3, 24 kHz): the `wav`
    /// form is for notification sounds, a later phase. The response's
    /// `ETag` is the audio's SHA-256 and the journal does not act on
    /// `If-None-Match`, so nothing here revalidates: the phone caches by
    /// its own key (`SpeechClipCache`).
    public func tts(text: String, voice: String?) async throws -> Data {
        var body: [String: Any] = ["text": String(text.prefix(Self.ttsTextLimit))]
        if let voice { body["voice"] = voice }
        let (data, response) = try await rawRequest(path: "/tts", method: "POST", body: body)
        guard response.statusCode == 200, !data.isEmpty else {
            throw TTSError.failed(status: response.statusCode, code: Self.errorCode(data))
        }
        return data
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.(TTSAPITests|JournalAPITests)'`
Expected: `Executed 5 tests, with 0 failures` and `Executed 39 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Journal/JournalAPI.swift MatronShared/Sources/Journal/JournalAPI+TTS.swift \
        MatronShared/Tests/JournalTests/TTSAPITests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: JournalAPI text-to-speech routes" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: The fixed-phrase cache, earcons and settings

**Files:**
- Create: `MatronShared/Sources/Voice/SpeechClipCache.swift`, `EarconSynth.swift`, `VoiceSettings.swift`
- Test: `MatronShared/Tests/VoiceTests/VoiceSupportTests.swift` (new)

**Interfaces:**
- Consumes: `VoicePhrases.fixed` (Task 6), `VoiceModeEngine.Earcon` and `Config` (Task 8), `TTSVoice` (Task 10).
- Produces (MatronVoice):
  - `struct SpeechClipCache { directory, limit }` — `standard()` (`Library/Caches/voice-clips`), `isCacheable(_:)`, `clip(text:voice:) -> Data?`, `store(_:text:voice:)`, `removeAll()`; key = SHA-256 of `voice + "\n" + text`.
  - `enum EarconSynth` — `wav(_:) -> Data`, `duration(_:)`; three earcons: `micOpen`, `sent`, `error`.
  - `@MainActor @Observable final class VoiceSettings` — `voice: String?` (`nil` = the journal's default; `VoiceSettings.onDevice` = never ask the journal), `rate` (0.8…1.5), `talkOver`, `offerMore`, `debugTools`; `init(defaults:talkOverDefault:)`; `engineConfig(_:)`; `builtInVoices` (Harry, Emily).

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/VoiceTests/VoiceSupportTests.swift`:

```swift
import XCTest
@testable import MatronVoice

final class VoiceSupportTests: XCTestCase {
    // MARK: SpeechClipCache

    func testOnlyFixedPhrasesAreKept() {
        let cache = SpeechClipCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { cache.removeAll() }
        cache.store(Data("a".utf8), text: VoicePhrases.sent, voice: "en-GB-Harry")
        cache.store(Data("b".utf8), text: "The deploy finished.", voice: "en-GB-Harry")
        XCTAssertEqual(cache.clip(text: VoicePhrases.sent, voice: "en-GB-Harry"), Data("a".utf8))
        XCTAssertNil(cache.clip(text: "The deploy finished.", voice: "en-GB-Harry"))
        XCTAssertNil(cache.clip(text: VoicePhrases.sent, voice: "en-GB-Emily"), "keyed by voice as well as text")
        XCTAssertTrue(SpeechClipCache.isCacheable("Three things need you."))
        XCTAssertFalse(SpeechClipCache.isCacheable("Sending: Go."))
    }

    func testTheKeyIsAHashOfVoiceAndText() {
        XCTAssertEqual(SpeechClipCache.key(text: "Sent.", voice: "v").count, 64)
        XCTAssertNotEqual(SpeechClipCache.key(text: "Sent.", voice: "a"), SpeechClipCache.key(text: "Sent.", voice: "b"))
        XCTAssertEqual(SpeechClipCache.key(text: "Sent.", voice: "a"), SpeechClipCache.key(text: "Sent.", voice: "a"))
    }

    func testTheOldestClipsGoWhenTheCacheIsFull() {
        let cache = SpeechClipCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), limit: 2)
        defer { cache.removeAll() }
        let phrases = [VoicePhrases.sent, VoicePhrases.cancelled, VoicePhrases.denied]
        for (index, phrase) in phrases.enumerated() {
            cache.store(Data("x".utf8), text: phrase, voice: "v")
            // Modification dates a second apart, so "oldest" is well defined.
            let url = cache.url(text: phrase, voice: "v")
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + index))],
                                                   ofItemAtPath: url.path)
        }
        cache.store(Data("x".utf8), text: VoicePhrases.notSent, voice: "v")
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path)) ?? []
        XCTAssertEqual(kept.count, 2)
        XCTAssertNil(cache.clip(text: VoicePhrases.sent, voice: "v"))
        XCTAssertNotNil(cache.clip(text: VoicePhrases.notSent, voice: "v"))
    }

    // MARK: EarconSynth

    func testEarconsAreShortValidWavFiles() {
        for earcon in VoiceModeEngine.Earcon.allCases {
            let wav = EarconSynth.wav(earcon)
            XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
            let samples = EarconSynth.samples(earcon)
            XCTAssertEqual(wav.count, 44 + samples.count * 2)
            XCTAssertLessThan(EarconSynth.duration(earcon), 0.35)
            XCTAssertEqual(samples.first, 0, "fades in from silence")
            XCTAssertLessThanOrEqual(samples.map { abs(Int($0)) }.max() ?? 0, Int(Double(Int16.max) * 0.36))
        }
        XCTAssertNotEqual(EarconSynth.wav(.micOpen), EarconSynth.wav(.error))
    }

    // MARK: VoiceSettings

    @MainActor
    func testSettingsDefaultPersistAndClamp() {
        let name = "voice-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let settings = VoiceSettings(defaults: defaults)
        XCTAssertNil(settings.voice); XCTAssertEqual(settings.rate, 1)
        XCTAssertTrue(settings.talkOver); XCTAssertTrue(settings.offerMore)
        XCTAssertFalse(settings.usesOnDeviceVoice); XCTAssertFalse(settings.debugTools)
        settings.voice = VoiceSettings.onDevice
        settings.rate = 1.3
        settings.talkOver = false
        settings.offerMore = false
        settings.debugTools = true
        let reloaded = VoiceSettings(defaults: defaults)
        XCTAssertTrue(reloaded.usesOnDeviceVoice); XCTAssertEqual(reloaded.rate, 1.3)
        XCTAssertFalse(reloaded.talkOver); XCTAssertFalse(reloaded.offerMore); XCTAssertTrue(reloaded.debugTools)
        let config = reloaded.engineConfig()
        XCTAssertFalse(config.talkOver); XCTAssertFalse(config.offerMore)
        defaults.set(9.0, forKey: "matron.voice.rate")
        XCTAssertEqual(VoiceSettings(defaults: defaults).rate, 1.5, "a stored rate out of range is clamped")
        // The spike's fallback: off until the user turns it on.
        let fresh = UserDefaults(suiteName: name + "-b")!
        defer { UserDefaults().removePersistentDomain(forName: name + "-b") }
        XCTAssertFalse(VoiceSettings(defaults: fresh, talkOverDefault: false).talkOver)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceSupportTests'`
Expected: build FAILS — `cannot find 'SpeechClipCache' in scope`.

- [ ] **Step 3: Implement the cache**

Create `MatronShared/Sources/Voice/SpeechClipCache.swift`:

```swift
import CryptoKit
import Foundation

/// A small on-disk cache of cloud clips for the fixed phrases ("Sent",
/// "Three things need you"), so they play at once and cost nothing after
/// first use (spec 2026-10-03 §3, "Playing"). Keyed by the phone's own
/// hash of voice and text: the journal's `ETag` is not revalidated.
/// Replies are never cached here; the journal keeps those for a day.
public struct SpeechClipCache: Sendable {
    public let directory: URL
    /// Oldest clips beyond this many are deleted on write.
    public let limit: Int

    public init(directory: URL, limit: Int = 96) {
        self.directory = directory
        self.limit = limit
    }

    /// `Library/Caches/voice-clips`: the system may empty it; nothing is lost.
    public static func standard() -> SpeechClipCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return SpeechClipCache(directory: caches.appendingPathComponent("voice-clips", isDirectory: true))
    }

    /// Only the fixed phrases are worth keeping.
    public static func isCacheable(_ text: String) -> Bool {
        fixed.contains(text)
    }

    private static let fixed = Set(VoicePhrases.fixed)

    static func key(text: String, voice: String) -> String {
        let digest = SHA256.hash(data: Data("\(voice)\n\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func url(text: String, voice: String) -> URL {
        directory.appendingPathComponent(Self.key(text: text, voice: voice) + ".mp3")
    }

    public func clip(text: String, voice: String) -> Data? {
        guard let data = try? Data(contentsOf: url(text: text, voice: voice)), !data.isEmpty else { return nil }
        return data
    }

    public func store(_ audio: Data, text: String, voice: String) {
        guard Self.isCacheable(text), !audio.isEmpty else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? audio.write(to: url(text: text, voice: voice), options: .atomic)
        trim()
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func trim() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > limit else { return }
        let dated = files.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) {
            try? manager.removeItem(at: url)
        }
    }
}
```

- [ ] **Step 4: Implement the earcons**

Create `MatronShared/Sources/Voice/EarconSynth.swift`:

```swift
import Foundation

/// The three short sounds that mark a state change, so nothing needs a
/// glance at the screen (spec 2026-10-03 §3, §11). Made here as WAV bytes
/// rather than shipped as files: two sine notes each, a few hundred
/// milliseconds, with a short fade at both ends so they do not click.
public enum EarconSynth {
    public static let sampleRate = 24_000

    /// (frequency in Hz, seconds) for each note.
    static func notes(_ earcon: VoiceModeEngine.Earcon) -> [(Double, Double)] {
        switch earcon {
        case .micOpen: return [(660, 0.07), (880, 0.09)]    // up: go ahead
        case .sent: return [(880, 0.06), (1_175, 0.10)]     // up and away
        case .error: return [(392, 0.12), (294, 0.16)]      // down
        }
    }

    public static func duration(_ earcon: VoiceModeEngine.Earcon) -> TimeInterval {
        notes(earcon).reduce(0) { $0 + $1.1 }
    }

    /// 16-bit mono PCM samples.
    static func samples(_ earcon: VoiceModeEngine.Earcon) -> [Int16] {
        var out: [Int16] = []
        let fade = Int(Double(sampleRate) * 0.008)
        for (frequency, seconds) in notes(earcon) {
            let count = Int(Double(sampleRate) * seconds)
            for index in 0..<count {
                let envelope = min(1, Double(min(index, count - 1 - index)) / Double(fade))
                let value = sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate))
                out.append(Int16(value * envelope * 0.35 * Double(Int16.max)))
            }
        }
        return out
    }

    /// A complete WAV file (RIFF header + PCM), playable by any player.
    public static func wav(_ earcon: VoiceModeEngine.Earcon) -> Data {
        let samples = samples(earcon)
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                      // PCM chunk size
        append(UInt16(1))                       // PCM
        append(UInt16(1))                       // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))          // byte rate
        append(UInt16(2))                       // block align
        append(UInt16(16))                      // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples { append(sample) }
        return data
    }
}
```

- [ ] **Step 5: Implement the settings**

Create `MatronShared/Sources/Voice/VoiceSettings.swift`:

```swift
import Foundation
import Observation
import MatronJournal

/// Voice mode's settings (spec 2026-10-03 §6): which voice, how fast,
/// whether talking over the agent interrupts it, and whether "more" is
/// offered after a reply. Per device, in `UserDefaults`.
@MainActor
@Observable
public final class VoiceSettings {
    /// The voice id sent to `POST /tts`; `onDevice` never asks the journal.
    public static let onDevice = "on-device"
    /// The cloud voices offered before `GET /tts/voices` has answered.
    public static let builtInVoices = [TTSVoice(id: "en-GB-Harry", name: "Harry", gender: "male"),
                                       TTSVoice(id: "en-GB-Emily", name: "Emily", gender: "female")]
    public static let rateRange: ClosedRange<Double> = 0.8...1.5

    enum Key {
        static let voice = "matron.voice.voice"
        static let rate = "matron.voice.rate"
        static let talkOver = "matron.voice.talkOver"
        static let offerMore = "matron.voice.offerMore"
        static let debugTools = "matron.voice.debugTools"
    }

    private let defaults: UserDefaults

    /// `nil` = the journal's default voice.
    public var voice: String? { didSet { defaults.set(voice, forKey: Key.voice) } }
    public var rate: Double { didSet { defaults.set(rate, forKey: Key.rate) } }
    public var talkOver: Bool { didSet { defaults.set(talkOver, forKey: Key.talkOver) } }
    public var offerMore: Bool { didSet { defaults.set(offerMore, forKey: Key.offerMore) } }
    /// Shows "Speak a reply" in a conversation's Session sheet. Hidden:
    /// switched by a long press on the settings section's title, so the
    /// voice can be judged on a TestFlight build, where `MatronDebug` is off.
    public var debugTools: Bool { didSet { defaults.set(debugTools, forKey: Key.debugTools) } }

    /// - Parameter talkOverDefault: what "Talk over the agent" is before
    ///   the user touches it. `true` per the spec; the PR 3 spike's
    ///   fallback ships it `false`.
    public init(defaults: UserDefaults = .standard, talkOverDefault: Bool = true) {
        self.defaults = defaults
        voice = defaults.string(forKey: Key.voice)
        let stored = defaults.object(forKey: Key.rate) as? Double ?? 1
        rate = min(max(stored, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        talkOver = defaults.object(forKey: Key.talkOver) as? Bool ?? talkOverDefault
        offerMore = defaults.object(forKey: Key.offerMore) as? Bool ?? true
        debugTools = defaults.bool(forKey: Key.debugTools)
    }

    public var usesOnDeviceVoice: Bool { voice == Self.onDevice }

    /// These settings as the engine reads them.
    public func engineConfig(_ base: VoiceModeEngine.Config = VoiceModeEngine.Config()) -> VoiceModeEngine.Config {
        var config = base
        config.talkOver = talkOver
        config.offerMore = offerMore
        return config
    }
}
```

- [ ] **Step 6: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceSupportTests'`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add MatronShared/Sources/Voice/SpeechClipCache.swift MatronShared/Sources/Voice/EarconSynth.swift \
        MatronShared/Sources/Voice/VoiceSettings.swift MatronShared/Tests/VoiceTests/VoiceSupportTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: fixed-phrase cache, earcons and settings" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: `SpeechPlayer` — the cloud clip, with the on-device voice behind it

**Files:**
- Create: `MatronShared/Sources/Voice/SpeechPlayer.swift`, `MatronShared/Sources/Voice/SystemVoiceOutputs.swift`
- Test: `MatronShared/Tests/VoiceTests/SpeechPlayerTests.swift` (new)

**Interfaces:**
- Consumes: `SpeechSynthesising` (Task 10); `SpeechClipCache`, `EarconSynth`, `VoiceSettings` (Task 11).
- Produces (MatronVoice):
  - `@MainActor protocol ClipOutput { func play(_ audio: Data, rate: Double) async throws; func playEffect(_ audio: Data); func stop(); func setVolume(_ volume: Float) }`.
  - `@MainActor protocol LocalVoice { func speak(_ text: String, rate: Double) async; func stop(); func setVolume(_ volume: Float) }`.
  - `@MainActor final class SpeechPlayer` — `init(synth:cache:output:local:settings:firstAudioTimeout:)`, `refreshVoices() async`, `@discardableResult speak(_:) async -> Source` (`cloud`, `cache`, `onDevice`, `stopped`), `stop()`, `setDucked(_:)`, `play(_ earcon:)`; `cloudUnavailable`, `voices`, `defaultVoiceID`; `duckedVolume` (0.2).
  - `PlayerClipOutput` (`AVAudioPlayer`) and `SynthesizerLocalVoice` (`AVSpeechSynthesizer`), used by this PR's debug list. PR 3 adds the outputs that play through the capture engine.
- The rule, exactly: on-device when the setting says so, when `cloudUnavailable`, or when the text is longer than 2,000 characters; otherwise the cached clip if there is one; otherwise `POST /tts` raced against `firstAudioTimeout` (2 s), and on ANY failure, an unplayable clip or the timeout, the same text on the device. Only a clip that actually played is cached, and only for a fixed phrase.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/VoiceTests/SpeechPlayerTests.swift`:

```swift
import XCTest
import MatronJournal
@testable import MatronVoice

@MainActor
final class SpeechPlayerTests: XCTestCase {
    final class FakeSynth: SpeechSynthesising, @unchecked Sendable {
        var voicesResult: Result<TTSVoices, Error> = .success(TTSVoices(voices: [], defaultVoiceID: nil))
        var clip: Result<Data, Error> = .success(Data("clip".utf8))
        var delay: Duration = .zero
        var requests: [(text: String, voice: String?)] = []
        var voiceRequests = 0

        func ttsVoices() async throws -> TTSVoices {
            voiceRequests += 1
            return try voicesResult.get()
        }

        func tts(text: String, voice: String?) async throws -> Data {
            requests.append((text, voice))
            if delay > .zero { try await Task.sleep(for: delay) }
            return try clip.get()
        }
    }

    final class FakeOutput: ClipOutput {
        var played: [(audio: Data, rate: Double)] = []
        var effects: [Data] = []
        var volumes: [Float] = []
        var stops = 0
        var failure: Error?
        func play(_ audio: Data, rate: Double) async throws {
            if let failure { throw failure }
            played.append((audio, rate))
        }
        func playEffect(_ audio: Data) { effects.append(audio) }
        func stop() { stops += 1 }
        func setVolume(_ volume: Float) { volumes.append(volume) }
    }

    final class FakeLocal: LocalVoice {
        var spoken: [(text: String, rate: Double)] = []
        var volumes: [Float] = []
        func speak(_ text: String, rate: Double) async { spoken.append((text, rate)) }
        func stop() {}
        func setVolume(_ volume: Float) { volumes.append(volume) }
    }

    var synth: FakeSynth!
    var output: FakeOutput!
    var local: FakeLocal!
    var settings: VoiceSettings!
    var cache: SpeechClipCache!
    var defaultsName: String!

    override func setUp() async throws {
        synth = FakeSynth()
        output = FakeOutput()
        local = FakeLocal()
        defaultsName = "voice-player-\(UUID().uuidString)"
        settings = VoiceSettings(defaults: UserDefaults(suiteName: defaultsName)!)
        cache = SpeechClipCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(defaultsName))
    }

    override func tearDown() async throws {
        cache.removeAll()
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    func player(timeout: Duration = .seconds(2)) -> SpeechPlayer {
        SpeechPlayer(synth: synth, cache: cache, output: output, local: local, settings: settings, firstAudioTimeout: timeout)
    }

    func testACloudClipIsPlayedAtTheChosenRateInTheChosenVoice() async {
        settings.voice = "en-GB-Emily"
        settings.rate = 1.2
        let source = await player().speak("The deploy finished.")
        XCTAssertEqual(source, .cloud)
        XCTAssertEqual(synth.requests.first?.text, "The deploy finished.")
        XCTAssertEqual(synth.requests.first?.voice, "en-GB-Emily")
        XCTAssertEqual(output.played.first?.audio, Data("clip".utf8))
        XCTAssertEqual(output.played.first?.rate, 1.2)
        XCTAssertTrue(local.spoken.isEmpty)
    }

    /// Any answer that is not a clip: the same text, on the device.
    func testEveryFailureFallsBackToTheOnDeviceVoice() async {
        let failures: [Error] = [
            TTSError.failed(status: 429, code: "tts_budget_exceeded"), TTSError.failed(status: 501, code: "tts_unconfigured"),
            TTSError.failed(status: 503, code: "tts_busy"), TTSError.failed(status: 404, code: "not_found"),
            TTSError.failed(status: 502, code: "tts_failed"), JournalAPIError.transport("offline"),
        ]
        for failure in failures {
            synth.clip = .failure(failure)
            local.spoken = []
            let source = await player().speak("Sent.")
            XCTAssertEqual(source, .onDevice, "\(failure)")
            XCTAssertEqual(local.spoken.map(\.text), ["Sent."])
        }
        XCTAssertTrue(output.played.isEmpty)
    }

    func testNoAudioWithinTheTimeoutFallsBack() async {
        synth.delay = .seconds(5)
        let source = await player(timeout: .milliseconds(50)).speak("Slow line.")
        XCTAssertEqual(source, .onDevice)
        XCTAssertEqual(local.spoken.map(\.text), ["Slow line."])
    }

    func testAClipThatWillNotPlayFallsBack() async {
        output.failure = ClipOutputError.cannotPlay
        let source = await player().speak("Garbled.")
        XCTAssertEqual(source, .onDevice)
    }

    func testTheOnDeviceSettingNeverAsksTheJournal() async {
        settings.voice = VoiceSettings.onDevice
        let source = await player().speak("Hello.")
        XCTAssertEqual(source, .onDevice)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    /// Only 404/501 from the voices route is remembered for the session.
    func testAJournalWithNoCloudVoiceIsRememberedButOtherFailuresAreNot() async {
        let speaker = player()
        synth.voicesResult = .failure(TTSError.failed(status: 503, code: "tts_busy"))
        await speaker.refreshVoices()
        XCTAssertFalse(speaker.cloudUnavailable)
        _ = await speaker.speak("One.")
        XCTAssertEqual(synth.requests.count, 1)
        synth.voicesResult = .failure(TTSError.unavailable)
        await speaker.refreshVoices()
        XCTAssertTrue(speaker.cloudUnavailable)
        let source = await speaker.speak("Two.")
        XCTAssertEqual(source, .onDevice)
        XCTAssertEqual(synth.requests.count, 1, "not asked again")
    }

    func testVoicesAndTheJournalsDefaultAreKept() async {
        synth.voicesResult = .success(TTSVoices(voices: [TTSVoice(id: "en-GB-Emily", name: "Emily")], defaultVoiceID: "en-GB-Emily"))
        let speaker = player()
        XCTAssertEqual(speaker.voices.map(\.id), ["en-GB-Harry", "en-GB-Emily"], "the built-in pair until the journal answers")
        await speaker.refreshVoices()
        XCTAssertEqual(speaker.voices.map(\.id), ["en-GB-Emily"])
        _ = await speaker.speak("Hi.")
        XCTAssertEqual(synth.requests.first?.voice, "en-GB-Emily", "no choice made: the journal's default")
    }

    func testAFixedPhraseIsFetchedOnceThenPlayedFromThePhone() async {
        let speaker = player()
        let first = await speaker.speak(VoicePhrases.sent)
        let second = await speaker.speak(VoicePhrases.sent)
        XCTAssertEqual(first, .cloud)
        XCTAssertEqual(second, .cache)
        XCTAssertEqual(synth.requests.count, 1)
        // A reply is never kept.
        _ = await speaker.speak("The deploy finished.")
        _ = await speaker.speak("The deploy finished.")
        XCTAssertEqual(synth.requests.count, 3)
        // Another voice is another clip.
        settings.voice = "en-GB-Emily"
        let other = await speaker.speak(VoicePhrases.sent)
        XCTAssertEqual(other, .cloud)
    }

    func testTextTooLongForTheJournalIsSaidOnTheDevice() async {
        let source = await player().speak(String(repeating: "word ", count: 500))
        XCTAssertEqual(source, .onDevice)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    func testALineOvertakenWhileItsClipWasOnItsWaySaysNothing() async {
        synth.delay = .milliseconds(100)
        let speaker = player()
        async let first = speaker.speak("First.")
        try? await Task.sleep(for: .milliseconds(20))
        speaker.stop()
        let source = await first
        XCTAssertEqual(source, .stopped)
        XCTAssertTrue(output.played.isEmpty)
        XCTAssertTrue(local.spoken.isEmpty)
    }

    func testDuckingAndEarcons() {
        let speaker = player()
        speaker.setDucked(true)
        speaker.setDucked(false)
        XCTAssertEqual(output.volumes, [0.2, 1])
        XCTAssertEqual(local.volumes, [0.2, 1])
        speaker.play(.sent)
        XCTAssertEqual(output.effects, [EarconSynth.wav(.sent)])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'VoiceTests.SpeechPlayerTests'`
Expected: build FAILS — `cannot find type 'ClipOutput' in scope`.

- [ ] **Step 3: Implement the player**

Create `MatronShared/Sources/Voice/SpeechPlayer.swift`:

```swift
import Foundation
import MatronJournal
import os

/// Where encoded audio (a cloud clip, an earcon) is played. PR 2's
/// `PlayerClipOutput` is a plain `AVAudioPlayer`; voice mode proper plays
/// through the capture engine instead, so the echo canceller can take the
/// agent's voice back out of the microphone (`VoiceAudioEngine`).
@MainActor
public protocol ClipOutput: AnyObject {
    /// Plays `audio` (MP3 or WAV) to its end. Returns early, without
    /// throwing, when `stop()` is called. Throws when it cannot be played.
    func play(_ audio: Data, rate: Double) async throws
    /// Plays a short sound over whatever else is playing; does not wait.
    func playEffect(_ audio: Data)
    func stop()
    func setVolume(_ volume: Float)
}

/// The on-device voice: the fallback when the journal has no clip to give.
@MainActor
public protocol LocalVoice: AnyObject {
    /// Speaks `text` to its end, or until `stop()`.
    func speak(_ text: String, rate: Double) async
    func stop()
    func setVolume(_ volume: Float)
}

/// Says a line (spec 2026-10-03 §3, "Playing"): the journal's clip, and on
/// ANY failure to get one — a status that is not 200, no network, or no
/// audio within two seconds — the same text in the on-device voice. Fixed
/// phrases are kept on the phone after first use.
@MainActor
public final class SpeechPlayer {
    public enum Source: String, Equatable, Sendable { case cloud, cache, onDevice, stopped }

    /// How loud a clip is while someone may be talking over it.
    public static let duckedVolume: Float = 0.2

    private static let logger = Logger(subsystem: "chat.matron", category: "voice-player")

    private let synth: any SpeechSynthesising
    private let cache: SpeechClipCache
    private let output: any ClipOutput
    private let local: any LocalVoice
    private let settings: VoiceSettings
    private let firstAudioTimeout: Duration
    /// Bumped by every `speak` and `stop`: a line that was overtaken while
    /// its clip was still on its way says nothing when the clip lands.
    private var generation = 0

    /// `GET /tts/voices` answered 404 or 501: this journal has no cloud
    /// voice, and nothing asks it again this session. No other failure is
    /// remembered.
    public private(set) var cloudUnavailable = false
    public private(set) var voices: [TTSVoice] = VoiceSettings.builtInVoices
    public private(set) var defaultVoiceID: String?

    public init(synth: any SpeechSynthesising, cache: SpeechClipCache, output: any ClipOutput, local: any LocalVoice,
                settings: VoiceSettings, firstAudioTimeout: Duration = .seconds(2)) {
        self.synth = synth
        self.cache = cache
        self.output = output
        self.local = local
        self.settings = settings
        self.firstAudioTimeout = firstAudioTimeout
    }

    /// Asks the journal which voices it has. Call when voice mode or its
    /// settings open.
    public func refreshVoices() async {
        do {
            let answer = try await synth.ttsVoices()
            if !answer.voices.isEmpty { voices = answer.voices }
            defaultVoiceID = answer.defaultVoiceID
            cloudUnavailable = false
        } catch TTSError.unavailable {
            cloudUnavailable = true
        } catch {
            Self.logger.info("voices: \(String(describing: error), privacy: .public)")
        }
    }

    /// Speaks `text` and returns when it has been said, or was stopped.
    @discardableResult
    public func speak(_ text: String) async -> Source {
        generation += 1
        let mine = generation
        output.stop()
        local.stop()
        let rate = settings.rate
        guard !settings.usesOnDeviceVoice, !cloudUnavailable, text.count <= JournalAPI.ttsTextLimit else {
            return await speakLocally(text, rate: rate, generation: mine)
        }
        let voice = settings.voice ?? defaultVoiceID
        let cacheVoice = voice ?? "default"
        if let cached = cache.clip(text: text, voice: cacheVoice) {
            do {
                try await output.play(cached, rate: rate)
                return mine == generation ? .cache : .stopped
            } catch {
                Self.logger.info("cached clip would not play; asking again")
            }
        }
        guard mine == generation else { return .stopped }
        let audio = await fetch(text, voice: voice)
        guard mine == generation else { return .stopped }
        guard let audio else { return await speakLocally(text, rate: rate, generation: mine) }
        do {
            try await output.play(audio, rate: rate)
            cache.store(audio, text: text, voice: cacheVoice)
            return mine == generation ? .cloud : .stopped
        } catch {
            guard mine == generation else { return .stopped }
            return await speakLocally(text, rate: rate, generation: mine)
        }
    }

    public func stop() {
        generation += 1
        output.stop()
        local.stop()
    }

    public func setDucked(_ ducked: Bool) {
        let volume = ducked ? Self.duckedVolume : 1
        output.setVolume(volume)
        local.setVolume(volume)
    }

    public func play(_ earcon: VoiceModeEngine.Earcon) {
        output.playEffect(EarconSynth.wav(earcon))
    }

    private func speakLocally(_ text: String, rate: Double, generation mine: Int) async -> Source {
        await local.speak(text, rate: rate)
        return mine == generation ? .onDevice : .stopped
    }

    /// The clip, or `nil` on any error or when none has arrived in time.
    private func fetch(_ text: String, voice: String?) async -> Data? {
        let synth = self.synth
        let timeout = firstAudioTimeout
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                do {
                    return try await synth.tts(text: text, voice: voice)
                } catch {
                    Self.logger.info("tts: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
```

- [ ] **Step 4: Implement the two system outputs**

Create `MatronShared/Sources/Voice/SystemVoiceOutputs.swift`:

```swift
import AVFoundation
import Foundation

public enum ClipOutputError: Error, Equatable, Sendable { case cannotPlay }

/// Plays clips with `AVAudioPlayer`. Enough to judge the voice (the PR 2
/// debug action); voice mode itself plays through `VoiceAudioEngine`.
@MainActor
public final class PlayerClipOutput: NSObject, ClipOutput, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var effects: [AVAudioPlayer] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var volume: Float = 1

    public override init() {}

    public func play(_ audio: Data, rate: Double) async throws {
        stop()
        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        player.enableRate = true
        player.rate = Float(rate)
        player.volume = volume
        self.player = player
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            if !player.play() {
                self.continuation = nil
                self.player = nil
                continuation.resume(throwing: ClipOutputError.cannotPlay)
            }
        }
    }

    public func playEffect(_ audio: Data) {
        guard let player = try? AVAudioPlayer(data: audio) else { return }
        effects.removeAll { !$0.isPlaying }
        effects.append(player)
        player.play()
    }

    public func stop() {
        player?.stop()
        player = nil
        continuation?.resume()
        continuation = nil
    }

    public func setVolume(_ volume: Float) {
        self.volume = volume
        player?.volume = volume
    }

    private func finished(_ finishedPlayer: AVAudioPlayer, error: Error?) {
        guard finishedPlayer === player else { return }
        player = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished(player, error: flag ? nil : ClipOutputError.cannotPlay) }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finished(player, error: error ?? ClipOutputError.cannotPlay) }
    }
}

/// The on-device voice, straight to the speaker.
@MainActor
public final class SynthesizerLocalVoice: NSObject, LocalVoice, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var volume: Float = 1

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The utterance both on-device paths build: a British voice, at the
    /// user's rate.
    public static func utterance(_ text: String, rate: Double, volume: Float) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * Float(rate), AVSpeechUtteranceMinimumSpeechRate),
                             AVSpeechUtteranceMaximumSpeechRate)
        utterance.volume = volume
        return utterance
    }

    public func speak(_ text: String, rate: Double) async {
        stop()
        let utterance = Self.utterance(text, rate: rate, volume: volume)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    public func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        continuation?.resume()
        continuation = nil
    }

    /// Takes effect from the next line: an utterance's volume is fixed
    /// once it starts.
    public func setVolume(_ volume: Float) {
        self.volume = volume
    }

    private func finished() {
        continuation?.resume()
        continuation = nil
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'VoiceTests.(SpeechPlayerTests|VoiceSupportTests)'`
Expected: `Executed 11 tests, with 0 failures` and `Executed 5 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Voice/SpeechPlayer.swift MatronShared/Sources/Voice/SystemVoiceOutputs.swift \
        MatronShared/Tests/VoiceTests/SpeechPlayerTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: SpeechPlayer says a line in the cloud voice, or on the device when it cannot" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: Settings ▸ Voice mode on iOS

**Files:**
- Modify: `project.yml` (the `Matron` target's dependencies after `MatronSearch` at line 192; the `MatronTests` target's after `MatronDesignSystem` at line 337)
- Modify: `Matron/App/AppDependencies.swift` (imports at line 13; before `pushService(for:)` at line 594)
- Modify: `Matron/App/AppShellView.swift` (imports at line 7; state at line 30; environment at line 113)
- Modify: `Matron/Features/Settings/DeviceSettingsView.swift` (imports; line 27; before `Section("Storage")` at line 81)
- Create: `Matron/Features/Voice/VoiceSettingsSection.swift`
- Test: `MatronTests/VoiceSettingsTests.swift` (new)

**Interfaces:**
- Consumes: `VoiceSettings`, `SpeechSynthesising`, `TTSVoice`.
- Produces: `AppDependencies.speechSynthesiser(for:) -> any SpeechSynthesising`; `VoiceSettings` in the shell's environment (`@Environment(VoiceSettings.self)`); `VoiceSettingsSection(settings:synth:)` with `static func selection(stored:defaultVoiceID:voices:cloudUnavailable:) -> String` and `static func rateLabel(_:) -> String`.

- [ ] **Step 1: Link `MatronVoice` into the app and its tests**

In `project.yml`, in the `Matron` target's `dependencies`, after the `MatronSearch` entry:

```yaml
      # Voice mode (spec 2026-10-03): the engine, player and capture.
      - package: MatronShared
        product: MatronVoice
```

and in the `MatronTests` target's `dependencies`, after its `MatronDesignSystem` entry:

```yaml
      # Voice mode navigation and screen-mapping tests build engine values.
      - package: MatronShared
        product: MatronVoice
```

- [ ] **Step 2: Write the failing test**

Create `MatronTests/VoiceSettingsTests.swift`:

```swift
import XCTest
import MatronJournal
import MatronVoice
@testable import Matron

/// Voice mode's settings section and the hidden "Speak a reply" list
/// (spec 2026-10-03 §6; plan PR 2).
@MainActor
final class VoiceSettingsTests: XCTestCase {
    func test_voicePickerSelection() {
        let voices = VoiceSettings.builtInVoices
        XCTAssertEqual(VoiceSettingsSection.selection(stored: nil, defaultVoiceID: "en-GB-Emily", voices: voices,
                                                      cloudUnavailable: false), "en-GB-Emily", "the journal's default")
        XCTAssertEqual(VoiceSettingsSection.selection(stored: nil, defaultVoiceID: nil, voices: voices,
                                                      cloudUnavailable: false), "en-GB-Harry", "else the first on offer")
        XCTAssertEqual(VoiceSettingsSection.selection(stored: "en-GB-Emily", defaultVoiceID: "en-GB-Harry", voices: voices,
                                                      cloudUnavailable: false), "en-GB-Emily")
        XCTAssertEqual(VoiceSettingsSection.selection(stored: "gone", defaultVoiceID: "en-GB-Harry", voices: voices,
                                                      cloudUnavailable: false), "en-GB-Harry", "a voice the journal dropped")
        XCTAssertEqual(VoiceSettingsSection.selection(stored: VoiceSettings.onDevice, defaultVoiceID: "en-GB-Harry",
                                                      voices: voices, cloudUnavailable: false), VoiceSettings.onDevice)
        XCTAssertEqual(VoiceSettingsSection.selection(stored: "en-GB-Emily", defaultVoiceID: nil, voices: voices,
                                                      cloudUnavailable: true), VoiceSettings.onDevice, "no cloud voice")
        XCTAssertEqual(VoiceSettingsSection.rateLabel(1.2), "1.2×")
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`
Run: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath build/ios-test -only-testing:MatronTests/VoiceSettingsTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: build FAILS — `cannot find 'VoiceSettingsSection' in scope`.

- [ ] **Step 4: Add the dependency accessor**

In `Matron/App/AppDependencies.swift`, add `import MatronVoice` after `import MatronViewModels`, and directly before `func pushService(for session: UserSession) -> any PushService {`:

```swift
    // MARK: Voice mode (spec 2026-10-03)

    /// The journal's text-to-speech routes. The session's one `JournalAPI`
    /// conforms; the protocol is what `SpeechPlayer` tests against.
    func speechSynthesiser(for session: UserSession) -> any SpeechSynthesising {
        core(for: session).api
    }

```

- [ ] **Step 5: Put the settings in the shell's environment**

In `Matron/App/AppShellView.swift`, add `import MatronVoice` after `import MatronPush`; after `@State private var voiceNotes = VoiceNoteSession()`:

```swift
    /// Voice mode's settings (spec 2026-10-03 §6): one object for the
    /// settings screen and for voice mode itself.
    @State private var voiceSettings = VoiceSettings()
```

and after `.environment(voiceNotes)`:

```swift
        .environment(voiceSettings)
```

- [ ] **Step 6: Create the section**

Create `Matron/Features/Voice/VoiceSettingsSection.swift`:

```swift
import SwiftUI
import MatronJournal
import MatronVoice

/// Settings ▸ Voice mode (spec 2026-10-03 §6): the voice, its speed,
/// whether talking over the agent interrupts it, and whether "more" is
/// offered after a reply.
struct VoiceSettingsSection: View {
    @Bindable var settings: VoiceSettings
    /// Asks the journal which voices it has. `nil` (previews, tests) keeps
    /// the built-in pair.
    var synth: (any SpeechSynthesising)? = nil

    @State private var voices: [TTSVoice] = VoiceSettings.builtInVoices
    @State private var defaultVoiceID: String?
    @State private var cloudUnavailable = false

    /// The picker's selection: the user's choice, else the journal's
    /// default, else the first voice on offer. On-device when the journal
    /// has no cloud voice.
    static func selection(stored: String?, defaultVoiceID: String?, voices: [TTSVoice], cloudUnavailable: Bool) -> String {
        if cloudUnavailable || stored == VoiceSettings.onDevice { return VoiceSettings.onDevice }
        if let stored, voices.contains(where: { $0.id == stored }) { return stored }
        return defaultVoiceID ?? voices.first?.id ?? VoiceSettings.onDevice
    }

    static func rateLabel(_ rate: Double) -> String {
        String(format: "%.1f×", rate)
    }

    private var selection: Binding<String> {
        Binding(
            get: { Self.selection(stored: settings.voice, defaultVoiceID: defaultVoiceID, voices: voices,
                                  cloudUnavailable: cloudUnavailable) },
            set: { settings.voice = $0 })
    }

    var body: some View {
        Section {
            Picker("Voice", selection: selection) {
                if !cloudUnavailable {
                    ForEach(voices) { voice in Text(voice.name).tag(voice.id) }
                }
                Text("On-device").tag(VoiceSettings.onDevice)
            }
            VStack(alignment: .leading) {
                Text("Speaking rate: \(Self.rateLabel(settings.rate))")
                Slider(value: $settings.rate, in: VoiceSettings.rateRange, step: 0.1)
                    .accessibilityLabel("Speaking rate")
            }
            Toggle("Talk over the agent", isOn: $settings.talkOver)
            Toggle("Offer \u{201C}more\u{201D} after a reply", isOn: $settings.offerMore)
        } header: {
            // A long press shows or hides "Speak a reply" in a
            // conversation's Session sheet (diagnostics).
            Text(settings.debugTools ? "Voice mode (debug tools on)" : "Voice mode")
                .onLongPressGesture { settings.debugTools.toggle() }
        } footer: {
            Text(cloudUnavailable
                 ? "This journal has no cloud voice, so the on-device voice is used. Talking over the agent stops it; anyone's voice does, a passenger's included."
                 : "Talking over the agent stops it; anyone's voice does, a passenger's included. A tap always works.")
        }
        .task {
            guard let synth else { return }
            do {
                let answer = try await synth.ttsVoices()
                if !answer.voices.isEmpty { voices = answer.voices }
                defaultVoiceID = answer.defaultVoiceID
            } catch TTSError.unavailable {
                cloudUnavailable = true
            } catch {
                // Busy or offline: keep the built-in pair and ask next time.
            }
        }
    }
}
```

- [ ] **Step 7: Show it in Settings**

In `Matron/Features/Settings/DeviceSettingsView.swift`, add `import MatronVoice` after `import MatronJournal`; after `@Environment(\.appLockController) private var appLock`:

```swift
    /// Injected by `AppShellView`; nil in previews/tests hides the section.
    @Environment(VoiceSettings.self) private var voiceSettings: VoiceSettings?
```

and directly before the `if let deps {` that wraps `Section("Storage")`:

```swift
            if let voiceSettings {
                VoiceSettingsSection(settings: voiceSettings, synth: deps?.speechSynthesiser(for: session))
            }
```

(The settings sheet is presented from `ChatListView` inside the shell, so it inherits the shell's environment.)

- [ ] **Step 8: Run to verify it passes**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`, then the Step 3 test command.
Expected: `Executed 1 test, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 9: Look at it**

Install on the iPhone 17 simulator (`xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO`, then `xcrun simctl install booted build/ios/Build/Products/Debug-iphonesimulator/Matron.app` and launch). Chats ▸ ⋯ ▸ Settings: a "Voice mode" section sits above Storage with Voice (Harry, Emily, On-device), a "Speaking rate: 1.0×" slider, "Talk over the agent" on, "Offer “more” after a reply" on. Change each, close and reopen Settings: every value has stuck. Against a journal without `/tts` the picker shows On-device only and the footer says the journal has no cloud voice.

- [ ] **Step 10: Commit**

```bash
git add project.yml Matron/App/AppDependencies.swift Matron/App/AppShellView.swift \
        Matron/Features/Settings/DeviceSettingsView.swift Matron/Features/Voice/VoiceSettingsSection.swift \
        MatronTests/VoiceSettingsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "ios: Settings gains a Voice mode section" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: The hidden "Speak a reply" list; PR 2

**Files:**
- Create: `Matron/Features/Voice/VoiceDebugView.swift`
- Modify: `Matron/Features/Chat/SessionStatusSheet.swift` (imports at line 5; line 49; the `ForEach(settingRows)` at line 152; before `settingLink` at line 159)
- Test: `MatronTests/VoiceSettingsTests.swift`

**Interfaces:**
- Consumes: `JournalStore.lastAgentReply`, `summaryEntries(convoID:)` (Tasks 1–2), `SpeechCleaner.fallbackShort` (Task 3), `SpeechPlayer`, `PlayerClipOutput`, `SynthesizerLocalVoice` (Task 12), `VoiceSettings.debugTools` (Task 11).
- Produces: `VoiceDebugView(convoID:store:synth:settings:)` with `static func lines(convoID:store:) -> [Line]`; a "Speak a reply (debug)" row in the Session sheet, shown when `MatronDebug.enabled` or `voiceSettings.debugTools` (the latter is switched by a long press on the "Voice mode" settings title, so it works on a TestFlight build).

- [ ] **Step 1: Write the failing test**

In `MatronTests/VoiceSettingsTests.swift`, insert before the class's closing brace:

```swift

    func test_debugLinesAreTheCleanerLineThenEachTurnsSpokenLines() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        func event(_ seq: Int64, type: String, _ payload: [String: Any]) -> JournalEvent {
            JournalEvent(seq: seq, convoID: "c1", ts: Date(timeIntervalSince1970: Double(seq)), sender: "agent:bev", type: type,
                         payloadData: try! JSONSerialization.data(withJSONObject: payload))
        }
        _ = try store.applyJournalBatch([
            event(1, type: "text", ["body": "The deploy finished. All green. Nothing else.", "message_ref": "m1"]),
            event(2, type: "summary", ["toc": "Deploy", "spoken": "It is deployed.", "spoken_more": "Every test passed.", "spoken_ref": "m1"]),
            event(3, type: "summary", ["toc": "Old bridge"]),
        ])
        let lines = VoiceDebugView.lines(convoID: "c1", store: store)
        XCTAssertEqual(lines.map(\.text), ["The deploy finished. All green.", "It is deployed.", "Every test passed."])
        XCTAssertEqual(lines.map(\.title), ["Last reply, through the cleaner", "Deploy", "Deploy (more)"])
    }
```

- [ ] **Step 2: Run to verify it fails**

Run the Task 13 Step 3 test command.
Expected: build FAILS — `cannot find 'VoiceDebugView' in scope`.

- [ ] **Step 3: Create the list**

Create `Matron/Features/Voice/VoiceDebugView.swift`:

```swift
import AVFoundation
import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronVoice

/// Hidden (Session sheet ▸ "Speak a reply", shown under `MatronDebug` or
/// the hidden switch in Settings ▸ Voice mode): says any
/// turn's spoken line, so the voices can be judged before voice mode can
/// listen. Plays straight to the speaker with a `.playback` session; voice
/// mode itself plays through the capture engine.
struct VoiceDebugView: View {
    let convoID: String
    let store: JournalStore
    let synth: any SpeechSynthesising
    let settings: VoiceSettings

    struct Line: Identifiable, Equatable {
        let id: String
        let title: String
        let text: String
    }

    @State private var lines: [Line] = []
    @State private var player: SpeechPlayer?
    @State private var lastSource: String?

    /// Newest first: the last reply through the cleaner, then every turn's
    /// spoken line and its longer version.
    static func lines(convoID: String, store: JournalStore) -> [Line] {
        var out: [Line] = []
        if let reply = try? store.lastAgentReply(convoID: convoID) {
            let short = SpeechCleaner.fallbackShort(reply.body)
            if !short.isEmpty { out.append(Line(id: "cleaner", title: "Last reply, through the cleaner", text: short)) }
        }
        for entry in ((try? store.summaryEntries(convoID: convoID)) ?? []).prefix(30) {
            if let spoken = entry.spoken {
                out.append(Line(id: "s\(entry.seq)", title: entry.toc, text: spoken))
            }
            if let more = entry.spokenMore {
                out.append(Line(id: "m\(entry.seq)", title: "\(entry.toc) (more)", text: more))
            }
        }
        return out
    }

    var body: some View {
        List {
            if let lastSource {
                Section { Text("Last spoken by: \(lastSource)").font(.footnote) }
            }
            Section("Tap a line to hear it") {
                if lines.isEmpty {
                    Text("No spoken lines in this conversation yet.").foregroundStyle(.secondary)
                }
                ForEach(lines) { line in
                    Button { speak(line.text) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.title).font(.footnote).foregroundStyle(.secondary)
                            Text(line.text)
                        }
                    }
                    .foregroundStyle(Color.primary)
                }
            }
            Section("Sounds") {
                ForEach(VoiceModeEngine.Earcon.allCases, id: \.self) { earcon in
                    Button(earcon.rawValue) {
                        activate()
                        player?.play(earcon)
                    }
                }
            }
        }
        .navigationTitle("Speak a reply")
        .task {
            lines = Self.lines(convoID: convoID, store: store)
            let made = SpeechPlayer(synth: synth, cache: .standard(), output: PlayerClipOutput(),
                                    local: SynthesizerLocalVoice(), settings: settings)
            player = made
            await made.refreshVoices()
        }
        .onDisappear {
            player?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func activate() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func speak(_ text: String) {
        guard let player else { return }
        activate()
        Task {
            let source = await player.speak(text)
            lastSource = source.rawValue
        }
    }
}
```

- [ ] **Step 4: Link it from the Session sheet**

In `Matron/Features/Chat/SessionStatusSheet.swift`, add `import MatronVoice` after `import MatronDesignSystem`; after `@Environment(\.dismiss) private var dismiss`:

```swift
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @Environment(VoiceSettings.self) private var voiceSettings: VoiceSettings?
```

in `sheetStack`, between the `ForEach(settingRows) { … }` and `sheetContent`:

```swift
            voiceDebugLink
```

and directly before the doc comment `/// A Model / Effort row: its current value on the trailing edge, and`:

```swift
    /// Diagnostics only: hear any turn's spoken line. Shown under
    /// `MatronDebug`, or once the hidden switch in Settings ▸ Voice mode is
    /// on (a long press on the section's title).
    @ViewBuilder private var voiceDebugLink: some View {
        if let deps, let session, let voiceSettings, MatronDebug.enabled || voiceSettings.debugTools {
            NavigationLink {
                VoiceDebugView(convoID: viewModel.roomID, store: deps.journalStore(for: session),
                               synth: deps.speechSynthesiser(for: session), settings: voiceSettings)
            } label: {
                Label("Speak a reply (debug)", systemImage: "waveform")
            }
            .accessibilityIdentifier("session-voice-debug-row")
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

```

- [ ] **Step 5: Run to verify it passes**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`, then the Task 13 Step 3 test command.
Expected: `Executed 2 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 6: Judge the voices on a phone**

This is the listening test the spec asks for before anything else is built (§2, "Risk"). Build to a real iPhone (or upload with `scripts/testflight-upload.sh`). Settings ▸ long-press the "Voice mode" title: it reads "Voice mode (debug tools on)". Open a conversation with a few finished turns, ⓘ ▸ "Speak a reply (debug)". Tap a line with Voice set to Harry, then Emily, then On-device, at rates 0.8×, 1.0× and 1.3×. "Last spoken by" reads `cloud` (a reply is never cached on the phone, so it does not read `cache` here). In flight mode the same line is spoken at once in the on-device voice and reads `onDevice`. Play the three sounds. Write down which voice Dan prefers and whether the on-device fallback is acceptable; if neither cloud voice is, stop and raise it (the journal can swap the vendor without an app change).

- [ ] **Step 7: Run every suite**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --skip test_fileLog 2>&1 | tee /tmp/shared-test.log | grep -E "Test Suite '.*\.xctest' (passed|failed)|Executed [0-9]+ tests"`
Expected: as Task 9 Step 1, with `VoiceTests.xctest` now at `Executed 106 tests, with 0 failures`.
Run the iOS suite: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath build/ios-test -only-testing:MatronTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: an `Executed N tests` line with N = main's count plus 2, and no failure other than `TextMessageCellTests.test_pillsRow_staysPut_whenTheCellSitsInASafeArea`.

- [ ] **Step 8: Commit, push, open PR 2**

```bash
git add Matron/Features/Voice/VoiceDebugView.swift Matron/Features/Chat/SessionStatusSheet.swift MatronTests/VoiceSettingsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "ios: a hidden list that speaks any turn's spoken line" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push -u origin feat/voice-speaking
gh pr create --base feat/voice-data --title "Voice mode (2/4): speaking" --body "$(cat <<'BODY'
Speaking for spec 2026-10-03: JournalAPI text-to-speech routes, SpeechPlayer (the journal's clip; on any failure or no audio in two seconds, the same text in the on-device voice; fixed phrases cached on the phone), synthesised earcons, and Settings ▸ Voice mode (voice, speaking rate, Talk over the agent, offer "more"). A hidden list (long-press the settings title, then a chat's ⓘ ▸ Speak a reply) says any turn's spoken line so the voices can be judged before the app can listen.

Plan: docs/superpowers/plans/2026-10-03-voice-mode-phase1-apple.md (Tasks 10–14)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

# PR 3 — listening and the loop

Branch: `git worktree add ../matron-apple-voice-3 -b feat/voice-loop feat/voice-speaking`.

### Task 15: SPIKE — the device audio layer, and proof the app's own voice does not trigger talking-over

This is the spec's phase 0 (§13): it decides whether talking over the agent ships on by default. It needs a real iPhone on iOS 26 or later, at full loudspeaker volume and with AirPods. It writes the production audio layer (kept) and one throwaway screen (deleted in Task 21).

**Files:**
- Create: `MatronShared/Sources/Voice/VoiceModeSeams.swift`, `VoiceAudioEngine.swift`, `VoiceAudioSession.swift`, `VoiceCapture.swift`
- Create (throwaway): `Matron/Features/Voice/VoiceSpikeView.swift`
- Modify: `project.yml` (after `NSPhotoLibraryUsageDescription` at line 113), `Matron/App/Info.plist` (after its `NSPhotoLibraryUsageDescription` string), `Matron/Features/Voice/VoiceDebugView.swift`
- Test: `MatronShared/Tests/VoiceTests/VoiceCaptureTests.swift` (new)

**Interfaces:**
- Produces (MatronVoice), the engine's edges:
  - `enum VoiceCaptureEvent { speechStarted, speechEnded, words(String), failed }`
  - `@MainActor protocol VoiceCapturing { var events: AsyncStream<VoiceCaptureEvent>; func start(_ mode:) async throws; func promote(); func stop(keep:) async -> URL? }`
  - `@MainActor protocol VoiceAudioControlling { var events: AsyncStream<VoiceModeEngine.Event>; var routeName: String; func activate() throws; func release() }`
  - `@MainActor protocol SpeechPlaying` (+ `extension SpeechPlayer: SpeechPlaying`), `protocol VoiceSending`, `@MainActor protocol VoiceFeeding` — used from Task 16 on.
- Produces (MatronVoice), the device layer:
  - `VoiceAudioEngine: ClipOutput` — one `AVAudioEngine`, voice processing on the input node, a player node for clips and one for earcons; `start()`, `stopEngine()`, `inputFormat`, internal `input: InputSink`.
  - `EngineLocalVoice: LocalVoice` — `AVSpeechSynthesizer.write` rendered into the same engine.
  - `VoiceAudioSession: VoiceAudioControlling` — `.playAndRecord` / `.voiceChat` / `[.defaultToSpeaker, .allowBluetoothHFP]`, interruptions and route changes as engine events (the mapping `VoiceRecorder.observeSystemInterruptions` uses, `VoiceRecorder.swift:292-319`).
  - `@available(iOS 26, macOS 26, *) VoiceCapture: VoiceCapturing` — the tap written to an AAC `.m4a` (`VoiceRecorder.makeSystemRecorder`'s settings, `VoiceRecorder.swift:321-330`, at the microphone's own sample rate), a rolling half-second `PreRollBuffer`, and `SpeechListener` (`SpeechAnalyzer` with `SpeechDetector` + `SpeechTranscriber`).

**Apple API facts this code rests on, and where each was checked:**
- `SpeechAnalyzer(modules:options:)`, `start(inputSequence:)`, `bestAvailableAudioFormat(compatibleWith:considering:)`, `cancelAndFinishNow()`; `SpeechDetector(detectionOptions:reportResults:)` with `results` of `Result { speechDetected: Bool }`; `SpeechTranscriber(locale:preset:)` with `.progressiveTranscription`, `isAvailable`, `supportedLocale(equivalentTo:)`, `results` of `Result { text: AttributedString }` and `isFinal`; `AnalyzerInput(buffer:)`; `AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`. All `@available(anyAppleOS 26, *)`. Verified in the SDK: `grep -n "class SpeechDetector\|class SpeechTranscriber\|actor SpeechAnalyzer" "$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface"`. Documentation: https://developer.apple.com/documentation/speech/speechanalyzer and https://developer.apple.com/documentation/speech/speechdetector ("This module only functions in conjunction with a SpeechTranscriber or DictationTranscriber module").
- `AnalyzerInputConverter` and `CaptureInputSequenceProvider` are iOS **27** only (same interface file), so the conversion to the analyzer's format is done by hand with `AVAudioConverter`.
- Authorisation: Apple's "Asking permission to use speech recognition" says the authorisation request "only applies to speech recognition using SFSpeechRecognizer. SpeechAnalyzer transcriber modules don't send audio data of the user's voice to Apple's servers", and also that without `NSSpeechRecognitionUsageDescription` "your app will crash when it attempts to request authorization or use the APIs of the Speech framework" (https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition). So this task adds the usage string and requests nothing but the microphone. **Step 9 checks on the phone that no speech-recognition prompt appears and nothing throws for want of one.**
- `AVAudioIONode.setVoiceProcessingEnabled(_:)`: "Voice processing can only be be enabled or disabled when the engine is in a stopped state", "Enabling this mode on either of the IO nodes automatically enables it on the other IO node" (`AVFAudio.framework/Headers/AVAudioIONode.h`; https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)).
- `AVAudioSession.CategoryOptions.allowBluetoothHFP` (the old `.allowBluetooth` is deprecated in its favour, `AVAudioSessionTypes.h`); `AVAudioFile.close()` is iOS 18 / macOS 15.
- NOT verifiable without a phone, which is what Step 9 is for: that a player node may be reconnected in a new format while the engine runs (`VoiceAudioEngine.play`), that `AVSpeechSynthesizer.write` buffers schedule cleanly after `standardised`, how `.voiceChat` mode sounds on the loudspeaker, how long the recogniser takes to start, and whether echo cancellation holds at full volume.

- [ ] **Step 1: Write the failing tests (the parts that need no microphone)**

Create `MatronShared/Tests/VoiceTests/VoiceCaptureTests.swift`:

```swift
import AVFoundation
import XCTest
@testable import MatronVoice

/// The parts of capture that need no microphone.
final class VoiceCaptureTests: XCTestCase {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// A buffer of `seconds` at 16 kHz, every sample set to `value`.
    func buffer(_ seconds: Double, value: Float = 0) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = value }
        return buffer
    }

    func testPreRollKeepsTheLastHalfSecond() {
        var preRoll = PreRollBuffer(seconds: 0.5)
        XCTAssertEqual(preRoll.duration, 0)
        for index in 0..<10 { preRoll.append(buffer(0.1, value: Float(index))) }
        XCTAssertEqual(preRoll.duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(preRoll.buffers.map { $0.floatChannelData![0][0] }, [5, 6, 7, 8, 9], "the newest five")
        let drained = preRoll.drain()
        XCTAssertEqual(drained.count, 5)
        XCTAssertEqual(preRoll.duration, 0)
    }

    /// One buffer longer than the window is kept whole rather than cut.
    func testPreRollNeverDropsItsOnlyBuffer() {
        var preRoll = PreRollBuffer(seconds: 0.5)
        preRoll.append(buffer(2))
        XCTAssertEqual(preRoll.buffers.count, 1)
        preRoll.append(buffer(0.6))
        XCTAssertEqual(preRoll.buffers.count, 1, "the newer buffer covers the window by itself")
        XCTAssertEqual(preRoll.duration, 0.6, accuracy: 0.001)
    }

    func testCopyIsIndependentOfItsSource() throws {
        let source = buffer(0.1, value: 0.25)
        let copy = try XCTUnwrap(copyOf(source))
        source.floatChannelData![0][0] = 0.9
        XCTAssertEqual(copy.frameLength, source.frameLength)
        XCTAssertEqual(copy.floatChannelData![0][0], 0.25)
    }

    func testWordsWhileRecordingAddUpAcrossSegments() {
        var words = WordsAccumulator()
        words.reset(recording: true)
        XCTAssertEqual(words.add("merge", isFinal: false), "merge")
        XCTAssertEqual(words.add("merge it", isFinal: false), "merge it")
        XCTAssertEqual(words.add("Merge it.", isFinal: true), "Merge it.")
        XCTAssertEqual(words.add("when the", isFinal: false), "Merge it. when the")
        XCTAssertEqual(words.add("When the tests pass.", isFinal: true), "Merge it. When the tests pass.")
    }

    /// Under a clip only the segment in progress counts; when talking over
    /// turns into an utterance, that segment is its start.
    func testWordsWhileMonitoringAreOnlyTheSegmentInProgress() {
        var words = WordsAccumulator()
        words.reset(recording: false)
        XCTAssertEqual(words.add("The deploy finished.", isFinal: true), "The deploy finished.")
        XCTAssertEqual(words.add("actually", isFinal: false), "actually")
        words.promote()
        XCTAssertEqual(words.add("actually wait", isFinal: false), "actually wait")
        XCTAssertEqual(words.add("Actually wait.", isFinal: true), "Actually wait.")
        XCTAssertEqual(words.add("for the tests", isFinal: false), "Actually wait. for the tests")
        words.reset(recording: false)
        XCTAssertEqual(words.text, "")
    }

    @MainActor
    func testEncodedClipsOpenAsAudioFiles() throws {
        let file = try VoiceAudioEngine.audioFile(EarconSynth.wav(.sent))
        XCTAssertEqual(file.processingFormat.sampleRate, 24_000)
        XCTAssertEqual(Double(file.length) / 24_000, EarconSynth.duration(.sent), accuracy: 0.001)
        XCTAssertThrowsError(try VoiceAudioEngine.audioFile(Data("not audio".utf8)))
    }

    @MainActor
    func testSynthesizerBuffersAreMadeEngineReady() throws {
        let integer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: true)!
        let source = AVAudioPCMBuffer(pcmFormat: integer, frameCapacity: 100)!
        source.frameLength = 100
        let converted = try XCTUnwrap(EngineLocalVoice.standardised(source))
        XCTAssertEqual(converted.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(converted.format.isInterleaved)
        XCTAssertEqual(converted.frameLength, 100)
        let float = buffer(0.1)
        XCTAssertTrue(EngineLocalVoice.standardised(float) === float, "already in the engine's format")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceCaptureTests'`
Expected: build FAILS — `cannot find 'PreRollBuffer' in scope`.

- [ ] **Step 3: Declare the engine's edges**

Create `MatronShared/Sources/Voice/VoiceModeSeams.swift`:

```swift
import Foundation

// The engine's edges (spec 2026-10-03 §3: "the audio, network and clock
// behind protocols"). A device supplies the real ones; tests supply fakes.

/// What the microphone side reports to the engine.
public enum VoiceCaptureEvent: Equatable, Sendable {
    case speechStarted
    case speechEnded
    /// The recogniser's words for the utterance so far.
    case words(String)
    case failed
}

/// The microphone: capture to a voice-note file, with the on-device
/// recogniser running alongside (`VoiceCapture` on a device).
@MainActor
public protocol VoiceCapturing: AnyObject {
    var events: AsyncStream<VoiceCaptureEvent> { get }
    func start(_ mode: VoiceModeEngine.CaptureMode) async throws
    /// Monitor becomes record, keeping the rolling half second.
    func promote()
    /// Closes the microphone. `keep`: the recorded file, when there is one.
    func stop(keep: Bool) async -> URL?
}

/// The audio session and engine: held only while listening or speaking.
@MainActor
public protocol VoiceAudioControlling: AnyObject {
    var events: AsyncStream<VoiceModeEngine.Event> { get }
    /// The current output route's name, e.g. "Speaker".
    var routeName: String { get }
    func activate() throws
    func release()
}

/// The voice (`SpeechPlayer`).
@MainActor
public protocol SpeechPlaying: AnyObject {
    @discardableResult func speak(_ text: String) async -> SpeechPlayer.Source
    func stop()
    func setDucked(_ ducked: Bool)
    func play(_ earcon: VoiceModeEngine.Earcon)
}

extension SpeechPlayer: SpeechPlaying {}

/// The network side (`JournalVoiceSender`).
public protocol VoiceSending: Sendable {
    /// `POST /media`; returns the blob ref.
    func upload(_ audio: Data) async throws -> String
    /// The journal's words for an uploaded note, or `nil`.
    func transcript(blobRef: String, waitSeconds: Int) async -> String?
    func sendVoiceNote(blobRef: String, size: Int, to target: VoiceModeEngine.SendTarget) async throws
    func sendItemAction(itemID: String, label: String) async
    func sendPromptReply(convoID: String, seq: Int64, choice: String?, text: String?) async throws
}

/// What happens in the conversations voice mode cares about
/// (`JournalVoiceFeed`).
@MainActor
public protocol VoiceFeeding: AnyObject {
    var events: AsyncStream<VoiceModeEngine.Event> { get }
    func watch(convoID: String)
    func stop()
}
```

- [ ] **Step 4: The audio engine**

Create `MatronShared/Sources/Voice/VoiceAudioEngine.swift`:

```swift
import AVFoundation
import Foundation

/// Hands the microphone tap's buffers to whoever is listening. The tap
/// runs on an audio thread; the consumer is swapped from the main actor.
final class InputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func set(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(buffer)
    }
}

/// One `AVAudioEngine` for both directions (spec 2026-10-03 §3,
/// "Listening"): the microphone with Apple's voice processing switched on,
/// and the agent's clips played through the same engine, which is what
/// lets the echo canceller take the agent's voice back out of the
/// microphone so it can stay open while the agent speaks.
///
/// `setVoiceProcessingEnabled(_:)` may only be called while the engine is
/// stopped, and switching it on the input node switches the output node
/// too (AVFAudio `AVAudioIONode.h`;
/// https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)).
@MainActor
public final class VoiceAudioEngine: ClipOutput {
    private let engine = AVAudioEngine()
    private let voice = AVAudioPlayerNode()
    private let effects = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    let input = InputSink()
    private let voiceProcessing: Bool
    private var configured = false
    /// Bumped by every play and stop: a completion from a clip that was
    /// stopped or replaced is ignored.
    private var token = 0
    private var continuation: CheckedContinuation<Void, Error>?
    /// The microphone's format once the graph is built.
    public private(set) var inputFormat: AVAudioFormat?

    /// - Parameter voiceProcessing: `false` only for the spike's
    ///   comparison run.
    public init(voiceProcessing: Bool = true) {
        self.voiceProcessing = voiceProcessing
    }

    public var isRunning: Bool { engine.isRunning }

    private func configure() throws {
        guard !configured else { return }
        if voiceProcessing { try engine.inputNode.setVoiceProcessingEnabled(true) }
        engine.attach(voice)
        engine.attach(pitch)
        engine.attach(effects)
        engine.connect(voice, to: pitch, format: nil)
        engine.connect(pitch, to: engine.mainMixerNode, format: nil)
        engine.connect(effects, to: engine.mainMixerNode, format: nil)
        let format = engine.inputNode.outputFormat(forBus: 0)
        inputFormat = format
        let sink = input
        engine.inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            sink.push(buffer)
        }
        configured = true
    }

    /// Starts the engine (building the graph first). The audio session
    /// must already be active.
    public func start() throws {
        try configure()
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    public func stopEngine() {
        stop()
        effects.stop()
        if engine.isRunning { engine.stop() }
    }

    // MARK: ClipOutput

    public func play(_ audio: Data, rate: Double) async throws {
        let file = try Self.audioFile(audio)
        try await play(format: file.processingFormat, rate: rate) { node, done in
            node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in done() }
        }
    }

    /// Plays PCM buffers end to end (the on-device voice).
    func play(buffers: [AVAudioPCMBuffer], rate: Double) async throws {
        guard let format = buffers.first?.format else { return }
        try await play(format: format, rate: rate) { node, done in
            for (index, buffer) in buffers.enumerated() {
                if index == buffers.count - 1 {
                    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
                } else {
                    node.scheduleBuffer(buffer)
                }
            }
        }
    }

    private func play(format: AVAudioFormat, rate: Double,
                      schedule: (AVAudioPlayerNode, @escaping @Sendable () -> Void) -> Void) async throws {
        stop()
        try start()
        token += 1
        let mine = token
        // A player node does not convert what is scheduled on it, so it is
        // reconnected in each clip's own format; the mixer converts.
        engine.disconnectNodeOutput(voice)
        engine.disconnectNodeOutput(pitch)
        engine.connect(voice, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        pitch.rate = Float(rate)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            schedule(voice) { [weak self] in
                Task { @MainActor in self?.finished(mine) }
            }
            voice.play()
        }
    }

    private func finished(_ finishedToken: Int) {
        guard finishedToken == token else { return }
        continuation?.resume()
        continuation = nil
    }

    public func playEffect(_ audio: Data) {
        guard let file = try? Self.audioFile(audio), (try? start()) != nil else { return }
        engine.disconnectNodeOutput(effects)
        engine.connect(effects, to: engine.mainMixerNode, format: file.processingFormat)
        effects.scheduleFile(file, at: nil, completionHandler: nil)
        effects.play()
    }

    public func stop() {
        token += 1
        voice.stop()
        continuation?.resume()
        continuation = nil
    }

    public func setVolume(_ volume: Float) {
        voice.volume = volume
    }

    /// Encoded bytes as a readable audio file. `AVAudioFile` reads from a
    /// URL only, so the bytes go through a temporary file, removed once it
    /// is open (the open handle keeps it readable).
    static func audioFile(_ audio: Data) throws -> AVAudioFile {
        let isWave = audio.prefix(4) == Data("RIFF".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clip-\(UUID().uuidString).\(isWave ? "wav" : "mp3")")
        try audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try AVAudioFile(forReading: url)
    }
}

/// The on-device voice played through the capture engine, so it too is
/// echo-cancelled. `AVSpeechSynthesizer.write` renders the line to
/// buffers; they are converted to the engine's float format and scheduled.
@MainActor
public final class EngineLocalVoice: LocalVoice {
    private let audio: VoiceAudioEngine
    private let synthesizer = AVSpeechSynthesizer()
    private var generation = 0

    public init(audio: VoiceAudioEngine) {
        self.audio = audio
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [AVAudioPCMBuffer] = []
        private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?
        init(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) { self.continuation = continuation }
        /// The synthesizer ends a line with an empty buffer.
        func take(_ buffer: AVAudioBuffer) {
            lock.lock()
            defer { lock.unlock() }
            if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                buffers.append(pcm)
            } else {
                continuation?.resume(returning: buffers)
                continuation = nil
            }
        }
    }

    public func speak(_ text: String, rate: Double) async {
        generation += 1
        let mine = generation
        let utterance = SynthesizerLocalVoice.utterance(text, rate: rate, volume: 1)
        let rendered: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            let collector = Collector(continuation)
            synthesizer.write(utterance) { collector.take($0) }
        }
        guard mine == generation else { return }
        let buffers = rendered.compactMap(Self.standardised)
        try? await audio.play(buffers: buffers, rate: 1)
    }

    public func stop() {
        generation += 1
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        audio.stop()
    }

    public func setVolume(_ volume: Float) {
        audio.setVolume(volume)
    }

    /// The synthesizer's buffers may be 16-bit integers; the engine takes
    /// deinterleaved floats.
    static func standardised(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate,
                                         channels: buffer.format.channelCount) else { return nil }
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
        do {
            try converter.convert(to: out, from: buffer)
            return out
        } catch {
            return nil
        }
    }
}
```

- [ ] **Step 5: The audio session**

Create `MatronShared/Sources/Voice/VoiceAudioSession.swift`:

```swift
import AVFoundation
import Foundation
import os

/// Voice mode's hold on the device's audio (spec 2026-10-03 §3, "Audio
/// session"): `.playAndRecord` with voice processing, active only while
/// the engine is listening or speaking, and given back (telling other apps)
/// when it waits, so music or the radio returns. A call or Siri pauses the
/// engine, as `VoiceRecorder` does for a voice note.
@MainActor
public final class VoiceAudioSession: VoiceAudioControlling {
    public let events: AsyncStream<VoiceModeEngine.Event>
    private let continuation: AsyncStream<VoiceModeEngine.Event>.Continuation
    private let engine: VoiceAudioEngine
    private var observers: [NSObjectProtocol] = []
    private var active = false

    private static let logger = Logger(subsystem: "chat.matron", category: "voice-session")

    public init(engine: VoiceAudioEngine) {
        self.engine = engine
        (events, continuation) = AsyncStream.makeStream(of: VoiceModeEngine.Event.self)
        observe()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    public var routeName: String {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.isEmpty ? "none" : outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        #else
        return "Mac"
        #endif
    }

    public func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // The loudspeaker, not the earpiece, when nothing else is
        // connected; AirPods and a car's hands-free when they are.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        Self.logger.info("active: route=\(self.routeName, privacy: .public) sampleRate=\(session.sampleRate, format: .fixed(precision: 0))")
        #endif
        active = true
        try engine.start()
    }

    public func release() {
        active = false
        engine.stopEngine()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func observe() {
        let center = NotificationCenter.default
        // A route change (AirPods in or out) reconfigures the engine,
        // which stops it: start it again while voice mode holds the audio.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                try? self.engine.start()
            }
        })
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.continuation.yield(.interruption(.began))
                case .ended: self?.continuation.yield(.interruption(.ended(shouldResume: shouldResume)))
                @unknown default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.continuation.yield(.routeChanged(self.routeName))
            }
        })
        #endif
    }
}
```

- [ ] **Step 6: Capture and the recogniser**

Create `MatronShared/Sources/Voice/VoiceCapture.swift`:

```swift
import AVFoundation
import Foundation
import Speech
import os

public enum VoiceCaptureError: Error, Equatable, Sendable {
    case microphoneDenied
    case noInput
    /// The on-device recogniser does not support the locale, or its model
    /// could not be installed.
    case recogniserUnavailable
}

/// The last half second of microphone audio, kept while the engine only
/// monitors, so that when talking over a clip turns into an utterance its
/// first word is not clipped (spec 2026-10-03 §3, "Talking over the agent").
struct PreRollBuffer {
    let seconds: TimeInterval
    private(set) var buffers: [AVAudioPCMBuffer] = []
    private var frames: AVAudioFrameCount = 0

    init(seconds: TimeInterval = 0.5) {
        self.seconds = seconds
    }

    var duration: TimeInterval {
        guard let rate = buffers.first?.format.sampleRate, rate > 0 else { return 0 }
        return Double(frames) / rate
    }

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        buffers.append(buffer)
        frames += buffer.frameLength
        let limit = AVAudioFrameCount(seconds * buffer.format.sampleRate)
        // Drop from the front while what is left still covers the window.
        while let first = buffers.first, buffers.count > 1, frames - first.frameLength >= limit {
            frames -= first.frameLength
            buffers.removeFirst()
        }
    }

    mutating func drain() -> [AVAudioPCMBuffer] {
        defer { removeAll() }
        return buffers
    }

    mutating func removeAll() {
        buffers = []
        frames = 0
    }
}

/// The recogniser's words for the utterance so far. While monitoring, only
/// the segment in progress counts (what was said under earlier parts of a
/// clip is not part of what he says now); while recording, finished
/// segments add up.
struct WordsAccumulator {
    var recording = false
    private var finished = ""
    private var current = ""

    var text: String {
        [finished, current].filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func add(_ segment: String, isFinal: Bool) -> String {
        let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal, recording {
            finished = [finished, segment].filter { !$0.isEmpty }.joined(separator: " ")
            current = ""
        } else {
            current = segment
        }
        return text
    }

    /// Monitoring becomes recording: what is being said now is its start.
    mutating func promote() {
        recording = true
        finished = ""
    }

    mutating func reset(recording: Bool) {
        self.recording = recording
        finished = ""
        current = ""
    }
}

/// A copy of `buffer`: the engine may reuse a tap's buffer after the
/// callback returns.
func copyOf(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
    copy.frameLength = buffer.frameLength
    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (from, to) in zip(source, destination) {
        guard let fromData = from.mData, let toData = to.mData else { continue }
        memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
    }
    return copy
}

/// Writes the microphone to a voice-note file. Called from the audio
/// thread (`append`) and the main actor (everything else).
@available(iOS 26, macOS 26, *)
final class CaptureCore: @unchecked Sendable {
    private let lock = NSLock()
    private var preRoll = PreRollBuffer()
    private var file: AVAudioFile?
    private var url: URL?
    private var format: AVAudioFormat?

    func begin(record: Bool, format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        self.format = format
        preRoll.removeAll()
        if record { openFile() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let file {
            try? file.write(from: buffer)
        } else if let copy = copyOf(buffer) {
            preRoll.append(copy)
        }
    }

    /// Starts the file with the half second already heard.
    func promote() {
        lock.lock()
        defer { lock.unlock() }
        guard file == nil else { return }
        openFile()
        for buffer in preRoll.drain() { try? file?.write(from: buffer) }
    }

    func finish(keep: Bool) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        file?.close()
        file = nil
        preRoll.removeAll()
        let finished = url
        url = nil
        guard let finished else { return nil }
        if keep { return finished }
        try? FileManager.default.removeItem(at: finished)
        return nil
    }

    /// The voice-note format `VoiceRecorder` writes (AAC in an `.m4a`,
    /// mono, 64 kbit/s), at the microphone's own sample rate: under voice
    /// processing that is whatever the echo canceller runs at, and
    /// resampling it to 44.1 kHz would add nothing.
    private func openFile() {
        guard let format else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat,
                                interleaved: format.isInterleaved)
        self.url = file == nil ? nil : url
    }
}

/// The on-device recogniser (spec §3, "Listening"): `SpeechDetector` says
/// whether someone is speaking, `SpeechTranscriber` gives rough words.
/// Its words are never sent to the agent: they decide end of speech,
/// talking over a clip, and commands.
///
/// API as declared in the iOS 26 SDK's `Speech.swiftinterface` and
/// described at https://developer.apple.com/documentation/speech/speechanalyzer
/// and https://developer.apple.com/documentation/speech/speechdetector
/// ("This module only functions in conjunction with a SpeechTranscriber or
/// DictationTranscriber module").
@available(iOS 26, macOS 26, *)
final class SpeechListener: @unchecked Sendable {
    let events: AsyncStream<VoiceCaptureEvent>
    private let eventsContinuation: AsyncStream<VoiceCaptureEvent>.Continuation
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let lock = NSLock()
    private var words = WordsAccumulator()
    private var tasks: [Task<Void, Never>] = []

    private static let logger = Logger(subsystem: "chat.matron", category: "voice-listener")

    static func make(locale: Locale, inputFormat: AVAudioFormat, recording: Bool) async throws -> SpeechListener {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceCaptureError.recogniserUnavailable
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        let modules: [any SpeechModule] = [detector, transcriber]
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        } catch {
            logger.error("assets: \(error.localizedDescription, privacy: .public)")
            throw VoiceCaptureError.recogniserUnavailable
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: inputFormat) else {
            throw VoiceCaptureError.recogniserUnavailable
        }
        // Lingering: the models stay loaded between one opening of the
        // microphone and the next.
        let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .userInitiated, modelRetention: .lingering))
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let listener = SpeechListener(analyzer: analyzer, input: input, analyzerFormat: format, inputFormat: inputFormat,
                                      recording: recording)
        try await analyzer.start(inputSequence: stream)
        listener.listen(detector: detector, transcriber: transcriber)
        return listener
    }

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, analyzerFormat: AVAudioFormat,
                 inputFormat: AVAudioFormat, recording: Bool) {
        self.analyzer = analyzer
        self.input = input
        self.analyzerFormat = analyzerFormat
        self.converter = inputFormat == analyzerFormat ? nil : AVAudioConverter(from: inputFormat, to: analyzerFormat)
        (events, eventsContinuation) = AsyncStream.makeStream(of: VoiceCaptureEvent.self)
        words.reset(recording: recording)
    }

    private func listen(detector: SpeechDetector, transcriber: SpeechTranscriber) {
        let continuation = eventsContinuation
        tasks.append(Task {
            var speaking = false
            do {
                for try await result in detector.results where result.speechDetected != speaking {
                    speaking = result.speechDetected
                    continuation.yield(speaking ? .speechStarted : .speechEnded)
                }
            } catch {
                if !(error is CancellationError) { continuation.yield(.failed) }
            }
        })
        tasks.append(Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    continuation.yield(.words(self.heard(String(result.text.characters), isFinal: result.isFinal)))
                }
            } catch {
                if !(error is CancellationError) { continuation.yield(.failed) }
            }
        })
    }

    private func heard(_ segment: String, isFinal: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        return words.add(segment, isFinal: isFinal)
    }

    func promote() {
        lock.lock()
        words.promote()
        lock.unlock()
    }

    /// From the audio thread: one microphone buffer for the recogniser.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            if let copy = copyOf(buffer) { input.yield(AnalyzerInput(buffer: copy)) }
            return
        }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        var handed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if handed {
                status.pointee = .noDataNow
                return nil
            }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() async {
        input.finish()
        for task in tasks { task.cancel() }
        await analyzer.cancelAndFinishNow()
        eventsContinuation.finish()
    }
}

/// The microphone for voice mode: the capture engine's input, written to a
/// voice-note file and fed to the on-device recogniser. `VoiceRecorder` is
/// unchanged and keeps serving ordinary voice notes.
@available(iOS 26, macOS 26, *)
@MainActor
public final class VoiceCapture: VoiceCapturing {
    public let events: AsyncStream<VoiceCaptureEvent>
    private let continuation: AsyncStream<VoiceCaptureEvent>.Continuation
    private let audio: VoiceAudioEngine
    private let locale: Locale
    private let core = CaptureCore()
    private var listener: SpeechListener?
    private var pump: Task<Void, Never>?

    /// Whether this device can run voice mode at all.
    public static var isSupported: Bool { SpeechTranscriber.isAvailable }

    public init(audio: VoiceAudioEngine, locale: Locale = Locale(identifier: "en-GB")) {
        self.audio = audio
        self.locale = locale
        (events, continuation) = AsyncStream.makeStream(of: VoiceCaptureEvent.self)
    }

    public func start(_ mode: VoiceModeEngine.CaptureMode) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw VoiceCaptureError.microphoneDenied }
        _ = await stop(keep: false)
        try audio.start()
        guard let format = audio.inputFormat, format.channelCount > 0 else { throw VoiceCaptureError.noInput }
        let listener = try await SpeechListener.make(locale: locale, inputFormat: format, recording: mode == .record)
        self.listener = listener
        core.begin(record: mode == .record, format: format)
        let core = self.core
        audio.input.set { buffer in
            core.append(buffer)
            listener.feed(buffer)
        }
        let continuation = self.continuation
        pump = Task {
            for await event in listener.events { continuation.yield(event) }
        }
    }

    public func promote() {
        core.promote()
        listener?.promote()
    }

    public func stop(keep: Bool) async -> URL? {
        audio.input.set(nil)
        let url = core.finish(keep: keep)
        pump?.cancel()
        pump = nil
        if let listener {
            self.listener = nil
            await listener.finish()
        }
        return url
    }
}
```

- [ ] **Step 7: Run to verify the unit tests pass, on both platforms' compilers**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceCaptureTests'`
Expected: `Executed 7 tests, with 0 failures`.
Run: `cd MatronShared && xcodebuild build -scheme MatronVoice -destination 'generic/platform=iOS Simulator' -derivedDataPath ../build/pkg-ios 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` (the `#if os(iOS)` halves compile).
Run: `grep -rn "^import" MatronShared/Sources/Voice | grep -E "import (UIKit|AppKit|SwiftUI)"`
Expected: no output.

- [ ] **Step 8: The usage string, and the throwaway screen**

In `project.yml`, after the `NSPhotoLibraryUsageDescription` line:

```yaml
        # Voice mode (spec 2026-10-03 §3) recognises speech on the device
        # with SpeechAnalyzer, which asks for no speech-recognition
        # authorisation of its own. Apple's permission page still says the
        # app "will crash when it attempts to ... use the APIs of the Speech
        # framework" without this key, so it ships.
        NSSpeechRecognitionUsageDescription: Voice mode listens for when you start and stop speaking, and for commands such as "more" and "stop". The words are recognised on your iPhone.
```

Run `xcodegen generate`, then `git checkout Matron/App/Info.plist` as always, and then add ONLY the new key to the checked-in plist by hand, directly after the `NSPhotoLibraryUsageDescription` string (tabs, as the file uses):

```xml
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Voice mode listens for when you start and stop speaking, and for commands such as "more" and "stop". The words are recognised on your iPhone.</string>
```

Check: `xcodegen generate && git diff --stat Matron/App/Info.plist` must now show a single insertion (the `audio` line) once the edit is staged or committed; `git checkout Matron/App/Info.plist` then restores the committed file with the key in it.

Create `Matron/Features/Voice/VoiceSpikeView.swift`:

```swift
import SwiftUI
import UIKit
import MatronJournal
import MatronVoice

/// THROWAWAY (deleted at the end of PR 3). The phase-0 spike of spec
/// 2026-10-03 §13: plays a minute of speech through the capture engine at
/// whatever volume the phone is set to, with the microphone open under it,
/// and logs what the detector and recogniser make of it. The question it
/// answers: does the app's own voice trigger talking-over?
@available(iOS 26, *)
@MainActor
@Observable
final class VoiceSpike {
    static let clip = """
    This is the talking over test. For the next minute I will keep speaking at a steady pace, and nobody in the room \
    should say anything. The app is listening to its own microphone while I talk. If echo cancellation is working, \
    it hears silence, and nothing below changes. If it is not, it hears me, and the counts below go up. \
    The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. \
    How razorback jumping frogs can level six piqued gymnasts. Sphinx of black quartz, judge my vow. \
    The five boxing wizards jump quickly. We promptly judged antique ivory buckles for the next prize. \
    That is the end of the pangrams. I am still talking, and you are still quiet. A few more seconds. \
    The last part of the test is yours. When I say now, say the word stop, once, in your normal voice. Now.
    """

    private(set) var log: [String] = []
    private(set) var running = false
    private(set) var speechWindows = 0
    private(set) var longWindows = 0
    private(set) var echoWordEvents = 0
    private(set) var otherWordEvents = 0
    private(set) var source = ""

    private var started = Date()
    private var windowStart: Date?

    var summary: String {
        "speech windows \(speechWindows) · of 300 ms or more \(longWindows) · own words heard \(echoWordEvents) · other words \(otherWordEvents) · voice \(source)"
    }

    private func note(_ line: String) {
        log.append(String(format: "%6.2f  %@", Date().timeIntervalSince(started), line))
    }

    func run(synth: any SpeechSynthesising, settings: VoiceSettings, voiceProcessing: Bool) async {
        guard !running else { return }
        running = true
        log = []
        speechWindows = 0; longWindows = 0; echoWordEvents = 0; otherWordEvents = 0
        started = Date()
        let audio = VoiceAudioEngine(voiceProcessing: voiceProcessing)
        let session = VoiceAudioSession(engine: audio)
        let capture = VoiceCapture(audio: audio)
        let player = SpeechPlayer(synth: synth, cache: .standard(), output: audio, local: EngineLocalVoice(audio: audio),
                                  settings: settings)
        do {
            try session.activate()
            note("route \(session.routeName) voiceProcessing=\(voiceProcessing)")
            try await capture.start(.monitor)
        } catch {
            note("FAILED to start: \(error)")
            session.release()
            running = false
            return
        }
        let events = capture.events
        let listening = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .speechStarted:
                    self.speechWindows += 1
                    self.windowStart = Date()
                    self.note("speech started")
                case .speechEnded:
                    let length = self.windowStart.map { Date().timeIntervalSince($0) } ?? 0
                    if length >= 0.3 { self.longWindows += 1 }
                    self.note(String(format: "speech ended after %.2f s", length))
                case .words(let text):
                    if VoiceModeEngine.isEcho(text, of: Self.clip) {
                        self.echoWordEvents += 1
                        self.note("OWN WORDS: \(text)")
                    } else if !text.isEmpty {
                        self.otherWordEvents += 1
                        self.note("words: \(text)")
                    }
                case .failed:
                    self.note("capture FAILED")
                }
            }
        }
        source = (await player.speak(Self.clip)).rawValue
        note("clip finished (\(source))")
        try? await Task.sleep(for: .seconds(4))
        listening.cancel()
        _ = await capture.stop(keep: false)
        session.release()
        note(summary)
        running = false
    }
}

@available(iOS 26, *)
struct VoiceSpikeView: View {
    let synth: any SpeechSynthesising
    let settings: VoiceSettings
    @State private var spike = VoiceSpike()

    var body: some View {
        List {
            Section {
                Button("Run with voice processing") {
                    Task { await spike.run(synth: synth, settings: settings, voiceProcessing: true) }
                }
                Button("Run WITHOUT voice processing (comparison)") {
                    Task { await spike.run(synth: synth, settings: settings, voiceProcessing: false) }
                }
            }
            .disabled(spike.running)
            Section("Result") {
                Text(spike.summary).font(.footnote.monospaced())
                Button("Copy log") { UIPasteboard.general.string = spike.log.joined(separator: "\n") }
            }
            Section("Log") {
                ForEach(Array(spike.log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Talking-over spike")
    }
}
```

In `Matron/Features/Voice/VoiceDebugView.swift`, directly before `Section("Sounds") {`:

```swift
            if #available(iOS 26, *) {
                Section("Spike") {
                    NavigationLink("Talking-over spike") { VoiceSpikeView(synth: synth, settings: settings) }
                }
            }
```

Run: `xcodegen generate && git checkout Matron/App/Info.plist`, then `xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Run the spike on a phone**

Build to a real iPhone on iOS 26 or later (or `scripts/testflight-upload.sh` from this branch and install from TestFlight). Turn the debug tools on (Settings ▸ long-press "Voice mode"), open any conversation, ⓘ ▸ Speak a reply ▸ Talking-over spike.

For each route — **(a) the loudspeaker, volume buttons at maximum, phone on a table in a quiet room; (b) AirPods** — do this five times: tap "Run with voice processing", say nothing until the clip says "Now", then say "stop" once. After each run tap "Copy log" and keep it. Then, on the loudspeaker only, tap "Run WITHOUT voice processing" once and stay silent throughout.

Read from each result line (`speech windows … · of 300 ms or more … · own words heard … · other words … · voice …`) and the log:

| Check | Passes when |
|---|---|
| The test can see a failure at all | The run WITHOUT voice processing on the loudspeaker shows `own words heard` greater than 0. If it shows 0, the recogniser is not hearing the speaker and the other results prove nothing: fix that first (see the last row of the next table). |
| The app's voice does not trigger talking-over | In every run WITH voice processing: `own words heard` is 0, and the result line shows at most 3 windows of 300 ms or more (one of them is your own "stop", so at most 2 false starts in a minute of speech; 3 inside one clip is what switches talking-over off). |
| Dan's voice does | In at least 4 of the 5 runs, a `words: stop` line appears within 1.5 s of the `speech started` line that follows "Now". |
| Nothing else is wrong | No `FAILED` line; no speech-recognition permission prompt appeared (only the microphone's, once); the clip is clearly audible and not distorted; the first run's `speech`/`words` lines begin within about two seconds of tapping Run. |

Also note for the PR description: the route's name as logged, the input sample rate (Console, subsystem `chat.matron`, category `voice-session`), which voice spoke (`cloud` or `onDevice`), and how the loudspeaker sounds in `.voiceChat` mode.

- [ ] **Step 10: Decide — the result that lets PR 3 proceed, and what to do otherwise**

| Result | What to do |
|---|---|
| Both routes pass every check | Proceed exactly as written. Talking over the agent ships **on** by default. |
| AirPods pass, the loudspeaker fails "does not trigger" or "Dan's voice does" | Proceed, with talking-over **off by default and a tap to interrupt**: in Task 20 Step 6 build the settings as `VoiceSettings(talkOverDefault: false)`. The setting stays, so it can be turned on for AirPods; the engine's own guard (three false starts in a clip switch it off for that route) covers anyone who turns it on over the loudspeaker. Say so in the PR description and in Task 21's manual tests. |
| Both routes fail, or capture only works WITHOUT voice processing | Proceed with talking-over off by default as above, AND in Task 20's `VoiceModeSession` build the engine as `VoiceAudioEngine(voiceProcessing: false)`, AND delete the `Toggle("Talk over the agent", …)` row from `VoiceSettingsSection` (it cannot work without echo cancellation). The loop still works: with the setting off the engine never opens the microphone under a clip (`VoiceModeEngineTests.testWithTalkingOverSwitchedOffOnlyATapInterrupts`). |
| The clip is distorted or very quiet on the loudspeaker but the checks pass | In `VoiceAudioSession.activate()` change `mode: .voiceChat` to `mode: .default`, rerun Step 9 on the loudspeaker, and keep whichever mode passes and sounds right. |
| `FAILED to start` in both runs (the recogniser itself will not start) | Stop. Voice mode needs the recogniser for end of speech. Read the logged error: `recogniserUnavailable` means `SpeechTranscriber.isAvailable` is false on this phone or the `en-GB` model could not be installed (check Settings ▸ General ▸ Language & Region and storage, then retry on Wi-Fi); an authorisation error means the assumption above is wrong: add `SFSpeechRecognizer.requestAuthorization` to `VoiceCapture.start` before `SpeechListener.make` and rerun. If it still will not start, file it for Dan with the log; do not build Tasks 16–21 on a guess. |

Write the chosen row and the ten result lines into the PR description draft now (`/tmp/voice-spike.md`); Task 21 pastes it.

- [ ] **Step 11: Commit**

```bash
git add MatronShared/Sources/Voice/VoiceModeSeams.swift MatronShared/Sources/Voice/VoiceAudioEngine.swift \
        MatronShared/Sources/Voice/VoiceAudioSession.swift MatronShared/Sources/Voice/VoiceCapture.swift \
        MatronShared/Tests/VoiceTests/VoiceCaptureTests.swift project.yml Matron/App/Info.plist \
        Matron/Features/Voice/VoiceSpikeView.swift Matron/Features/Voice/VoiceDebugView.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: capture through AVAudioEngine with voice processing, and the talking-over spike" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 16: The transcript route, and voice mode's sends

**Files:**
- Create: `MatronShared/Sources/Journal/JournalAPI+Transcript.swift`, `MatronShared/Sources/Voice/JournalVoiceSender.swift`
- Test: `MatronShared/Tests/JournalTests/MediaTranscriptAPITests.swift`, `MatronShared/Tests/VoiceTests/JournalVoiceSenderTests.swift` (new)

**Interfaces:**
- Produces (MatronJournal): `JournalAPI.mediaTranscript(blobRef:waitSeconds:) async throws -> String?` — the words only when `status` is `done`; `nil` for `none`, `pending`, `failed`, an empty transcript and a 404.
- Produces (MatronVoice): `struct JournalVoiceSender: VoiceSending` — `init(api:engine:items:)`; `filename` (`voice-note.m4a`), `mimeType` (`audio/mp4`).
- How the app uploads a voice note today, and what this reuses: `ComposerViewModel.sendVoiceNote` (`ComposerViewModel.swift:684`) calls `timeline.sendFile`, which is `JournalTimelineService.sendMedia` (`JournalTimelineService.swift:795-805`): `api.uploadMedia` then `engine.sendOp(.sendMedia(…type: "file"…))` in one go. `ItemDetailViewModel.sendVoiceNote` (`ItemDetailViewModel.swift:726`) uploads then `sync.enqueueComment(body: "", attachments: [note])`. Neither asks for the transcript: the journal transcribes at upload and the bridge reads the words. Voice mode needs the words itself, between the upload and the send, so the two halves are called separately here; the frames they produce are the same.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/JournalTests/MediaTranscriptAPITests.swift`:

```swift
import XCTest
@testable import MatronJournal

final class MediaTranscriptAPITests: XCTestCase {
    private func makeAPI() -> JournalAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    func testTranscriptIsTheWordsOnlyWhenDone() async throws {
        let api = makeAPI()
        StubURLProtocol.responses = ["/media/m-1/transcript": (200, #"{"status":"done","transcript":" Merge it. "}"#)]
        let words = try await api.mediaTranscript(blobRef: "m-1", waitSeconds: 8)
        XCTAssertEqual(words, "Merge it.")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "wait=8")
        for body in [#"{"status":"pending"}"#, #"{"status":"none"}"#, #"{"status":"failed"}"#, #"{"status":"done","transcript":""}"#] {
            StubURLProtocol.responses = ["/media/m-1/transcript": (200, body)]
            let none = try await api.mediaTranscript(blobRef: "m-1", waitSeconds: 8)
            XCTAssertNil(none, body)
        }
        StubURLProtocol.responses = [:]   // an old journal: 404
        let old = try await api.mediaTranscript(blobRef: "m-1", waitSeconds: 99)
        XCTAssertNil(old)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "wait=30", "the journal's ceiling")
    }
}
```

Create `MatronShared/Tests/VoiceTests/JournalVoiceSenderTests.swift`:

```swift
import XCTest
import MatronJournal
import MatronModels
@testable import MatronVoice

final class JournalVoiceSenderTests: XCTestCase {
    final class Log: @unchecked Sendable {
        var uploads: [(Data, String)] = []
        var transcripts: [(String, Int)] = []
        var ops: [ClientOp] = []
        var comments: [(itemID: String, body: String, attachments: [TrackerAttachment], action: String?)] = []
    }

    func makeSender(_ log: Log, transcript: Result<String?, Error> = .success("Merge it.")) -> JournalVoiceSender {
        JournalVoiceSender(
            uploadMedia: { data, type in log.uploads.append((data, type)); return "m-1" },
            mediaTranscript: { ref, wait in log.transcripts.append((ref, wait)); return try transcript.get() },
            sendOp: { log.ops.append($0) },
            enqueueComment: { log.comments.append(($0, $1, $2, $3)) })
    }

    func testUploadIsAnAudioBlob() async throws {
        let log = Log()
        let ref = try await makeSender(log).upload(Data("aac".utf8))
        XCTAssertEqual(ref, "m-1")
        XCTAssertEqual(log.uploads.first?.1, "audio/mp4")
    }

    func testTranscriptPassesTheWaitAndSwallowsErrors() async {
        let log = Log()
        let words = await makeSender(log).transcript(blobRef: "m-1", waitSeconds: 8)
        XCTAssertEqual(words, "Merge it.")
        XCTAssertEqual(log.transcripts.first?.1, 8)
        struct Boom: Error {}
        let none = await makeSender(log, transcript: .failure(Boom())).transcript(blobRef: "m-1", waitSeconds: 8)
        XCTAssertNil(none)
    }

    /// The same frame `ComposerViewModel.sendVoiceNote` produces.
    func testAVoiceNoteToAConversationIsAFileSend() async throws {
        let log = Log()
        try await makeSender(log).sendVoiceNote(blobRef: "m-1", size: 9, to: .conversation("c1"))
        guard case .sendMedia(let convoID, let type, let blobRef, let name, let contentType, let size, let caption, let batch, _)? = log.ops.first else {
            return XCTFail("expected a media send")
        }
        XCTAssertEqual(convoID, "c1"); XCTAssertEqual(type, "file"); XCTAssertEqual(blobRef, "m-1")
        XCTAssertEqual(name, "voice-note.m4a"); XCTAssertEqual(contentType, "audio/mp4"); XCTAssertEqual(size, 9)
        XCTAssertNil(caption); XCTAssertNil(batch)
    }

    /// The same comment `ItemDetailViewModel.sendVoiceNote` queues.
    func testAVoiceNoteToAnItemIsAnAttachmentOnlyComment() async throws {
        let log = Log()
        try await makeSender(log).sendVoiceNote(blobRef: "m-1", size: 9, to: .item("it_1"))
        XCTAssertEqual(log.comments.first?.itemID, "it_1")
        XCTAssertEqual(log.comments.first?.body, "")
        XCTAssertEqual(log.comments.first?.attachments,
                       [TrackerAttachment(blobRef: "m-1", mime: "audio/mp4", name: "voice-note.m4a", size: 9)])
        XCTAssertNil(log.comments.first?.action)
    }

    /// The same comment `ItemDetailViewModel.chooseAction` queues.
    func testAnItemActionIsTheLabelAsBodyAndAction() async {
        let log = Log()
        await makeSender(log).sendItemAction(itemID: "it_1", label: "Go")
        XCTAssertEqual(log.comments.first?.body, "Go")
        XCTAssertEqual(log.comments.first?.action, "Go")
        XCTAssertEqual(log.comments.first?.attachments, [])
    }

    func testAPromptReplyIsThePromptReplyOp() async throws {
        let log = Log()
        try await makeSender(log).sendPromptReply(convoID: "c3", seq: 30, choice: "pg", text: nil)
        try await makeSender(log).sendPromptReply(convoID: "c3", seq: 31, choice: nil, text: "Use MySQL.")
        XCTAssertEqual(log.ops, [.promptReply(convoID: "c3", targetSeq: 30, choice: "pg", text: nil),
                                 .promptReply(convoID: "c3", targetSeq: 31, choice: nil, text: "Use MySQL.")])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'JournalTests.MediaTranscriptAPITests|VoiceTests.JournalVoiceSenderTests'`
Expected: build FAILS — `value of type 'JournalAPI' has no member 'mediaTranscript'`.

- [ ] **Step 3: Implement the route**

Create `MatronShared/Sources/Journal/JournalAPI+Transcript.swift`:

```swift
import Foundation

extension JournalAPI {
    /// The words of a voice note the journal transcribed at upload
    /// (`GET /media/:id/transcript?wait=N`, `wait` at most 30 seconds):
    /// `{status: none|pending|done|failed, transcript?}`. `nil` for
    /// anything but `done` with words: a journal with transcription off
    /// (`none`), one still working (`pending` after the wait), a failure,
    /// or a journal that predates the route (404).
    public func mediaTranscript(blobRef: String, waitSeconds: Int) async throws -> String? {
        let (data, response) = try await rawRequest(
            path: "/media/\(Self.pathSegment(blobRef))/transcript", method: "GET", body: nil,
            query: [URLQueryItem(name: "wait", value: String(max(0, min(30, waitSeconds))))])
        guard response.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["status"] as? String == "done",
              let transcript = (obj["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty
        else { return nil }
        return transcript
    }
}
```

- [ ] **Step 4: Implement the sender**

Create `MatronShared/Sources/Voice/JournalVoiceSender.swift`:

```swift
import Foundation
import MatronJournal
import MatronModels

/// Voice mode's sends, on the paths the app already uses for the same
/// things by hand:
///
/// - upload: `POST /media`, as `JournalTimelineService.sendMedia` and
///   `ItemDetailViewModel.submitAttachments` do;
/// - a voice note to a conversation: the `file` media send
///   `ComposerViewModel.sendVoiceNote` ends in (`voice-note.m4a`,
///   `audio/mp4`);
/// - a voice note or an action on an item: the item outbox
///   (`ItemsSync.enqueueComment`), which is what
///   `ItemDetailViewModel.sendVoiceNote` and `chooseAction` use, so both
///   survive being offline;
/// - a prompt answer: the `prompt_reply` op.
public struct JournalVoiceSender: VoiceSending {
    public static let filename = "voice-note.m4a"
    public static let mimeType = "audio/mp4"

    let uploadMedia: @Sendable (Data, String) async throws -> String
    let mediaTranscript: @Sendable (String, Int) async throws -> String?
    let sendOp: @Sendable (ClientOp) async throws -> Void
    let enqueueComment: @Sendable (_ itemID: String, _ body: String, _ attachments: [TrackerAttachment], _ action: String?) async -> Void

    init(uploadMedia: @escaping @Sendable (Data, String) async throws -> String,
         mediaTranscript: @escaping @Sendable (String, Int) async throws -> String?,
         sendOp: @escaping @Sendable (ClientOp) async throws -> Void,
         enqueueComment: @escaping @Sendable (String, String, [TrackerAttachment], String?) async -> Void) {
        self.uploadMedia = uploadMedia
        self.mediaTranscript = mediaTranscript
        self.sendOp = sendOp
        self.enqueueComment = enqueueComment
    }

    public init(api: JournalAPI, engine: JournalSyncEngine, items: ItemsSync) {
        self.init(
            uploadMedia: { data, type in try await api.uploadMedia(data, contentType: type) },
            mediaTranscript: { ref, wait in try await api.mediaTranscript(blobRef: ref, waitSeconds: wait) },
            sendOp: { op in try await engine.sendOp(op) },
            enqueueComment: { itemID, body, attachments, action in
                await items.enqueueComment(itemID: itemID, localID: UUID().uuidString, body: body,
                                           attachments: attachments, action: action)
            })
    }

    public func upload(_ audio: Data) async throws -> String {
        try await uploadMedia(audio, Self.mimeType)
    }

    public func transcript(blobRef: String, waitSeconds: Int) async -> String? {
        (try? await mediaTranscript(blobRef, waitSeconds)) ?? nil
    }

    public func sendVoiceNote(blobRef: String, size: Int, to target: VoiceModeEngine.SendTarget) async throws {
        switch target {
        case .conversation(let convoID):
            try await sendOp(.sendMedia(convoID: convoID, type: "file", blobRef: blobRef, name: Self.filename,
                                        contentType: Self.mimeType, size: size, caption: nil, batch: nil,
                                        localID: UUID().uuidString))
        case .item(let itemID):
            let note = TrackerAttachment(blobRef: blobRef, mime: Self.mimeType, name: Self.filename, size: Int64(size))
            await enqueueComment(itemID, "", [note], nil)
        }
    }

    public func sendItemAction(itemID: String, label: String) async {
        await enqueueComment(itemID, label, [], label)
    }

    public func sendPromptReply(convoID: String, seq: Int64, choice: String?, text: String?) async throws {
        try await sendOp(.promptReply(convoID: convoID, targetSeq: seq, choice: choice, text: text))
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'JournalTests.MediaTranscriptAPITests|VoiceTests.JournalVoiceSenderTests'`
Expected: `Executed 1 test, with 0 failures` and `Executed 6 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add MatronShared/Sources/Journal/JournalAPI+Transcript.swift MatronShared/Sources/Voice/JournalVoiceSender.swift \
        MatronShared/Tests/JournalTests/MediaTranscriptAPITests.swift MatronShared/Tests/VoiceTests/JournalVoiceSenderTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: ask the journal for a note's words, and send on the paths the app already uses" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 17: `JournalVoiceFeed` — turn ends, the summary wait, and things starting to need Dan

**Files:**
- Create: `MatronShared/Sources/Voice/JournalVoiceFeed.swift`
- Test: `MatronShared/Tests/VoiceTests/JournalVoiceFeedTests.swift` (new)

**Interfaces:**
- Consumes: `JournalStore.sessionStateStream(convoID:)` (`JournalStore.swift:2231`; it re-delivers on every change to the conversation's row, so a turn that started and ended between two deliveries is still noticed), `lastAgentReply`, `spokenSummary` (Task 2), `needsYouEntries` (Task 7), `maxSeq(convoID:)`, `conversation(id:)`, `agentNames()`.
- Produces (MatronVoice):
  - `struct VoiceTextMaker { short, sections, plain }` — the cleaner, as closures.
  - `@MainActor final class JournalVoiceFeed: VoiceFeeding` — `init(store:text:scope:summaryWait:poll:needsPoll:now:sleep:)`, `Scope { conversation(String), everything }`, `initialQueue() -> [VoiceEntry]`, `lastConversation(excluding:)`, `startWatchingNeeds()`, `watch(convoID:)`, `stop()`, `events`.
- Emits `.turnStarted` / `.turnEnded` for a watched conversation, `.arrived(.reply)` once per new reply (after waiting up to `summaryWait`, 4 s, for a summary whose `spoken_ref` names it; a reply with no `message_ref` does not wait), `.arrived` for a prompt or item that starts needing the user, `.resolved(id:expired:)` when one stops (`expired` when a permission prompt's five minutes ran out).

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/VoiceTests/JournalVoiceFeedTests.swift`:

```swift
import XCTest
import MatronJournal
import MatronModels
@testable import MatronVoice

@MainActor
final class JournalVoiceFeedTests: XCTestCase {
    static let text = VoiceTextMaker(
        short: { String($0.prefix(while: { $0 != "." })) + ($0.isEmpty ? "" : ".") },
        sections: { $0.isEmpty ? [] : [$0] },
        plain: { $0.replacingOccurrences(of: "**", with: "") })

    var store: JournalStore!
    var nextSeq: Int64 = 1
    var collected: [VoiceModeEngine.Event] = []
    var collector: Task<Void, Never>?

    override func setUp() async throws {
        store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        nextSeq = 1
        collected = []
    }

    override func tearDown() async throws {
        collector?.cancel()
    }

    @discardableResult
    func apply(_ type: String, convo: String = "c1", sender: String = "agent:bev", _ payload: [String: Any]) throws -> Int64 {
        let seq = nextSeq
        nextSeq += 1
        _ = try store.applyJournal(JournalEvent(seq: seq, convoID: convo, ts: Date(), sender: sender, type: type,
                                                payloadData: try JSONSerialization.data(withJSONObject: payload)))
        return seq
    }

    func makeFeed(_ scope: JournalVoiceFeed.Scope = .conversation("c1"), summaryWait: TimeInterval = 0.2) -> JournalVoiceFeed {
        let feed = JournalVoiceFeed(store: store, text: Self.text, scope: scope, summaryWait: summaryWait, poll: 0.02, needsPoll: 0.05)
        let events = feed.events
        collector = Task { [weak self] in
            for await event in events { self?.collected.append(event) }
        }
        return feed
    }

    /// For "nothing more happens": long enough for a delivery to land.
    func settle(_ seconds: TimeInterval = 0.4) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// For "this happens": returns as soon as it has. Sleeps under a test
    /// host are coarse (20 ms can take 150), so nothing here asserts on a
    /// fixed delay.
    func waitUntil(_ timeout: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    var arrivedIDs: [String] {
        collected.compactMap { event -> String? in
            if case .arrived(let entry) = event { return entry.id } else { return nil }
        }
    }

    var arrivedReplies: [SpokenReply] {
        collected.compactMap { event -> SpokenReply? in
            if case .arrived(let entry) = event, case .reply(let reply) = entry.subject { return reply }
            return nil
        }
    }

    func testATurnEndingWithASummarySpeaksTheBridgesLines() async throws {
        try apply("convo_meta", ["title": "[ab] Auth refactor"])
        try apply("session_status", ["state": "waiting"])
        let feed = makeFeed()
        feed.watch(convoID: "c1")
        await settle()
        try apply("session_status", ["state": "running"])
        await settle()
        let seq = try apply("text", ["body": "The deploy finished. All green.", "message_ref": "m1"])
        try apply("summary", ["toc": "Deploy", "spoken": "The deploy is done.", "spoken_more": "Every test passed.", "spoken_ref": "m1"])
        try apply("session_status", ["state": "waiting"])
        await waitUntil { !self.arrivedReplies.isEmpty }
        XCTAssertEqual(arrivedReplies, [SpokenReply(convoID: "c1", seq: seq, short: "The deploy is done.",
                                                    more: "Every test passed.", sections: ["The deploy finished. All green."])])
        XCTAssertTrue(collected.contains(.turnStarted(convoID: "c1")))
        XCTAssertTrue(collected.contains(.turnEnded(convoID: "c1")))
        if case .arrived(let entry)? = collected.last {
            XCTAssertEqual(entry.convoTitle, "Auth refactor")
        } else {
            XCTFail("the reply arrives last")
        }
        feed.stop()
    }

    func testNoSummaryFallsBackToTheCleanerAfterTheWait() async throws {
        try apply("session_status", ["state": "running"])
        let feed = makeFeed(summaryWait: 0.1)
        feed.watch(convoID: "c1")
        await settle()
        try apply("text", ["body": "The deploy finished. All green.", "message_ref": "m1"])
        try apply("session_status", ["state": "waiting"])
        XCTAssertEqual(arrivedReplies, [], "it waits for the summary first")
        await waitUntil { !self.arrivedReplies.isEmpty }
        XCTAssertEqual(arrivedReplies.map(\.short), ["The deploy finished."])
        XCTAssertNil(arrivedReplies.first?.more)
        XCTAssertEqual(arrivedReplies.first?.sections, ["The deploy finished. All green."])
        feed.stop()
    }

    func testASummaryThatLandsDuringTheWaitIsUsed() async throws {
        try apply("session_status", ["state": "running"])
        let feed = makeFeed(summaryWait: 30)
        feed.watch(convoID: "c1")
        await settle()
        try apply("text", ["body": "Long answer. With detail.", "message_ref": "m1"])
        try apply("session_status", ["state": "waiting"])
        await settle()
        XCTAssertEqual(arrivedReplies, [])
        try apply("summary", ["toc": "T", "spoken": "Short answer.", "spoken_ref": "m1"])
        await waitUntil { !self.arrivedReplies.isEmpty }
        XCTAssertEqual(arrivedReplies.map(\.short), ["Short answer."])
        feed.stop()
    }

    /// A summary for an older reply must not be said for the newest one.
    func testALateSummaryForAnOlderReplyIsIgnored() async throws {
        try apply("session_status", ["state": "running"])
        let feed = makeFeed(summaryWait: 0.1)
        feed.watch(convoID: "c1")
        await settle()
        try apply("text", ["body": "Old reply. Detail.", "message_ref": "m1"])
        try apply("text", ["body": "New reply. Detail.", "message_ref": "m2"])
        try apply("summary", ["toc": "T", "spoken": "About the old one.", "spoken_ref": "m1"])
        try apply("session_status", ["state": "waiting"])
        await waitUntil { !self.arrivedReplies.isEmpty }
        XCTAssertEqual(arrivedReplies.map(\.short), ["New reply."])
        feed.stop()
    }

    func testWhatWasAlreadyThereIsNotSpoken() async throws {
        try apply("text", ["body": "Yesterday's reply.", "message_ref": "m0"])
        try apply("session_status", ["state": "waiting"])
        let feed = makeFeed(summaryWait: 0.05)
        feed.watch(convoID: "c1")
        await settle()
        XCTAssertEqual(arrivedReplies, [])
        // A message that is its own summary has nothing more to read.
        try apply("text", ["body": "Done.", "message_ref": "m1"])
        await waitUntil { !self.arrivedReplies.isEmpty }
        XCTAssertEqual(arrivedReplies.map(\.short), ["Done."])
        XCTAssertEqual(arrivedReplies.first?.sections, [])
        feed.stop()
    }

    func testAPromptArrivesAndIsResolvedWhenAnswered() async throws {
        try apply("convo_meta", ["title": "[ab] Schema"])
        let feed = makeFeed(.everything)
        feed.startWatchingNeeds()
        await settle()
        let seq = try apply("prompt", ["question": "Which **database**?", "options": ["Postgres", "SQLite"]])
        await waitUntil { !self.arrivedIDs.isEmpty }
        guard case .arrived(let entry)? = collected.last, case .prompt(let prompt) = entry.subject else {
            return XCTFail("the prompt arrives: \(collected)")
        }
        XCTAssertEqual(prompt.question, "Which database?", "through the cleaner")
        XCTAssertEqual(entry.id, "prompt:\(seq)")
        try apply("prompt_reply", sender: "user:dan", ["target_seq": seq, "choice": "Postgres"])
        await waitUntil { self.collected.last == .resolved(id: "prompt:\(seq)", expired: false) }
        XCTAssertEqual(collected.last, .resolved(id: "prompt:\(seq)", expired: false))
        feed.stop()
    }

    func testInAConversationOnlyItsOwnPromptsArriveAndWaitingItemsAreNotReadOut() async throws {
        try store.upsertItems([TrackerItem(id: "it_old", num: 1, kind: .question, awaiting: .user, title: "Old", originConvoID: "c1")])
        try apply("prompt", convo: "c1", ["question": "Here?", "options": ["Yes", "No"]])
        try apply("prompt", convo: "c2", ["question": "Elsewhere?", "options": ["Yes", "No"]])
        let feed = makeFeed(.conversation("c1"))
        feed.startWatchingNeeds()
        await waitUntil { !self.arrivedIDs.isEmpty }
        await settle()
        XCTAssertEqual(arrivedIDs, ["prompt:1"])
        try store.upsertItems([TrackerItem(id: "it_new", num: 2, kind: .decision, awaiting: .user, title: "New",
                                           originConvoID: "c1", actions: ["Go"])])
        await waitUntil { self.arrivedIDs.count == 2 }
        XCTAssertEqual(collected.last, .arrived(.item(VoiceItem(id: "it_new", kind: .decision, convoID: "c1", title: "New",
                                                                labels: ["Go"]), convoTitle: "")))
        feed.stop()
    }

    func testTheInitialQueueIsReadableAndNotAnnouncedAgain() async throws {
        try apply("convo_meta", convo: "c1", ["title": "[ab] Auth refactor"])
        try apply("text", convo: "c1", ["body": "All merged. Nothing left.", "message_ref": "m1"])
        try apply("summary", convo: "c1", ["toc": "T", "spoken": "It is merged.", "spoken_ref": "m1"])
        try apply("session_status", convo: "c1", ["state": "waiting"])
        try apply("prompt", convo: "c2", ["question": "Ship it?", "options": ["Yes", "No"]])
        try store.upsertItems([TrackerItem(id: "it_a", num: 7, kind: .question, awaiting: .user, title: "Pick a colour",
                                           body: "Red or blue.", originConvoID: "c1", actions: ["Red", "Blue"])])
        let feed = makeFeed(.everything)
        let queue = feed.initialQueue()
        XCTAssertEqual(queue.map(\.id), ["prompt:5", "item:it_a", "reply:c1:2"])
        if case .reply(let reply) = queue[2].subject {
            XCTAssertEqual(reply.short, "It is merged.")
        } else {
            XCTFail("the unseen reply is last")
        }
        if case .item(let item) = queue[1].subject {
            XCTAssertEqual(item.sections, ["Red or blue."])
            XCTAssertEqual(item.labels, ["Red", "Blue"])
        } else {
            XCTFail("the item is second")
        }
        feed.startWatchingNeeds()
        feed.watch(convoID: "c1")
        await settle()
        XCTAssertFalse(collected.contains { if case .arrived = $0 { return true } else { return false } },
                       "nothing in the queue arrives a second time")
        XCTAssertEqual(feed.lastConversation()?.id, "c2")
        XCTAssertEqual(feed.lastConversation(excluding: "c2")?.title, "Auth refactor")
        feed.stop()
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'VoiceTests.JournalVoiceFeedTests'`
Expected: build FAILS — `cannot find 'JournalVoiceFeed' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/Voice/JournalVoiceFeed.swift`:

```swift
import Foundation
import MatronJournal
import MatronModels

/// Markdown to speech, handed in by the app: the cleaner lives beside the
/// Markdown renderers (`SpeechCleaner` in MatronDesignSystem), which this
/// module never imports.
public struct VoiceTextMaker: Sendable {
    /// Level 1 when the bridge sent no spoken line.
    public var short: @Sendable (String) -> String
    /// Level 3: the message, about a minute a section.
    public var sections: @Sendable (String) -> [String]
    /// A question or title as it should be said.
    public var plain: @Sendable (String) -> String

    public init(short: @escaping @Sendable (String) -> String, sections: @escaping @Sendable (String) -> [String],
                plain: @escaping @Sendable (String) -> String) {
        self.short = short; self.sections = sections; self.plain = plain
    }
}

/// Watches the local mirror for what voice mode should say (spec
/// 2026-10-03 §3, "What is spoken", and §5): a watched conversation's
/// turn ending, and prompts and items that start or stop needing the user.
/// Reads only the store: nothing here talks to the network.
@MainActor
public final class JournalVoiceFeed: VoiceFeeding {
    public enum Scope: Equatable, Sendable {
        /// Started inside a conversation: only what happens in it.
        case conversation(String)
        /// Started from the app shell: everything that needs the user.
        case everything
    }

    public let events: AsyncStream<VoiceModeEngine.Event>
    private let continuation: AsyncStream<VoiceModeEngine.Event>.Continuation

    private let store: JournalStore
    private let text: VoiceTextMaker
    private let scope: Scope
    /// How long a turn's end waits for its `summary` event before the
    /// cleaner's version is used (spec: up to four seconds).
    private let summaryWait: TimeInterval
    private let poll: TimeInterval
    private let needsPoll: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var watchers: [String: Task<Void, Never>] = [:]
    private var replies: [String: Task<Void, Never>] = [:]
    /// Per conversation: nothing at or below this seq is a new reply.
    private var floors: [String: Int64] = [:]
    private var needsTask: Task<Void, Never>?
    private var known: Set<String> = []
    private var permissionDeadlines: [String: Date] = [:]

    public init(store: JournalStore, text: VoiceTextMaker, scope: Scope, summaryWait: TimeInterval = 4,
                poll: TimeInterval = 0.25, needsPoll: TimeInterval = 2,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.store = store
        self.text = text
        self.scope = scope
        self.summaryWait = summaryWait
        self.poll = poll
        self.needsPoll = needsPoll
        self.now = now
        self.sleep = sleep
        (events, continuation) = AsyncStream.makeStream(of: VoiceModeEngine.Event.self)
    }

    // MARK: The queue

    /// "What needs you" as entries the engine can read out, in the
    /// queue's order. Call before `start(.queue…)`.
    public func initialQueue() -> [VoiceEntry] {
        let entries = (try? store.needsYouEntries(now: now())) ?? []
        remember(entries)
        return entries.compactMap(voiceEntry)
    }

    /// The conversation voice mode falls back to once the queue is empty:
    /// the one used last, other than `excluding` (the Coordinator's).
    public func lastConversation(excluding: String? = nil) -> (id: String, title: String, boxName: String?)? {
        guard let record = (try? store.conversations(now: now()))?.first(where: { $0.id != excluding }) else { return nil }
        return (record.id, NeedsYouQueue.cleanTitle(record.title), boxName(record.agentDeviceID))
    }

    /// Starts telling the engine about prompts and items as they start and
    /// stop needing the user.
    public func startWatchingNeeds() {
        guard needsTask == nil else { return }
        if case .conversation = scope {
            // Items already waiting when voice mode opened inside a
            // conversation are not read out; a prompt there is.
            let items = ((try? store.needsYouEntries(now: now())) ?? []).filter {
                if case .item = $0.kind { return true } else { return false }
            }
            known.formUnion(items.map(\.id))
        }
        let interval = needsPoll
        let sleep = self.sleep
        needsTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshNeeds()
                do { try await sleep(interval) } catch { return }
            }
        }
    }

    private func inScope(_ entry: NeedsYouEntry) -> Bool {
        switch scope {
        case .everything: return true
        case .conversation(let id): return entry.convoID == id
        }
    }

    private func remember(_ entries: [NeedsYouEntry]) {
        for entry in entries {
            known.insert(entry.id)
            if case .permission(let prompt) = entry.kind, permissionDeadlines[entry.id] == nil,
               let ts = (try? store.events(convoID: prompt.convoID, beforeSeq: prompt.seq + 1, limit: 1))?.last?.ts {
                permissionDeadlines[entry.id] = ts.addingTimeInterval(NeedsYouQueue.permissionTTL)
            }
        }
    }

    func refreshNeeds() {
        let entries = ((try? store.needsYouEntries(now: now())) ?? []).filter { entry in
            if case .unseenReply = entry.kind { return false }
            return inScope(entry)
        }
        let ids = Set(entries.map(\.id))
        let fresh = entries.filter { !known.contains($0.id) }
        let gone = known.subtracting(ids).filter { !$0.hasPrefix("convo:") }
        remember(fresh)
        for entry in fresh {
            if let voice = voiceEntry(entry) { continuation.yield(.arrived(voice)) }
        }
        for id in gone.sorted() {
            known.remove(id)
            let expired = permissionDeadlines.removeValue(forKey: id).map { now() >= $0 } ?? false
            continuation.yield(.resolved(id: id, expired: expired))
        }
    }

    private func boxName(_ deviceID: Int64?) -> String? {
        guard let deviceID else { return nil }
        return (try? store.agentNames())?[deviceID]
    }

    func voiceEntry(_ entry: NeedsYouEntry) -> VoiceEntry? {
        switch entry.kind {
        case .permission(let prompt), .prompt(let prompt):
            let said = VoicePrompt(convoID: prompt.convoID, seq: prompt.seq, question: text.plain(prompt.question),
                                   options: prompt.options, allowsFreeText: prompt.allowsFreeText, permission: prompt.permission)
            return .prompt(said, convoTitle: entry.convoTitle, boxName: entry.boxName)
        case .item(let item):
            return .item(VoiceItem(item, sections: text.sections(item.body)), convoTitle: entry.convoTitle, boxName: entry.boxName)
        case .unseenReply:
            let read = (try? store.conversation(id: entry.convoID))?.readUpToSeq ?? 0
            guard let reply = try? store.lastAgentReply(convoID: entry.convoID, afterSeq: read),
                  let spoken = spokenReply(reply, convoID: entry.convoID) else { return nil }
            floors[entry.convoID] = (try? store.maxSeq(convoID: entry.convoID)) ?? reply.seq
            return .reply(spoken, convoTitle: entry.convoTitle, boxName: entry.boxName)
        }
    }

    // MARK: Turns

    public func watch(convoID: String) {
        guard watchers[convoID] == nil else { return }
        if floors[convoID] == nil {
            // Whatever is already there has been seen (or was just read
            // out as a queue entry): only later replies are spoken.
            floors[convoID] = ((try? store.maxSeq(convoID: convoID)) ?? nil) ?? 0
        }
        let stream = store.sessionStateStream(convoID: convoID)
        watchers[convoID] = Task { [weak self] in
            var wasRunning: Bool?
            // One value per change to the conversation's row, so a turn
            // that started and ended between two deliveries is still seen:
            // every quiet delivery looks for a reply above the floor.
            for await state in stream {
                guard let self, !Task.isCancelled else { return }
                let running = state == "running"
                if running, wasRunning != true { self.continuation.yield(.turnStarted(convoID: convoID)) }
                if !running {
                    if wasRunning == true { self.continuation.yield(.turnEnded(convoID: convoID)) }
                    self.lookForReply(convoID)
                }
                wasRunning = running
            }
        }
    }

    private func lookForReply(_ convoID: String) {
        guard let reply = try? store.lastAgentReply(convoID: convoID, afterSeq: floors[convoID] ?? 0) else { return }
        floors[convoID] = ((try? store.maxSeq(convoID: convoID)) ?? nil) ?? reply.seq
        replies[convoID]?.cancel()
        let wait = summaryWait
        let step = poll
        let sleep = self.sleep
        replies[convoID] = Task { [weak self] in
            // The summary pass lands a second or three after the turn
            // ends. A reply with no ref can have no spoken line: no wait.
            var waited: TimeInterval = 0
            while reply.messageRef != nil, waited < wait, !Task.isCancelled {
                if (try? self?.store.spokenSummary(convoID: convoID, for: reply)) ?? nil != nil { break }
                do { try await sleep(step) } catch { return }
                waited += step
            }
            guard let self, !Task.isCancelled, let spoken = self.spokenReply(reply, convoID: convoID) else { return }
            let record = try? self.store.conversation(id: convoID)
            self.continuation.yield(.arrived(.reply(spoken, convoTitle: NeedsYouQueue.cleanTitle(record?.title ?? ""),
                                                    boxName: self.boxName(record?.agentDeviceID))))
        }
    }

    /// The bridge's spoken lines when its summary names this reply, else
    /// the cleaner's short form. `nil` when there is nothing sayable.
    func spokenReply(_ reply: AgentReplyRow, convoID: String) -> SpokenReply? {
        let sections = text.sections(reply.body)
        if let summary = try? store.spokenSummary(convoID: convoID, for: reply), let spoken = summary.spoken {
            return SpokenReply(convoID: convoID, seq: reply.seq, short: spoken, more: summary.spokenMore, sections: sections)
        }
        let short = text.short(reply.body)
        guard !short.isEmpty else { return nil }
        // A message short enough to be its own summary has nothing more.
        let whole = sections.joined(separator: " ")
        return SpokenReply(convoID: convoID, seq: reply.seq, short: short, more: nil, sections: whole == short ? [] : sections)
    }

    public func stop() {
        for task in watchers.values { task.cancel() }
        for task in replies.values { task.cancel() }
        watchers = [:]
        replies = [:]
        needsTask?.cancel()
        needsTask = nil
        continuation.finish()
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'VoiceTests.JournalVoiceFeedTests'`
Expected: `Executed 8 tests, with 0 failures` (about seven seconds: three of them wait to show that nothing more arrives).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Voice/JournalVoiceFeed.swift MatronShared/Tests/VoiceTests/JournalVoiceFeedTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: the feed turns the local mirror into things to say" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 18: `VoiceModeRunner` — carrying out the engine's effects

**Files:**
- Create: `MatronShared/Sources/Voice/VoiceModeRunner.swift`
- Test: `MatronShared/Tests/VoiceTests/VoiceModeRunnerTests.swift` (new)

**Interfaces:**
- Consumes: the protocols of Task 15 Step 3; `VoiceModeEngine.reduce`; `VoiceSettings.engineConfig`.
- Produces (MatronVoice): `@MainActor @Observable final class VoiceModeRunner` — `init(capture:audio:player:sender:feed:settings:setScreenAwake:sleep:)`, `state` (observable), `start(_:)`, `send(_:)`, `settingsChanged()`, `connectionRestored()`, `onEnded`, `unsentCount`.
- What each effect does:

| Effect | Runner |
|---|---|
| `activateAudio`, `releaseAudio`, `startCapture`, `promoteCapture`, `stopCapture`, `earcon`, `upload`, `sendVoiceNote`, `discardRecording`, `ended` | Queued and run one after another in the order given (a stop must finish before the upload that reads its file). |
| `play` | Queued; the clip then plays in its own task, and `playbackFinished(id)` is sent unless it was stopped. |
| `stopPlayback`, `duck`, `restoreVolume`, timers, `watch`, `keepScreenAwake` | At once. |
| `upload` | `POST /media`, then the transcript wait; answers `.transcript(words?)` or `.uploadFailed`. Dropped if the recording was discarded or replaced meanwhile. |
| `sendVoiceNote` | Uploads first if that has not happened, then sends. Offline: the file is kept in `unsent` and sent on `connectionRestored()`; `.sendFailed` is reported only when the engine does not already know (the upload had succeeded). |
| `sendItemAction` | Through the item outbox: it cannot fail offline. |
| `sendPromptReply` | The WebSocket op; `.sendFailed` when offline. |

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/VoiceTests/VoiceModeRunnerTests.swift`:

```swift
import XCTest
@testable import MatronVoice

@MainActor
final class VoiceModeRunnerTests: XCTestCase {
    final class FakeCapture: VoiceCapturing {
        let events: AsyncStream<VoiceCaptureEvent>
        let continuation: AsyncStream<VoiceCaptureEvent>.Continuation
        var log: [String] = []
        var startError: Error?
        var fileToReturn: URL?
        init() { (events, continuation) = AsyncStream.makeStream(of: VoiceCaptureEvent.self) }
        func start(_ mode: VoiceModeEngine.CaptureMode) async throws {
            if let startError { throw startError }
            log.append("start \(mode.rawValue)")
        }
        func promote() { log.append("promote") }
        func stop(keep: Bool) async -> URL? {
            log.append("stop keep=\(keep)")
            return keep ? fileToReturn : nil
        }
    }

    final class FakeAudio: VoiceAudioControlling {
        let events: AsyncStream<VoiceModeEngine.Event>
        let continuation: AsyncStream<VoiceModeEngine.Event>.Continuation
        var routeName = "Speaker"
        var log: [String] = []
        init() { (events, continuation) = AsyncStream.makeStream(of: VoiceModeEngine.Event.self) }
        func activate() throws { log.append("activate") }
        func release() { log.append("release") }
    }

    final class FakePlayer: SpeechPlaying {
        var spoken: [String] = []
        var earcons: [VoiceModeEngine.Earcon] = []
        var ducks: [Bool] = []
        var stops = 0
        /// Lines whose playback the test finishes by hand.
        var held: [CheckedContinuation<SpeechPlayer.Source, Never>] = []
        var holds = false
        func speak(_ text: String) async -> SpeechPlayer.Source {
            spoken.append(text)
            guard holds else { return .cloud }
            return await withCheckedContinuation { held.append($0) }
        }
        func stop() {
            stops += 1
            held.forEach { $0.resume(returning: .stopped) }
            held = []
        }
        func setDucked(_ ducked: Bool) { ducks.append(ducked) }
        func play(_ earcon: VoiceModeEngine.Earcon) { earcons.append(earcon) }
    }

    final class FakeSender: VoiceSending, @unchecked Sendable {
        var uploads: [Data] = []
        var uploadError: Error?
        var transcriptText: String? = "Merge it."
        var voiceNotes: [(ref: String, size: Int, target: VoiceModeEngine.SendTarget)] = []
        var sendError: Error?
        var itemActions: [(String, String)] = []
        var promptReplies: [(String, Int64, String?, String?)] = []
        func upload(_ audio: Data) async throws -> String {
            if let uploadError { throw uploadError }
            uploads.append(audio)
            return "m-\(uploads.count)"
        }
        func transcript(blobRef: String, waitSeconds: Int) async -> String? { transcriptText }
        func sendVoiceNote(blobRef: String, size: Int, to target: VoiceModeEngine.SendTarget) async throws {
            if let sendError { throw sendError }
            voiceNotes.append((blobRef, size, target))
        }
        func sendItemAction(itemID: String, label: String) async { itemActions.append((itemID, label)) }
        func sendPromptReply(convoID: String, seq: Int64, choice: String?, text: String?) async throws {
            if let sendError { throw sendError }
            promptReplies.append((convoID, seq, choice, text))
        }
    }

    final class FakeFeed: VoiceFeeding {
        let events: AsyncStream<VoiceModeEngine.Event>
        let continuation: AsyncStream<VoiceModeEngine.Event>.Continuation
        var watched: [String] = []
        var stopped = false
        init() { (events, continuation) = AsyncStream.makeStream(of: VoiceModeEngine.Event.self) }
        func watch(convoID: String) { watched.append(convoID) }
        func stop() { stopped = true }
    }

    struct Offline: Error {}

    var capture: FakeCapture!
    var audio: FakeAudio!
    var player: FakePlayer!
    var sender: FakeSender!
    var feed: FakeFeed!
    var settings: VoiceSettings!
    var awake: [Bool] = []
    var defaultsName: String!

    override func setUp() async throws {
        capture = FakeCapture(); audio = FakeAudio(); player = FakePlayer(); sender = FakeSender(); feed = FakeFeed()
        defaultsName = "voice-runner-\(UUID().uuidString)"
        settings = VoiceSettings(defaults: UserDefaults(suiteName: defaultsName)!)
        awake = []
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    /// Timers never fire by themselves in these tests: the test sends
    /// `timerFired` when it wants one to.
    func makeRunner() -> VoiceModeRunner {
        VoiceModeRunner(capture: capture, audio: audio, player: player, sender: sender, feed: feed, settings: settings,
                        setScreenAwake: { [weak self] in self?.awake.append($0) },
                        sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
    }

    func recordingFile(_ contents: String = "aac-bytes") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try! Data(contents.utf8).write(to: url)
        return url
    }

    /// Lets queued effects and their follow-on tasks run.
    func drain(_ runner: VoiceModeRunner) async {
        for _ in 0..<5 {
            await runner.settle()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStartOpensTheMicrophoneInOrderAndWatchesTheConversation() async {
        settings.talkOver = false
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "Auth refactor", boxName: "bev"))
        await drain(runner)
        XCTAssertEqual(runner.state.phase, .listening)
        XCTAssertEqual(runner.state.route, "Speaker")
        XCTAssertFalse(runner.state.config.talkOver, "the settings reach the engine")
        XCTAssertEqual(audio.log, ["activate"])
        XCTAssertEqual(capture.log, ["start record"])
        XCTAssertEqual(player.earcons, [.micOpen])
        XCTAssertEqual(feed.watched, ["c1"])
        XCTAssertEqual(awake, [true])
    }

    func testAnUtteranceIsUploadedTranscribedAndSentAsAVoiceNote() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        let file = recordingFile()
        capture.fileToReturn = file
        capture.continuation.yield(.speechStarted)
        capture.continuation.yield(.words("merge it"))
        capture.continuation.yield(.speechEnded)
        await drain(runner)
        runner.send(.timerFired(.silence))
        await drain(runner)
        XCTAssertEqual(sender.uploads, [Data("aac-bytes".utf8)])
        XCTAssertEqual(sender.voiceNotes.map(\.ref), ["m-1"])
        XCTAssertEqual(sender.voiceNotes.first?.size, 9)
        XCTAssertEqual(sender.voiceNotes.first?.target, .conversation("c1"))
        XCTAssertEqual(runner.state.phase, .waiting)
        XCTAssertEqual(audio.log, ["activate", "release"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "sent: the file is gone")
        XCTAssertEqual(player.earcons, [.micOpen, .sent])
    }

    func testAReplyFromTheFeedIsSpokenThenTheMicrophoneOpens() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        runner.send(.timerFired(.noSpeech))
        await drain(runner)
        feed.continuation.yield(.arrived(.reply(SpokenReply(convoID: "c1", seq: 9, short: "Done."), convoTitle: "T")))
        await drain(runner)
        XCTAssertEqual(player.spoken, ["Done."])
        XCTAssertEqual(runner.state.phase, .listening, "the clip finished, so it listens")
        XCTAssertEqual(capture.log.suffix(2), ["start monitor", "promote"])
    }

    func testStoppingAClipDoesNotReportItFinished() async {
        player.holds = true
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        runner.send(.timerFired(.noSpeech))
        runner.send(.arrived(.reply(SpokenReply(convoID: "c1", seq: 9, short: "A long reply."), convoTitle: "T")))
        await drain(runner)
        XCTAssertEqual(runner.state.phase, .speaking)
        runner.send(.tap)
        await drain(runner)
        XCTAssertEqual(player.stops, 1)
        XCTAssertEqual(runner.state.phase, .listening)
        XCTAssertNil(runner.state.playing)
    }

    func testDuckingReachesThePlayer() async {
        player.holds = true
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        runner.send(.timerFired(.noSpeech))
        runner.send(.arrived(.reply(SpokenReply(convoID: "c1", seq: 9, short: "A long reply."), convoTitle: "T")))
        runner.send(.speechStarted)
        runner.send(.timerFired(.talkOverOnset))
        runner.send(.timerFired(.talkOverWords))
        await drain(runner)
        XCTAssertEqual(player.ducks, [true, false])
    }

    func testOfflineKeepsTheNoteAndSendsItWhenTheConnectionReturns() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        let file = recordingFile()
        capture.fileToReturn = file
        sender.uploadError = Offline()
        runner.send(.words("merge it"))
        runner.send(.timerFired(.silence))
        await drain(runner)
        XCTAssertEqual(player.spoken, ["No connection. I'll send it when you're back online."])
        XCTAssertEqual(player.earcons, [.micOpen, .error])
        XCTAssertEqual(runner.unsentCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "kept for the retry")
        sender.uploadError = nil
        runner.connectionRestored()
        await drain(runner)
        XCTAssertEqual(sender.voiceNotes.map(\.target), [.conversation("c1")])
        XCTAssertEqual(runner.unsentCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Uploaded, then the socket dropped before the send: the engine is
    /// told, and the note still goes later.
    func testASendThatFailsAfterTheUploadIsAnnouncedAndRetried() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        capture.fileToReturn = recordingFile()
        sender.sendError = Offline()
        runner.send(.words("merge it"))
        runner.send(.timerFired(.silence))
        await drain(runner)
        XCTAssertEqual(runner.unsentCount, 1)
        XCTAssertEqual(player.spoken, ["No connection. That wasn't sent."])
        sender.sendError = nil
        runner.connectionRestored()
        await drain(runner)
        XCTAssertEqual(sender.voiceNotes.count, 1)
        XCTAssertEqual(sender.uploads.count, 1, "not uploaded twice")
    }

    func testAnItemActionGoesThroughTheSenderAndTheRecordingIsDropped() async {
        let runner = makeRunner()
        let item = VoiceEntry.item(VoiceItem(id: "it_1", kind: .decision, convoID: "c2", title: "Ship it", labels: ["Go", "Wait"]),
                                   convoTitle: "Promo")
        runner.start(.queue(entries: [item], lastConvoID: "c1", lastTitle: "T", lastBoxName: nil))
        await drain(runner)
        XCTAssertEqual(player.spoken, ["One thing needs you. A decision: Ship it. Options: Go, Wait."])
        let file = recordingFile()
        capture.fileToReturn = file
        sender.transcriptText = "Go."
        runner.send(.words("go"))
        runner.send(.timerFired(.silence))
        await drain(runner)
        XCTAssertEqual(player.spoken.last, "Sending: Go.")
        XCTAssertEqual(runner.state.phase, .confirming)
        runner.send(.timerFired(.confirm))
        await drain(runner)
        XCTAssertEqual(sender.itemActions.map(\.1), ["Go"])
        XCTAssertTrue(sender.voiceNotes.isEmpty, "a button press: the recording is not posted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAFailedPromptReplyIsReported() async {
        let runner = makeRunner()
        let prompt = VoiceEntry.prompt(VoicePrompt(convoID: "c3", seq: 30, question: "Which?",
                                                   options: [.init(label: "A", value: "a"), .init(label: "B", value: "b")]),
                                       convoTitle: "Schema")
        runner.start(.queue(entries: [prompt], lastConvoID: nil, lastTitle: "", lastBoxName: nil))
        await drain(runner)
        sender.sendError = Offline()
        runner.send(.actionTapped("A"))
        await drain(runner)
        XCTAssertTrue(player.earcons.contains(.error))
    }

    func testAMicrophoneThatWillNotStartIsReported() async {
        capture.startError = Offline()
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        await drain(runner)
        XCTAssertEqual(player.spoken, ["I can't use the microphone."])
    }

    func testAudioEventsReachTheEngine() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        audio.continuation.yield(.routeChanged("AirPods Pro"))
        audio.continuation.yield(.interruption(.began))
        await drain(runner)
        XCTAssertEqual(runner.state.route, "AirPods Pro")
        XCTAssertTrue(runner.state.paused)
    }

    func testEndingTearsDownAndTellsTheHost() async {
        let runner = makeRunner()
        var ended: VoiceModeEngine.EndReason?
        runner.onEnded = { ended = $0 }
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        runner.send(.end)
        await drain(runner)
        XCTAssertEqual(ended, .user)
        XCTAssertTrue(feed.stopped)
        XCTAssertEqual(awake, [true, false])
        XCTAssertEqual(capture.log, ["start record", "stop keep=false"])
        XCTAssertEqual(audio.log, ["activate", "release"])
        XCTAssertEqual(runner.state.phase, .idle)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceModeRunnerTests'`
Expected: build FAILS — `cannot find 'VoiceModeRunner' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/Voice/VoiceModeRunner.swift`:

```swift
import Foundation
import Observation
import os

/// Carries out the engine's effects and feeds what they produce back in
/// (spec 2026-10-03 §3). The one object a screen, the Mac's stage or a
/// CarPlay scene holds: read `state`, call `send`.
@MainActor
@Observable
public final class VoiceModeRunner {
    public private(set) var state = VoiceModeEngine.State()
    /// Called once when voice mode has ended, by the user or by itself.
    @ObservationIgnored public var onEnded: ((VoiceModeEngine.EndReason) -> Void)?

    @ObservationIgnored private let capture: any VoiceCapturing
    @ObservationIgnored private let audio: any VoiceAudioControlling
    @ObservationIgnored private let player: any SpeechPlaying
    @ObservationIgnored private let sender: any VoiceSending
    @ObservationIgnored private let feed: any VoiceFeeding
    @ObservationIgnored private let settings: VoiceSettings
    @ObservationIgnored private let setScreenAwake: (Bool) -> Void
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void

    @ObservationIgnored private var timers: [VoiceModeEngine.TimerID: Task<Void, Never>] = [:]
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    /// Effects run one after another in the order the engine gave them.
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?

    /// The utterance last kept: its file, and its blob once uploaded.
    private struct Recording {
        let id: Int
        let url: URL
        var blob: (ref: String, size: Int)?
    }
    @ObservationIgnored private var recording: Recording?
    @ObservationIgnored private var nextRecordingID = 1
    /// Notes that could not leave (offline), kept until they do.
    @ObservationIgnored private var unsent: [(recording: Recording, target: VoiceModeEngine.SendTarget)] = []

    private static let logger = Logger(subsystem: "chat.matron", category: "voice-runner")

    public init(capture: any VoiceCapturing, audio: any VoiceAudioControlling, player: any SpeechPlaying,
                sender: any VoiceSending, feed: any VoiceFeeding, settings: VoiceSettings,
                setScreenAwake: @escaping (Bool) -> Void = { _ in },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.capture = capture
        self.audio = audio
        self.player = player
        self.sender = sender
        self.feed = feed
        self.settings = settings
        self.setScreenAwake = setScreenAwake
        self.sleep = sleep
    }

    // MARK: In

    public func start(_ start: VoiceModeEngine.Start) {
        guard state.phase == .idle else { return }
        subscribe()
        send(.configChanged(settings.engineConfig(state.config)))
        send(.routeChanged(audio.routeName))
        send(.start(start))
    }

    /// The settings screen changed something while voice mode is on.
    public func settingsChanged() {
        send(.configChanged(settings.engineConfig(state.config)))
    }

    /// The connection is back: notes kept while offline go now.
    public func connectionRestored() {
        let waiting = unsent
        unsent = []
        for entry in waiting { deliver(entry.recording, to: entry.target, announceFailure: false) }
    }

    public func send(_ event: VoiceModeEngine.Event) {
        let (next, effects) = VoiceModeEngine.reduce(state, event)
        if next != state { state = next }
        for effect in effects { perform(effect) }
    }

    private func subscribe() {
        guard listeners.isEmpty else { return }
        let captureEvents = capture.events
        listeners.append(Task { [weak self] in
            for await event in captureEvents {
                switch event {
                case .speechStarted: self?.send(.speechStarted)
                case .speechEnded: self?.send(.speechEnded)
                case .words(let text): self?.send(.words(text))
                case .failed: self?.send(.captureFailed)
                }
            }
        })
        for stream in [audio.events, feed.events] {
            listeners.append(Task { [weak self] in
                for await event in stream { self?.send(event) }
            })
        }
    }

    // MARK: Out

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// For tests: every queued effect has been carried out.
    func settle() async {
        await chain?.value
    }

    private func perform(_ effect: VoiceModeEngine.Effect) {
        switch effect {
        case .startTimer(let id, let interval):
            timers[id]?.cancel()
            let sleep = self.sleep
            timers[id] = Task { [weak self] in
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled else { return }
                self?.send(.timerFired(id))
            }
        case .cancelTimer(let id):
            timers[id]?.cancel()
            timers[id] = nil
        case .watch(let convoID):
            feed.watch(convoID: convoID)
        case .keepScreenAwake(let awake):
            setScreenAwake(awake)
        case .duck:
            player.setDucked(true)
        case .restoreVolume:
            player.setDucked(false)
        case .stopPlayback:
            playTask?.cancel()
            playTask = nil
            player.stop()
        case .earcon(let earcon):
            enqueue { [player] in player.play(earcon) }
        case .activateAudio:
            enqueue { [weak self] in
                guard let self else { return }
                do {
                    try self.audio.activate()
                } catch {
                    Self.logger.error("activate: \(error.localizedDescription, privacy: .public)")
                    self.send(.captureFailed)
                }
            }
        case .releaseAudio:
            enqueue { [audio] in audio.release() }
        case .startCapture(let mode):
            enqueue { [weak self] in
                guard let self else { return }
                do {
                    try await self.capture.start(mode)
                } catch {
                    Self.logger.error("capture: \(error.localizedDescription, privacy: .public)")
                    self.send(.captureFailed)
                }
            }
        case .promoteCapture:
            enqueue { [capture] in capture.promote() }
        case .stopCapture(let keep):
            enqueue { [weak self] in
                guard let self else { return }
                let url = await self.capture.stop(keep: keep)
                guard keep, let url else { return }
                self.replaceRecording(with: url)
            }
        case .play(let utterance):
            enqueue { [weak self] in
                guard let self else { return }
                self.playTask = Task { [weak self] in
                    guard let self else { return }
                    let source = await self.player.speak(utterance.text)
                    guard source != .stopped, !Task.isCancelled else { return }
                    self.send(.playbackFinished(utterance.id))
                }
            }
        case .upload:
            enqueue { [weak self] in self?.upload() }
        case .sendVoiceNote(let target):
            enqueue { [weak self] in
                guard let self, let recording = self.recording else { return }
                self.recording = nil
                self.deliver(recording, to: target, announceFailure: recording.blob != nil)
            }
        case .discardRecording:
            enqueue { [weak self] in
                guard let self, let recording = self.recording else { return }
                self.recording = nil
                try? FileManager.default.removeItem(at: recording.url)
            }
        case .sendItemAction(let itemID, let label):
            Task { [sender] in await sender.sendItemAction(itemID: itemID, label: label) }
        case .sendPromptReply(let convoID, let seq, let choice, let text):
            Task { [weak self, sender] in
                do {
                    try await sender.sendPromptReply(convoID: convoID, seq: seq, choice: choice, text: text)
                } catch {
                    self?.send(.sendFailed)
                }
            }
        case .ended(let reason):
            enqueue { [weak self] in self?.finish(reason) }
        }
    }

    private func replaceRecording(with url: URL) {
        if let old = recording { try? FileManager.default.removeItem(at: old.url) }
        recording = Recording(id: nextRecordingID, url: url, blob: nil)
        nextRecordingID += 1
    }

    /// Uploads the current recording and asks for its words. The answer is
    /// dropped if the recording was discarded or replaced meanwhile.
    private func upload() {
        guard let recording else {
            send(.uploadFailed)
            return
        }
        let wait = Int(state.config.transcriptTimeout.rounded(.up))
        Task { [weak self, sender] in
            do {
                let data = try Data(contentsOf: recording.url)
                let ref = try await sender.upload(data)
                guard let self, self.recording?.id == recording.id else { return }
                self.recording?.blob = (ref, data.count)
                let words = await sender.transcript(blobRef: ref, waitSeconds: wait)
                guard self.recording?.id == recording.id else { return }
                self.send(.transcript(words))
            } catch {
                guard let self, self.recording?.id == recording.id else { return }
                self.send(.uploadFailed)
            }
        }
    }

    /// Sends a kept note, uploading it first when that has not happened.
    /// Offline, it is kept and goes when the connection is back; the
    /// engine is told (`sendFailed`) only when it does not already know.
    private func deliver(_ recording: Recording, to target: VoiceModeEngine.SendTarget, announceFailure: Bool) {
        Task { [weak self, sender] in
            var recording = recording
            do {
                if recording.blob == nil {
                    let data = try Data(contentsOf: recording.url)
                    recording.blob = (try await sender.upload(data), data.count)
                }
                guard let blob = recording.blob else { return }
                try await sender.sendVoiceNote(blobRef: blob.ref, size: blob.size, to: target)
                try? FileManager.default.removeItem(at: recording.url)
            } catch {
                guard let self else { return }
                self.unsent.append((recording, target))
                if announceFailure { self.send(.sendFailed) }
            }
        }
    }

    private func finish(_ reason: VoiceModeEngine.EndReason) {
        for task in timers.values { task.cancel() }
        timers = [:]
        for task in listeners { task.cancel() }
        listeners = []
        playTask?.cancel()
        playTask = nil
        feed.stop()
        onEnded?(reason)
    }

    /// Notes still waiting for a connection, for the host to show.
    public var unsentCount: Int { unsent.count }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd MatronShared && swift test --filter 'VoiceTests.VoiceModeRunnerTests'`
Expected: `Executed 12 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Voice/VoiceModeRunner.swift MatronShared/Tests/VoiceTests/VoiceModeRunnerTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: the runner carries out the engine's effects" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 19: `VoiceModeScreen` — the screen as a plain view

**Files:**
- Create: `MatronShared/Sources/DesignSystem/Voice/VoiceModeScreen.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/VoiceModeScreenSnapshotTests.swift` (new)

**Interfaces:**
- Produces (MatronDesignSystem): `VoiceModeScreen(model:onTap:onSend:onAction:onEnd:)` with `Model { title, boxName, phase: Phase{listening, sending, working, waiting, speaking, confirming}, caption, labels, unsentCount }`; `maxButtons` (4); static `stateText`, `symbol`, `tint`, `tapHint`, `unsentText`.
- The view knows nothing of the engine (the design system does not import `MatronVoice`); Task 20 maps engine state onto the model. The Mac's stage can host it later.
- Spec §6: the conversation's name and box, a large state indicator, the line being spoken as a caption, up to four buttons for the current thing's labels, and End; a tap anywhere else interrupts.

- [ ] **Step 1: Write the failing tests**

Create `MatronShared/Tests/DesignSystemSnapshotTests/VoiceModeScreenSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import MatronDesignSystem

final class VoiceModeScreenSnapshotTests: XCTestCase {
    private func screen(_ model: VoiceModeScreen.Model) -> some View {
        VoiceModeScreen(model: model, onTap: {}, onSend: {}, onAction: { _ in }, onEnd: {})
            .frame(width: 390, height: 760)
    }

    // MARK: Pure

    func testStateWords() {
        XCTAssertEqual(VoiceModeScreen.stateText(.listening, boxName: "bev"), "Listening")
        XCTAssertEqual(VoiceModeScreen.stateText(.working, boxName: "bev"), "bev is working")
        XCTAssertEqual(VoiceModeScreen.stateText(.working, boxName: nil), "The agent is working")
        XCTAssertEqual(VoiceModeScreen.stateText(.waiting, boxName: "bev"), "Tap to talk")
        XCTAssertEqual(VoiceModeScreen.stateText(.confirming, boxName: nil), "Say cancel to stop")
        XCTAssertEqual(VoiceModeScreen.tapHint(.speaking), "Interrupt")
        XCTAssertEqual(VoiceModeScreen.tapHint(.waiting), "Talk")
        XCTAssertEqual(VoiceModeScreen.unsentText(1), "1 voice note waiting for a connection")
        XCTAssertEqual(VoiceModeScreen.unsentText(3), "3 voice notes waiting for a connection")
    }

    func testEveryPhaseHasItsOwnSymbol() {
        let phases: [VoiceModeScreen.Model.Phase] = [.listening, .sending, .working, .waiting, .speaking, .confirming]
        XCTAssertEqual(Set(phases.map(VoiceModeScreen.symbol)).count, phases.count)
    }

    func testButtonsCallBack() {
        var log: [String] = []
        let view = VoiceModeScreen(model: .init(title: "T", phase: .listening, labels: ["Go"]),
                                   onTap: { log.append("tap") }, onSend: { log.append("send") },
                                   onAction: { log.append($0) }, onEnd: { log.append("end") })
        view.onTap(); view.onSend(); view.onAction("Go"); view.onEnd()
        XCTAssertEqual(log, ["tap", "send", "Go", "end"])
    }

    // MARK: Snapshots

    func testListening() {
        assertVariants(of: screen(.init(title: "Auth refactor", boxName: "bev", phase: .listening)), named: "voice-listening")
    }

    func testSpeakingWithCaption() {
        assertVariants(of: screen(.init(title: "Auth refactor", boxName: "bev", phase: .speaking,
                                        caption: "The deploy finished. Shall I merge? Say more for the detail.")),
                       named: "voice-speaking")
    }

    func testAnItemWithTwoLabels() {
        assertVariants(of: screen(.init(title: "Promo", boxName: "pat", phase: .listening,
                                        caption: "A decision: Ship the promo page. Options: Go, Wait.",
                                        labels: ["Go", "Wait"])),
                       named: "voice-item-two-labels")
    }

    /// Five labels: four buttons; the fifth is spoken only.
    func testAtMostFourLabelButtons() {
        assertVariants(of: screen(.init(title: "Schema", phase: .waiting,
                                        labels: ["Postgres", "SQLite", "MySQL", "DynamoDB", "None of them"])),
                       named: "voice-four-buttons")
    }

    func testWorkingWithUnsentNotes() {
        assertVariants(of: screen(.init(title: "Auth refactor", boxName: "bev", phase: .working, unsentCount: 2)),
                       named: "voice-working-unsent")
    }

    func testConfirming() {
        assertVariants(of: screen(.init(title: "Promo", boxName: "pat", phase: .confirming, caption: "Sending: Go.",
                                        labels: ["Go", "Wait"])),
                       named: "voice-confirming")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter 'DesignSystemSnapshotTests.VoiceModeScreenSnapshotTests'`
Expected: build FAILS — `cannot find 'VoiceModeScreen' in scope`.

- [ ] **Step 3: Implement**

Create `MatronShared/Sources/DesignSystem/Voice/VoiceModeScreen.swift`:

```swift
import SwiftUI

/// The iPhone's voice-mode screen (spec 2026-10-03 §6): the conversation's
/// name and box, one large state indicator, the line being spoken as a
/// caption, up to four buttons for the current thing's labels, and End.
/// A tap anywhere else interrupts.
///
/// A plain view over a plain model: it knows nothing of the engine, so the
/// Mac's stage can reuse it and snapshots need no audio.
public struct VoiceModeScreen: View {
    public struct Model: Equatable {
        public enum Phase: Equatable {
            case listening
            case sending
            /// Nothing to say and the agent is busy.
            case working
            /// Nothing to say and nobody talking: a tap opens the microphone.
            case waiting
            case speaking
            /// "Sending: Go" has been said; "cancel" stops it.
            case confirming
        }

        public var title: String
        public var boxName: String?
        public var phase: Phase
        public var caption: String?
        public var labels: [String]
        /// Voice notes kept until the connection is back.
        public var unsentCount: Int

        public init(title: String, boxName: String? = nil, phase: Phase, caption: String? = nil,
                    labels: [String] = [], unsentCount: Int = 0) {
            self.title = title; self.boxName = boxName; self.phase = phase; self.caption = caption
            self.labels = labels; self.unsentCount = unsentCount
        }
    }

    /// At most this many label buttons are drawn; the rest are spoken only.
    public static let maxButtons = 4

    let model: Model
    let onTap: () -> Void
    let onSend: () -> Void
    let onAction: (String) -> Void
    let onEnd: () -> Void

    public init(model: Model, onTap: @escaping () -> Void, onSend: @escaping () -> Void,
                onAction: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
        self.model = model
        self.onTap = onTap
        self.onSend = onSend
        self.onAction = onAction
        self.onEnd = onEnd
    }

    public var body: some View {
        VStack(spacing: 24) {
            header
            Spacer(minLength: 0)
            indicator
            caption
            Spacer(minLength: 0)
            actions
            controls
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityAction(named: Text(Self.tapHint(model.phase)), onTap)
    }

    // MARK: Parts

    private var header: some View {
        VStack(spacing: 4) {
            Text(model.title.isEmpty ? "Voice mode" : model.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let box = model.boxName, !box.isEmpty {
                Text(box)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if model.unsentCount > 0 {
                Text(Self.unsentText(model.unsentCount))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var indicator: some View {
        VStack(spacing: 16) {
            Image(systemName: Self.symbol(model.phase))
                .font(.system(size: 72, weight: .regular))
                .foregroundStyle(Self.tint(model.phase))
                .frame(width: 168, height: 168)
                .background(Circle().fill(Self.tint(model.phase).opacity(0.14)))
            Text(Self.stateText(model.phase, boxName: model.boxName))
                .font(.title2.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var caption: some View {
        if let caption = model.caption, !caption.isEmpty {
            Text(caption)
                .font(.title3)
                .multilineTextAlignment(.center)
                .lineLimit(8)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var actions: some View {
        let labels = Array(model.labels.prefix(Self.maxButtons))
        if !labels.isEmpty {
            VStack(spacing: 10) {
                ForEach(labels, id: \.self) { label in
                    Button { onAction(label) } label: {
                        Text(label)
                            .font(.headline)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            if model.phase == .listening {
                Button(action: onSend) {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
            }
            Button(role: .destructive, action: onEnd) {
                Label("End", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Words and symbols (static, so tests pin them)

    static func stateText(_ phase: Model.Phase, boxName: String?) -> String {
        switch phase {
        case .listening: return "Listening"
        case .sending: return "Sending"
        case .working: return "\(boxName ?? "The agent") is working"
        case .waiting: return "Tap to talk"
        case .speaking: return "Speaking"
        case .confirming: return "Say cancel to stop"
        }
    }

    static func symbol(_ phase: Model.Phase) -> String {
        switch phase {
        case .listening: return "mic.fill"
        case .sending: return "arrow.up"
        case .working: return "ellipsis"
        case .waiting: return "hand.tap.fill"
        case .speaking: return "waveform"
        case .confirming: return "checkmark"
        }
    }

    static func tint(_ phase: Model.Phase) -> Color {
        switch phase {
        case .listening: return .red
        case .sending, .confirming: return .blue
        case .working, .waiting: return .secondary
        case .speaking: return .green
        }
    }

    static func tapHint(_ phase: Model.Phase) -> String {
        switch phase {
        case .speaking: return "Interrupt"
        case .waiting, .working: return "Talk"
        case .confirming: return "Cancel"
        case .listening, .sending: return "Voice mode"
        }
    }

    static func unsentText(_ count: Int) -> String {
        count == 1 ? "1 voice note waiting for a connection" : "\(count) voice notes waiting for a connection"
    }
}
```

- [ ] **Step 4: Run the logic tests, then record the snapshots**

Run: `cd MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter 'DesignSystemSnapshotTests.VoiceModeScreenSnapshotTests'`
Expected: `Executed 9 tests, with 0 failures`.
Run twice: `cd MatronShared && swift test --filter 'DesignSystemSnapshotTests.VoiceModeScreenSnapshotTests'`
Expected: the first run records the six snapshot pairs under `Tests/DesignSystemSnapshotTests/__Snapshots__/VoiceModeScreenSnapshotTests/` and fails; the second passes with `Executed 9 tests, with 0 failures`. Open the PNGs and look: the indicator is centred, the caption wraps, five labels draw four buttons, light and dark differ.
Run: `xcodegen generate && git checkout Matron/App/Info.plist` (the new PNGs are project members).

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/Voice MatronShared/Tests/DesignSystemSnapshotTests/VoiceModeScreenSnapshotTests.swift \
        MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/VoiceModeScreenSnapshotTests
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: the voice-mode screen as a plain view over a plain model" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 20: iPhone voice mode — the host, and its two entry points

**Files:**
- Create: `Matron/Features/Voice/VoiceModeEntry.swift`, `VoiceTextMaker+Cleaner.swift`, `VoiceModeHost.swift`
- Modify: `MatronShared/Sources/ViewModels/VoiceNoteSession.swift` (lines 53–63, 65, 126)
- Modify: `Matron/App/AppDependencies.swift` (beside `speechSynthesiser(for:)`)
- Modify: `Matron/App/AppShellNavigation.swift` (lines 62–64)
- Modify: `Matron/App/AppShellView.swift` (after `.environment(voiceSettings)`; before `coordinatorHasUnread` at line 203; the Decisions root at line 292)
- Modify: `Matron/Features/ChatList/ChatListView.swift` (the toolbar, after the New chat item at lines 117–120)
- Modify: `Matron/Features/Chat/ChatView.swift` (line 46; the toolbar at line 705–711; before `findInChat` at line 119)
- Test: `MatronTests/VoiceModeTests.swift` (new), `MatronShared/Tests/ViewModelTests/VoiceNoteSessionTests.swift`

**Interfaces:**
- Produces:
  - `enum VoiceModeEntry: Identifiable { conversation(id:title:boxName:), queue }`; `VoiceModeAvailability.isSupported`; `EnvironmentValues.openVoiceMode: ((VoiceModeEntry) -> Void)?`; `VoiceModeQueueButton: ToolbarContent`.
  - `AppShellNavigation.voiceMode: VoiceModeEntry?`, `openVoiceMode(_:)`, `closeVoiceMode()`.
  - `VoiceModeScreenMapping.model(_:unsentCount:)`; `@available(iOS 26, *) VoiceModeSession`, `VoiceModeHost`; `VoiceModeCover` (ungated wrapper).
  - `AppDependencies.voiceSender(for:) -> JournalVoiceSender`; `VoiceTextMaker.cleaner`.
  - `ChatView.showsVoiceModeTool(canOpen:page:)`.
  - `VoiceNoteSession.isVoiceModeOn`, `SessionError.voiceModeOn`.
- Entry points (spec §6): a `waveform` button in the conversation toolbar (voice mode talks to that conversation) and one on the Conversations and Decisions roots (voice mode opens on the queue). Both go through `openVoiceMode` to ONE `fullScreenCover` on the shell. The buttons are absent below iOS 26 and on a device with no recogniser.
- Scope (spec §6): voice mode works while the app is in front. `scenePhase == .background` sends `appBackgrounded` (pause); `.active` sends `appForegrounded` (what landed meanwhile is said). The screen stays awake (`keepScreenAwake` → `isIdleTimerDisabled`).

- [ ] **Step 1: Write the failing tests**

Create `MatronTests/VoiceModeTests.swift`:

```swift
import XCTest
import MatronDesignSystem
import MatronVoice
@testable import Matron

/// Voice mode on the iPhone (spec 2026-10-03 §6): the rules the shell and
/// the chat toolbar follow, and how engine state reaches the screen.
@MainActor
final class VoiceModeTests: XCTestCase {
    // MARK: Entry points

    func test_openVoiceMode_setsTheEntry_andASecondOpenIsIgnored() {
        let nav = AppShellNavigation()
        XCTAssertNil(nav.voiceMode)
        nav.openVoiceMode(.queue)
        XCTAssertEqual(nav.voiceMode, .queue)
        nav.openVoiceMode(.conversation(id: "c1", title: "Auth refactor", boxName: "bev"))
        XCTAssertEqual(nav.voiceMode, .queue, "one sitting at a time")
        nav.closeVoiceMode()
        XCTAssertNil(nav.voiceMode)
    }

    func test_openingVoiceMode_leavesTabsAndStacksAlone() {
        let nav = AppShellNavigation()
        nav.tab = .decisions
        nav.chatPath = ["c1"]
        nav.openVoiceMode(.conversation(id: "c1", title: "T", boxName: nil))
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertEqual(nav.chatPath, ["c1"])
    }

    func test_entryIdentity() {
        XCTAssertEqual(VoiceModeEntry.queue.id, "queue")
        XCTAssertEqual(VoiceModeEntry.conversation(id: "c1", title: "T", boxName: nil).id, "conversation:c1")
    }

    func test_theChatToolbarOffersVoiceModeOnlyOnTheChatPage_andOnlyWhereItCanRun() {
        XCTAssertTrue(ChatView.showsVoiceModeTool(canOpen: true, page: .chat))
        XCTAssertFalse(ChatView.showsVoiceModeTool(canOpen: true, page: .tasks))
        XCTAssertFalse(ChatView.showsVoiceModeTool(canOpen: false, page: .chat))
    }

    // MARK: Screen mapping

    func test_engineStateMapsOntoTheScreen() {
        var state = VoiceModeEngine.State()
        state.convoTitle = "Auth refactor"
        state.boxName = "bev"
        state.convoID = "c1"
        state.phase = .waiting
        XCTAssertEqual(VoiceModeScreenMapping.model(state, unsentCount: 0),
                       VoiceModeScreen.Model(title: "Auth refactor", boxName: "bev", phase: .waiting))
        state.working = ["c1"]
        XCTAssertEqual(VoiceModeScreenMapping.model(state, unsentCount: 2).phase, .working)
        XCTAssertEqual(VoiceModeScreenMapping.model(state, unsentCount: 2).unsentCount, 2)
        state.phase = .speaking
        state.caption = "Sending: Go."
        state.current = .item(VoiceItem(id: "it_1", kind: .decision, convoID: "c2", title: "Ship it", labels: ["Go", "Wait"]),
                              convoTitle: "Promo", boxName: "pat")
        let model = VoiceModeScreenMapping.model(state, unsentCount: 0)
        XCTAssertEqual(model.phase, .speaking)
        XCTAssertEqual(model.title, "Promo", "the thing being read names its own conversation")
        XCTAssertEqual(model.boxName, "pat")
        XCTAssertEqual(model.labels, ["Go", "Wait"])
        XCTAssertEqual(model.caption, "Sending: Go.")
        for (phase, expected) in [(VoiceModeEngine.Phase.listening, VoiceModeScreen.Model.Phase.listening),
                                  (.sending, .sending), (.confirming, .confirming)] {
            state.phase = phase
            XCTAssertEqual(VoiceModeScreenMapping.model(state, unsentCount: 0).phase, expected)
        }
    }
}
```

Append to `VoiceNoteSessionTests` (before its closing brace):

```swift
    /// Voice mode holds the microphone (spec 2026-10-03 §3): no ordinary
    /// note can start until it ends.
    func testANoteCannotStartWhileVoiceModeIsOn() async throws {
        let session = makeSession()
        session.isVoiceModeOn = true
        do {
            try await session.start(chatA) { _, _ in nil }
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? VoiceNoteSession.SessionError, .voiceModeOn)
            XCTAssertEqual(error.localizedDescription, "Voice mode is on. End it to record a voice note.")
        }
        XCTAssertFalse(session.isRecording)
        session.isVoiceModeOn = false
        try await session.start(chatA) { _, _ in nil }
        XCTAssertTrue(session.isRecording(for: chatA.kind))
        session.cancel()
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd MatronShared && swift test --filter 'ViewModelTests.VoiceNoteSessionTests'`
Expected: build FAILS — `value of type 'VoiceNoteSession' has no member 'isVoiceModeOn'`.

- [ ] **Step 3: One microphone — gate the ordinary voice note**

In `VoiceNoteSession.swift`, replace the `SessionError` enum's body:

```swift
        /// A note for another place is already recording.
        case busyElsewhere(title: String)
        /// Voice mode holds the microphone (spec 2026-10-03 §3, "Audio
        /// session").
        case voiceModeOn

        public var errorDescription: String? {
            switch self {
            case .busyElsewhere(let title):
                return "Already recording a voice note for \u{201C}\(title)\u{201D}. Send or cancel it first."
            case .voiceModeOn:
                return "Voice mode is on. End it to record a voice note."
            }
        }
```

after `public let recorder: VoiceRecorder`:

```swift

    /// Set while voice mode is on: it holds the microphone, so an ordinary
    /// note cannot start until it ends.
    public var isVoiceModeOn = false
```

and as the first line of `start(_:deliver:)`:

```swift
        guard !isVoiceModeOn else { throw SessionError.voiceModeOn }
```

Run: `cd MatronShared && swift test --filter 'ViewModelTests.VoiceNoteSessionTests'`
Expected: `Executed 18 tests, with 0 failures`.

- [ ] **Step 4: The entry, the availability check and the button**

Create `Matron/Features/Voice/VoiceModeEntry.swift`:

```swift
import SwiftUI
import MatronVoice

/// How voice mode was opened (spec 2026-10-03 §5): from inside a
/// conversation it talks to that conversation; from anywhere else it
/// opens on what needs the user.
enum VoiceModeEntry: Equatable, Identifiable {
    case conversation(id: String, title: String, boxName: String?)
    case queue

    var id: String {
        switch self {
        case .conversation(let id, _, _): return "conversation:\(id)"
        case .queue: return "queue"
        }
    }
}

enum VoiceModeAvailability {
    /// Voice mode needs iOS 26 (the on-device speech APIs) and a device
    /// whose recogniser is available. Below that its buttons are hidden;
    /// the app's floor stays where it is.
    @MainActor static var isSupported: Bool {
        if #available(iOS 26, *) { return VoiceCapture.isSupported }
        return false
    }
}

/// The app shell's way in (spec §6, "Entry"): opens voice mode on what
/// needs the user. Draws nothing where voice mode cannot run.
struct VoiceModeQueueButton: ToolbarContent {
    @Environment(\.openVoiceMode) private var openVoiceMode

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if let openVoiceMode {
                Button { openVoiceMode(.queue) } label: { Image(systemName: "waveform") }
                    .accessibilityLabel("Voice mode")
                    .accessibilityIdentifier("voice-mode-queue")
            }
        }
    }
}

extension EnvironmentValues {
    /// Opens voice mode over the whole shell. Set by `AppShellView`; `nil`
    /// (previews, tests, an unsupported device) draws no button.
    @Entry var openVoiceMode: ((VoiceModeEntry) -> Void)? = nil
}
```

Create `Matron/Features/Voice/VoiceTextMaker+Cleaner.swift`:

```swift
import MatronDesignSystem
import MatronVoice

extension VoiceTextMaker {
    /// The app's Markdown cleaner, handed to the voice engine's feed (the
    /// engine's module never imports the renderers).
    static let cleaner = VoiceTextMaker(
        short: { SpeechCleaner.fallbackShort($0) },
        sections: { SpeechCleaner.sections($0) },
        plain: { SpeechCleaner.speakable($0) })
}
```

- [ ] **Step 5: The sender accessor and the navigation state**

In `Matron/App/AppDependencies.swift`, after `speechSynthesiser(for:)`:

```swift
    /// Voice mode's sends, on the same paths the composer and the item
    /// thread use.
    func voiceSender(for session: UserSession) -> JournalVoiceSender {
        let c = core(for: session)
        return JournalVoiceSender(api: c.api, engine: c.engine, items: c.items)
    }

```

In `Matron/App/AppShellNavigation.swift`, replace

```swift
    var missionsPath: [String] = []

    init() {}
```

with

```swift
    var missionsPath: [String] = []
    /// Voice mode, when it is on: a full-screen cover over the whole shell
    /// (spec 2026-10-03 §6). `nil` when it is off.
    var voiceMode: VoiceModeEntry?

    init() {}

    /// Opens voice mode. Ignored while it is already on: one sitting at a
    /// time, and a second entry point must not restart it.
    func openVoiceMode(_ entry: VoiceModeEntry) {
        guard voiceMode == nil else { return }
        voiceMode = entry
    }

    func closeVoiceMode() {
        voiceMode = nil
    }
```

- [ ] **Step 6: The host**

Create `Matron/Features/Voice/VoiceModeHost.swift`:

```swift
import SwiftUI
import UIKit
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronViewModels
import MatronVoice

/// Engine state as the screen draws it. Not availability-gated, so tests
/// and older systems can still compile against it.
enum VoiceModeScreenMapping {
    static func model(_ state: VoiceModeEngine.State, unsentCount: Int) -> VoiceModeScreen.Model {
        let phase: VoiceModeScreen.Model.Phase
        switch state.phase {
        case .idle, .waiting: phase = state.isAgentWorking ? .working : .waiting
        case .listening: phase = .listening
        case .sending: phase = .sending
        case .confirming: phase = .confirming
        case .speaking: phase = .speaking
        }
        return VoiceModeScreen.Model(title: state.title, boxName: state.current?.boxName ?? state.boxName, phase: phase,
                                     caption: state.caption, labels: state.labels, unsentCount: unsentCount)
    }
}

/// Everything one voice-mode sitting owns: the audio engine, the
/// microphone, the voice, the feed and the runner that ties them to the
/// engine. Built when the screen appears, torn down when it ends.
@available(iOS 26, *)
@MainActor
@Observable
final class VoiceModeSession {
    let runner: VoiceModeRunner
    @ObservationIgnored private let feed: JournalVoiceFeed
    @ObservationIgnored private let player: SpeechPlayer
    @ObservationIgnored private var connectionTask: Task<Void, Never>?

    init(entry: VoiceModeEntry, session: UserSession, deps: AppDependencies, settings: VoiceSettings) {
        let audio = VoiceAudioEngine()
        let scope: JournalVoiceFeed.Scope
        switch entry {
        case .conversation(let id, _, _): scope = .conversation(id)
        case .queue: scope = .everything
        }
        feed = JournalVoiceFeed(store: deps.journalStore(for: session), text: .cleaner, scope: scope)
        player = SpeechPlayer(synth: deps.speechSynthesiser(for: session), cache: .standard(), output: audio,
                              local: EngineLocalVoice(audio: audio), settings: settings)
        runner = VoiceModeRunner(
            capture: VoiceCapture(audio: audio), audio: VoiceAudioSession(engine: audio), player: player,
            sender: deps.voiceSender(for: session), feed: feed, settings: settings,
            setScreenAwake: { UIApplication.shared.isIdleTimerDisabled = $0 })
        // A note kept while offline goes as soon as the socket is back.
        let sync = deps.syncService(for: session)
        connectionTask = Task { [weak runner] in
            for await state in await sync.stateStream() {
                if case .running = state { runner?.connectionRestored() }
            }
        }
    }

    func start(_ entry: VoiceModeEntry) {
        Task { await player.refreshVoices() }
        switch entry {
        case .conversation(let id, let title, let boxName):
            runner.start(.conversation(id: id, title: title, boxName: boxName))
        case .queue:
            let entries = feed.initialQueue()
            let last = feed.lastConversation()
            runner.start(.queue(entries: entries, lastConvoID: last?.id, lastTitle: last?.title ?? "",
                                lastBoxName: last?.boxName))
        }
        feed.startWatchingNeeds()
    }

    func end() {
        runner.send(.end)
        connectionTask?.cancel()
        connectionTask = nil
    }
}

/// The full-screen voice mode (spec 2026-10-03 §6). Phase 1 works while
/// the app is in front: leaving it pauses, coming back says what landed.
@available(iOS 26, *)
struct VoiceModeHost: View {
    let entry: VoiceModeEntry
    let session: UserSession
    let deps: AppDependencies
    let settings: VoiceSettings
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(VoiceNoteSession.self) private var voiceNotes: VoiceNoteSession?
    @State private var voice: VoiceModeSession?

    var body: some View {
        content
            .statusBarHidden()
            .task { begin() }
            .onChange(of: scenePhase) { _, phase in
                // `.inactive` (Control Centre, a system prompt) is not leaving.
                if phase == .background { voice?.runner.send(.appBackgrounded) }
                if phase == .active { voice?.runner.send(.appForegrounded) }
            }
            .onChange(of: settings.talkOver) { _, _ in voice?.runner.settingsChanged() }
            .onChange(of: settings.offerMore) { _, _ in voice?.runner.settingsChanged() }
            .onDisappear {
                voice?.end()
                voiceNotes?.isVoiceModeOn = false
            }
    }

    @ViewBuilder private var content: some View {
        if let voice {
            VoiceModeScreen(
                model: VoiceModeScreenMapping.model(voice.runner.state, unsentCount: voice.runner.unsentCount),
                onTap: { voice.runner.send(.tap) },
                onSend: { voice.runner.send(.sendTapped) },
                onAction: { voice.runner.send(.actionTapped($0)) },
                onEnd: { voice.runner.send(.end) })
        } else {
            ProgressView()
        }
    }

    private func begin() {
        guard voice == nil else { return }
        // One microphone: an ordinary voice note in progress is dropped,
        // and none can start while voice mode is on.
        voiceNotes?.cancel()
        voiceNotes?.isVoiceModeOn = true
        let made = VoiceModeSession(entry: entry, session: session, deps: deps, settings: settings)
        made.runner.onEnded = { _ in onClose() }
        voice = made
        made.start(entry)
    }
}

/// The cover the shell presents. Its own view so the availability check
/// stays out of `AppShellView`'s body.
struct VoiceModeCover: View {
    let entry: VoiceModeEntry
    let session: UserSession
    let deps: AppDependencies
    let settings: VoiceSettings
    let onClose: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            VoiceModeHost(entry: entry, session: session, deps: deps, settings: settings, onClose: onClose)
        } else {
            ContentUnavailableView("Voice mode needs iOS 26", systemImage: "waveform")
                .onTapGesture(perform: onClose)
        }
    }
}
```

If Task 15 Step 10 chose a fallback: build the shell's settings as `VoiceSettings(talkOverDefault: false)` in Step 7 below (rows 2 and 3), and (row 3 only) change `let audio = VoiceAudioEngine()` above to `let audio = VoiceAudioEngine(voiceProcessing: false)` and delete the `Toggle("Talk over the agent", isOn: $settings.talkOver)` line from `VoiceSettingsSection`.

- [ ] **Step 7: Present it from the shell**

In `Matron/App/AppShellView.swift`, after `.environment(voiceSettings)`:

```swift
        .environment(\.openVoiceMode, voiceModeOpener)
        .fullScreenCover(item: $nav.voiceMode) { entry in
            VoiceModeCover(entry: entry, session: session, deps: deps, settings: voiceSettings,
                           onClose: { nav.closeVoiceMode() })
                .environment(voiceNotes)
        }
```

directly before `private var coordinatorHasUnread: Bool {` (a hoisted helper, for CI's type-checker budget):

```swift
    /// The voice-mode buttons' action, or `nil` (no buttons) where voice
    /// mode cannot run: below iOS 26, or with no on-device recogniser.
    private var voiceModeOpener: ((VoiceModeEntry) -> Void)? {
        guard VoiceModeAvailability.isSupported else { return nil }
        return { nav.openVoiceMode($0) }
    }

```

and in `decisionsTab`, after `.navigationTitle("Decisions")`:

```swift
            .toolbar { VoiceModeQueueButton() }
```

- [ ] **Step 8: The two buttons**

In `Matron/Features/ChatList/ChatListView.swift`, in the `.toolbar`, directly after the New chat `ToolbarItem`:

```swift
            // Voice mode on what needs you (spec 2026-10-03 §6).
            VoiceModeQueueButton()
```

In `Matron/Features/Chat/ChatView.swift`, after `@Environment(\.openProject) private var openProject`:

```swift
    /// Voice mode, talking to this conversation (spec 2026-10-03 §6).
    @Environment(\.openVoiceMode) private var openVoiceMode
```

in the `.toolbar`, between the Session info `ToolbarItem` and `coordinatorChatTools`:

```swift
            voiceModeTool
```

and directly before the doc comment `/// Opens the search bar from the ⓘ sheet.`:

```swift
    /// Whether the chat's toolbar offers voice mode: where it can run, and
    /// on the chat page only. Static so a test pins the rule.
    static func showsVoiceModeTool(canOpen: Bool, page: ChatPage) -> Bool {
        canOpen && page == .chat
    }

    /// The conversation toolbar's way into voice mode (spec 2026-10-03 §6).
    @ToolbarContentBuilder
    private var voiceModeTool: some ToolbarContent {
        if Self.showsVoiceModeTool(canOpen: openVoiceMode != nil, page: pager.page) {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openVoiceMode?(.conversation(id: viewModel.roomID, title: SessionTag.titleBesideRoomTag(chatTitle),
                                                 boxName: boxName))
                } label: {
                    Image(systemName: "waveform")
                }
                .accessibilityLabel("Voice mode")
                .accessibilityIdentifier("voice-mode-chat")
            }
        }
    }

```

- [ ] **Step 9: Run to verify**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`
Run: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath build/ios-test -only-testing:MatronTests/VoiceModeTests -only-testing:MatronTests/AppShellNavigationTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: `Executed 5 tests, with 0 failures` (`VoiceModeTests`), `Executed 27 tests, with 0 failures` (`AppShellNavigationTests`), and `** TEST SUCCEEDED **`.

- [ ] **Step 10: Look at it in the simulator**

Launch on the iPhone 17 simulator (iOS 26 or later). The `waveform` button is in the Conversations toolbar, the Decisions toolbar, and a conversation's toolbar (not on its Tasks page). Tapping it covers the screen with the voice screen: the title, a red microphone and "Listening" (the simulator asks for the microphone once). End closes it. From Conversations, with nothing pending, it says "Nothing needs you." (in the on-device voice against a journal without `/tts`) and listens. The simulator cannot prove echo cancellation or the recogniser's timing: that is Task 21 on a phone.

- [ ] **Step 11: Commit**

```bash
git add Matron/Features/Voice/VoiceModeEntry.swift Matron/Features/Voice/VoiceTextMaker+Cleaner.swift \
        Matron/Features/Voice/VoiceModeHost.swift Matron/App/AppDependencies.swift Matron/App/AppShellNavigation.swift \
        Matron/App/AppShellView.swift Matron/Features/ChatList/ChatListView.swift Matron/Features/Chat/ChatView.swift \
        MatronShared/Sources/ViewModels/VoiceNoteSession.swift MatronShared/Tests/ViewModelTests/VoiceNoteSessionTests.swift \
        MatronTests/VoiceModeTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "ios: voice mode, from a conversation's toolbar and from the app shell" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 21: Manual tests, the spike removed; PR 3

**Files:**
- Modify: `manual-tests.md` (append a section)
- Delete: `Matron/Features/Voice/VoiceSpikeView.swift`
- Modify: `Matron/Features/Voice/VoiceDebugView.swift` (the "Spike" section)

- [ ] **Step 1: Add the manual checks**

Append to `manual-tests.md`:

```markdown
## Voice mode (phase 1) — iPhone, iOS 26 or later

Spec: `docs/superpowers/specs/2026-10-03-voice-mode-carplay-design.md` §14. A real phone: the simulator has no echo path.

### A full exchange

- [ ] In a conversation, tap the waveform button: the screen says "Listening" with a rising two-note sound. Say a sentence and stop: about 1.5 s later it says "Sending", a sent sound plays, the voice note appears in the chat with its transcript, and other audio (music) comes back while the agent works.
- [ ] When the turn ends, the reply's short line is spoken (within about four seconds of the turn ending), with the line as a caption, then "Listening".
- [ ] Say "more": the longer version. "More" again: the message itself, a section at a time, each ending "Go on?"; "yes" carries on, "no" stops. "Repeat" says the last thing again.
- [ ] Say nothing for eight seconds: the microphone closes ("Tap to talk"); a tap opens it.
- [ ] A box with no summary key (or an old bridge): the reply is still spoken (first two sentences), and "more" reads the message.

### Interrupting

- [ ] Loudspeaker: while a reply is being spoken, say "actually, wait for the tests": the clip drops, stops, and the sentence is sent whole (the first word is not clipped).
- [ ] The same on AirPods.
- [ ] Cough during a clip: the volume dips and comes back; the clip carries on.
- [ ] Say "stop" over a clip: it stops and nothing is sent. "Skip" in the queue moves on.
- [ ] Tap anywhere during a clip: it stops and the microphone opens.
- [ ] Settings ▸ Voice mode ▸ "Talk over the agent" off: speaking over a clip does nothing; a tap still interrupts.

### Items and prompts

- [ ] From Conversations, tap the waveform button with an item awaiting you that has two actions: "One thing needs you. A decision: … Options: Go, Wait." with two buttons. Say "go": "Sending: Go." then, three seconds later, the sent sound; the item shows Go chosen.
- [ ] Say "go" then "cancel" inside the three seconds: "Cancelled." and nothing is sent.
- [ ] Say something close ("go, after lunch"): "Did you mean Go?"; "yes" sends, "no" says "OK, not sent."
- [ ] Say something else entirely: it is posted as a voice-note comment on the item.
- [ ] Tap a label button: sent at once.
- [ ] A tool-permission prompt (a session started with `/start --auto`): "bev wants to run a command: … Allow or deny?". "Allow" always asks "Did you mean Allow once?"; "deny" is sent at once ("Denied.").
- [ ] Leave a permission prompt for five minutes: "That permission request timed out and was denied."
- [ ] A secret request in the queue: "That one needs the screen. It's in your tracker." and it moves on.

### The queue

- [ ] With several things pending: the count, then the first; "skip" moves on; after the last, "That's everything." and it listens on the conversation used last.
- [ ] With nothing pending: "Nothing needs you." and it listens.

### Failures

- [ ] Flight mode, then speak: an error sound, "No connection. I'll send it when you're back online.", and the screen shows "1 voice note waiting for a connection". Flight mode off: the note is sent.
- [ ] A journal without `/tts` (or Voice set to On-device): everything is spoken in the on-device voice.
- [ ] A phone call during voice mode: it goes quiet; afterwards the cut-off line is said again.
- [ ] Switch to another app mid-reply and come back: the reply is said again from the start.
- [ ] Try to record an ordinary voice note while voice mode is on (it is not reachable from the voice screen; end voice mode and it works again).
- [ ] Leave voice mode idle for thirty minutes: it ends itself.
```

- [ ] **Step 2: Remove the spike**

```bash
git rm Matron/Features/Voice/VoiceSpikeView.swift
```

In `Matron/Features/Voice/VoiceDebugView.swift`, delete the block added in Task 15 Step 8:

```swift
            if #available(iOS 26, *) {
                Section("Spike") {
                    NavigationLink("Talking-over spike") { VoiceSpikeView(synth: synth, settings: settings) }
                }
            }
```

Run: `xcodegen generate && git checkout Matron/App/Info.plist`

- [ ] **Step 3: Run the manual checks on a phone**

Build to the phone used for the spike and run every line of the new section. If Task 15 chose a fallback, the "Interrupting" lines about talking over a clip are run with the setting turned on by hand, and their result is recorded, not required.

- [ ] **Step 4: Run every suite**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --skip test_fileLog 2>&1 | tee /tmp/shared-test.log | grep -E "Test Suite '.*\.xctest' (passed|failed)|Executed [0-9]+ tests"`
Expected: `VoiceTests.xctest` passes with `Executed 139 tests, with 0 failures`; `DesignSystemSnapshotTests` fails only on the tests named in Global Constraints.
Run: `swift test --package-path MatronShared --filter 'DesignSystemSnapshotTests.VoiceModeScreenSnapshotTests'`
Expected: `Executed 9 tests, with 0 failures` (snapshots compared, not skipped).
Run the iOS suite (Task 14 Step 7's command).
Expected: N = main's count plus 7; no failure other than `TextMessageCellTests.test_pillsRow_staysPut_whenTheCellSitsInASafeArea`.
Run the Mac suite (Global Constraints' command, with the override).
Expected: `Executed N tests, with 0 failures`, N = main's count (302 on 2 Oct): the Mac app compiles against the changed `VoiceNoteSession` and design system and nothing else moved.

- [ ] **Step 5: Commit, push, open PR 3**

```bash
git add manual-tests.md Matron/Features/Voice/VoiceDebugView.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "voice: manual checks, and the spike screen removed" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push -u origin feat/voice-loop
gh pr create --base feat/voice-speaking --title "Voice mode (3/4): listening and the loop" --body "$(cat <<'BODY'
Voice mode on the iPhone for spec 2026-10-03 (iOS 26 and later; the buttons are hidden below): capture through AVAudioEngine with voice processing and the on-device recogniser (end of speech, talking over a clip, commands), the runner that carries out the engine's effects, the feed that turns the local mirror into things to say (with the four-second wait for the bridge's spoken line), the full-screen voice screen, and its entry points (a conversation's toolbar; the Conversations and Decisions roots, which open the queue).

Spike result (Task 15): see below.

Plan: docs/superpowers/plans/2026-10-03-voice-mode-phase1-apple.md (Tasks 15–21)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

Then edit the PR description to paste `/tmp/voice-spike.md` under "Spike result" (`gh pr edit --body-file`), including which row of Task 15 Step 10 was taken.

---

# PR 4 — Siri

Branch: `git worktree add ../matron-apple-voice-4 -b feat/voice-siri feat/voice-loop`.

Both hooks are App Intents in the app target, published as App Shortcuts (spec §10). **No extension is needed:** the deployment target is iOS 18, App Intents and `AppShortcutsProvider` are iOS 16, an intent that opens the app must live in the app, and the build's `appintentsmetadataprocessor` step picks intents up from the app target by itself (it does not look inside a Swift package, which is why these files are under `Matron/`, not `MatronShared/`). The phrases need no strings file for a single-language app. `supportedModes` is iOS 26 (`openAppWhenRun` is deprecated there): verified with `grep -n "supportedModes\|struct IntentModes" "$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/AppIntents.framework/Modules/AppIntents.swiftmodule/arm64e-apple-ios.swiftinterface"`; https://developer.apple.com/documentation/appintents/appintent/supportedmodes.

### Task 22: "What needs me in Matron"

**Files:**
- Modify: `Matron/App/AppDependencies.swift` (line 25), `Matron/App/MatronApp.swift` (line 19)
- Create: `Matron/Features/Voice/Intents/VoiceIntents.swift`
- Test: `MatronTests/VoiceIntentsTests.swift` (new)

**Interfaces:**
- Consumes: `JournalStore.needsYouEntries()`, `NeedsYouQueue.summary` (Task 7); `AuthService.restoreSession()`.
- Produces: `AppDependencies.live` (the process's one instance); `struct WhatNeedsMeIntent: AppIntent` (runs in the background, answers with a dialog); `enum WhatNeedsMeAnswer` — `text(_:)`, `current(deps:)`, `signedOut`.
- Siri answers in its own voice, without opening the app, from this device's mirror (Decision 17). The journal store is readable after first unlock (it is deliberately not `NSFileProtectionComplete`, `JournalStore.swift:345`), so this works from a locked phone once it has been unlocked since boot.

- [ ] **Step 1: Write the failing test**

Create `MatronTests/VoiceIntentsTests.swift`:

```swift
import XCTest
import MatronModels
import MatronVoice
@testable import Matron

/// The Siri hooks (spec 2026-10-03 §10).
@MainActor
final class VoiceIntentsTests: XCTestCase {
    func test_whatNeedsMeAnswer() {
        XCTAssertEqual(WhatNeedsMeAnswer.text(nil), "Open Matron and sign in first.")
        XCTAssertEqual(WhatNeedsMeAnswer.text([]), "Nothing needs you.")
        let item = TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "Approve the claims copy",
                               originConvoID: "c1")
        let one = NeedsYouQueue.build(prompts: [], items: [item], conversations: [], now: Date())
        XCTAssertEqual(WhatNeedsMeAnswer.text(one), "One thing needs you. Approve the claims copy.")
        let two = NeedsYouQueue.build(prompts: [], items: [item], conversations: [
            QueueConversation(id: "c9", title: "[ab] Promo launch", unreadCount: 1, sessionState: "waiting"),
        ], now: Date())
        XCTAssertEqual(WhatNeedsMeAnswer.text(two), "Two things need you. The first: Approve the claims copy.")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`
Run: `set -o pipefail; xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -derivedDataPath build/ios-test -only-testing:MatronTests/VoiceIntentsTests CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/ios-test.log | grep -E "Executed [0-9]+ test|error:|\*\* TEST"`
Expected: build FAILS — `cannot find 'WhatNeedsMeAnswer' in scope`.

- [ ] **Step 3: One `AppDependencies` for the process**

In `Matron/App/AppDependencies.swift`, as the first member of `final class AppDependencies`:

```swift
    /// The app's one instance. `MatronApp` holds it for the UI; an App
    /// Intent that runs with no window (Siri's "what needs me") reaches the
    /// same journal mirror through it. Tests still build their own.
    static let live = AppDependencies()

```

In `Matron/App/MatronApp.swift`, change `@State private var dependencies = AppDependencies()` to:

```swift
    @State private var dependencies = AppDependencies.live
```

- [ ] **Step 4: The intent**

Create `Matron/Features/Voice/Intents/VoiceIntents.swift`:

```swift
import AppIntents
import MatronJournal
import MatronVoice

/// "What needs me in Matron" (spec 2026-10-03 §10): Siri answers by
/// itself, without opening the app, with the count and the first thing's
/// title, read from this device's mirror.
struct WhatNeedsMeIntent: AppIntent {
    static let title: LocalizedStringResource = "What needs me"
    static let description = IntentDescription("Says how many things need you in Matron, and the first one.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await WhatNeedsMeAnswer.current()
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}

enum WhatNeedsMeAnswer {
    static let signedOut = "Open Matron and sign in first."

    /// `nil` entries: nobody is signed in on this device.
    static func text(_ entries: [NeedsYouEntry]?) -> String {
        entries.map(NeedsYouQueue.summary) ?? signedOut
    }

    @MainActor
    static func current(deps: AppDependencies = .live) async -> String {
        guard let session = (try? await deps.auth.restoreSession()) ?? nil else { return signedOut }
        return text((try? deps.journalStore(for: session).needsYouEntries()) ?? [])
    }
}

/// App Shortcuts: they work as soon as the app is installed, with nothing
/// to set up. Apple requires the app's name in every phrase.
struct MatronShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatNeedsMeIntent(),
            phrases: [
                "What needs me in \(.applicationName)",
                "What's waiting in \(.applicationName)",
                "What needs me on \(.applicationName)",
            ],
            shortTitle: "What needs me",
            systemImageName: "tray.full")
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`, then the Step 2 test command.
Expected: `Executed 1 test, with 0 failures` and `** TEST SUCCEEDED **`.
Run: `xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3 && python3 -c "import json;d=json.load(open('build/ios/Build/Products/Debug-iphonesimulator/Matron.app/Metadata.appintents/extract.actionsdata'));print(sorted(d['actions']), [(s['actionIdentifier'], len(s['phraseTemplates'])) for s in d['autoShortcuts']])"`
Expected: `** BUILD SUCCEEDED **`, then `['WhatNeedsMeIntent'] [('WhatNeedsMeIntent', 3)]` — the metadata step found the intent and its three phrases in the app target.

- [ ] **Step 6: Commit**

```bash
git add Matron/App/AppDependencies.swift Matron/App/MatronApp.swift Matron/Features/Voice/Intents/VoiceIntents.swift \
        MatronTests/VoiceIntentsTests.swift
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "ios: Siri answers \"What needs me in Matron\"" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 23: "Start voice mode in Matron"; PR 4

**Files:**
- Create: `Matron/Features/Voice/Intents/VoiceModeLaunchInbox.swift`
- Modify: `Matron/Features/Voice/Intents/VoiceIntents.swift`, `Matron/App/AppShellView.swift` (before the `tappedRoomID` `.onReceive` at line 131; beside `voiceModeOpener`), `manual-tests.md`
- Test: `MatronTests/VoiceIntentsTests.swift`

**Interfaces:**
- Consumes: `AppShellNavigation.openVoiceMode`, `VoiceModeAvailability` (Task 20).
- Produces: `@MainActor final class VoiceModeLaunchInbox` — `shared`, `requests` (a `PassthroughSubject`), `request()`, `consume() -> Bool`, `isPending`; `@available(iOS 26, *) struct StartVoiceModeIntent: AppIntent` with `supportedModes = .foreground(.immediate)`; the second `AppShortcut`.
- The hand-off is `NotificationDelegate`'s pattern for a tapped notification (`AppShellView.swift:131-134` and `169-174`): published for a shell that is up, held for one still launching.

- [ ] **Step 1: Write the failing test**

In `MatronTests/VoiceIntentsTests.swift`, insert as the class's first test:

```swift
    func test_aSiriRequestIsHeldUntilTheShellTakesIt_once() {
        let inbox = VoiceModeLaunchInbox()
        XCTAssertFalse(inbox.consume())
        inbox.request()
        XCTAssertTrue(inbox.isPending)
        XCTAssertTrue(inbox.consume())
        XCTAssertFalse(inbox.consume(), "taken once")
    }

```

- [ ] **Step 2: Run to verify it fails**

Run the Task 22 Step 2 test command.
Expected: build FAILS — `cannot find 'VoiceModeLaunchInbox' in scope`.

- [ ] **Step 3: The inbox**

Create `Matron/Features/Voice/Intents/VoiceModeLaunchInbox.swift`:

```swift
import Combine
import Foundation

/// A request to open voice mode that arrived from outside the UI (Siri,
/// Spotlight, the Action Button). Same shape as `NotificationDelegate`'s
/// tapped-room hand-off: published for a shell that is already up, and
/// held for one that is still launching.
@MainActor
final class VoiceModeLaunchInbox {
    static let shared = VoiceModeLaunchInbox()

    let requests = PassthroughSubject<Void, Never>()
    private(set) var isPending = false

    func request() {
        isPending = true
        requests.send()
    }

    /// Takes the pending request, if there is one.
    func consume() -> Bool {
        defer { isPending = false }
        return isPending
    }
}
```

- [ ] **Step 4: The intent and its shortcut**

In `VoiceIntents.swift`, replace `MatronShortcuts` (everything from its doc comment to the end of the file) with:

```swift
/// "Start voice mode in Matron" (spec §10): opens the app in voice mode on
/// what needs the user, already listening.
///
/// `supportedModes` (iOS 26; `openAppWhenRun` is deprecated there):
/// https://developer.apple.com/documentation/appintents/appintent/supportedmodes
@available(iOS 26, *)
struct StartVoiceModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start voice mode"
    static let description = IntentDescription("Opens Matron in voice mode on what needs you.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceModeLaunchInbox.shared.request()
        return .result()
    }
}

/// App Shortcuts: both work as soon as the app is installed, with nothing
/// to set up. Apple requires the app's name in every phrase.
struct MatronShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatNeedsMeIntent(),
            phrases: [
                "What needs me in \(.applicationName)",
                "What's waiting in \(.applicationName)",
                "What needs me on \(.applicationName)",
            ],
            shortTitle: "What needs me",
            systemImageName: "tray.full")
        if #available(iOS 26, *) {
            AppShortcut(
                intent: StartVoiceModeIntent(),
                phrases: [
                    "Start voice mode in \(.applicationName)",
                    "Open \(.applicationName) voice mode",
                    "Start \(.applicationName) voice mode",
                ],
                shortTitle: "Voice mode",
                systemImageName: "waveform")
        }
    }
}
```

- [ ] **Step 5: The shell takes the request**

In `Matron/App/AppShellView.swift`, directly before `.onReceive(NotificationDelegate.shared.tappedRoomID) { roomID in`:

```swift
        // "Start voice mode in Matron" (Siri, Spotlight, the Action Button).
        .onReceive(VoiceModeLaunchInbox.shared.requests) { _ in openVoiceModeFromOutside() }
        .task { openVoiceModeFromOutside() }
```

and beside `voiceModeOpener`:

```swift
    /// Takes a request left by `StartVoiceModeIntent`: on the queue, as
    /// from the shell's own button. Dropped where voice mode cannot run.
    private func openVoiceModeFromOutside() {
        guard VoiceModeLaunchInbox.shared.consume(), VoiceModeAvailability.isSupported else { return }
        nav.openVoiceMode(.queue)
    }

```

- [ ] **Step 6: Run to verify**

Run: `xcodegen generate && git checkout Matron/App/Info.plist`, then the Task 22 Step 2 test command.
Expected: `Executed 2 tests, with 0 failures` and `** TEST SUCCEEDED **`.
Run the Task 22 Step 5 build-and-print command.
Expected: `['StartVoiceModeIntent', 'WhatNeedsMeIntent'] [('WhatNeedsMeIntent', 3), ('StartVoiceModeIntent', 3)]`.

- [ ] **Step 7: Add the manual checks and run them on a phone**

Append to the "Voice mode (phase 1)" section of `manual-tests.md`:

```markdown
### Siri

- [ ] "Hey Siri, what needs me in Matron" with the app closed: Siri says the count and the first thing's title in its own voice, and Matron does not open. With nothing pending: "Nothing needs you." Signed out: "Open Matron and sign in first."
- [ ] The same from the Lock Screen after the phone has been unlocked once since restart.
- [ ] "Hey Siri, start voice mode in Matron" with the app closed and the phone unlocked: Matron opens in voice mode, says what needs you and listens. With the app already open on another screen: the same. With voice mode already on: nothing restarts.
- [ ] Both shortcuts appear under Matron in the Shortcuts app and in Spotlight. On iOS 18–25 only "What needs me" appears.
```

Run each on the phone. Whether Siri asks for Face ID to open the app from a locked phone is expected (spec §10, "Limits"); note what it did.

- [ ] **Step 8: Run every suite, commit, push, open PR 4**

Run the iOS suite (Task 14 Step 7's command). Expected: N = main's count plus 9; no failure other than the known one.

```bash
git add Matron/Features/Voice/Intents Matron/App/AppShellView.swift MatronTests/VoiceIntentsTests.swift manual-tests.md
git -c user.name="Dan Barker" -c user.email=dan@yearbookmachine.com commit \
  -m "ios: Siri starts voice mode on what needs you" \
  -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push -u origin feat/voice-siri
gh pr create --base feat/voice-loop --title "Voice mode (4/4): Siri" --body "$(cat <<'BODY'
The two Siri hooks of spec 2026-10-03 §10, as in-app App Intents published as App Shortcuts (no extension): "What needs me in Matron" answers with the count and the first thing's title without opening the app; "Start voice mode in Matron" (iOS 26) opens the app in voice mode on the queue.

Plan: docs/superpowers/plans/2026-10-03-voice-mode-phase1-apple.md (Tasks 22–23)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

## Self-review (done while writing)

- **Every Swift file in this plan was compiled and every test run before it was written down,** in a scratch copy of this worktree (Xcode 27.0, Swift 6.4 in 5.10 mode): the shared package's new tests pass on the Mac host (`VoiceTests` 139, `JournalStoreVoiceTests` 14, `TTSAPITests` 5, `MediaTranscriptAPITests` 1, `SpeechCleanerTests` 25, `VoiceModeScreenSnapshotTests` 9 with snapshots skipped, `VoiceNoteSessionTests` 18), the package builds with its tests at the PR 1 and PR 2 cut points (the later files removed), `MatronVoice` builds for the iOS Simulator, the `Matron` app builds for the iOS Simulator and `MatronMac` for macOS with all of PR 1–4 in place, the App Intents metadata lists both intents with three phrases each, and `VoiceModeTests` (5), `VoiceSettingsTests` (2), `VoiceIntentsTests` (2) and `AppShellNavigationTests` (27) pass on the iPhone 17 simulator. What was NOT run: anything that needs a microphone, a loudspeaker or a voice (Task 14 Step 6, Task 15 Steps 9–10, Task 21 Step 3, Task 23 Step 7), the snapshot recordings, the Mac test bundle, and the app target at the PR 2 and PR 3 cut points (only the final state was built).
- **Spec coverage, phase 1 apple part:** §1 "Where it goes" and "When it is missing" → Tasks 1, 2, 17. §3 states, listening, talking over, what happens to what was said, what is spoken, the cleaner, playing, audio session → Tasks 3, 8, 12, 15, 17, 18. §4 → Tasks 5, 8. §5 → Tasks 7, 8, 17. §6 entry, screen, scope, settings → Tasks 13, 19, 20. §10 → Tasks 22, 23. §11 (rules the engine enforces) → Task 8 (confirmations, the idle end, sounds on state changes, refusal of screen-only things). §12 → Tasks 8, 18 (offline, late transcript, cloud voice unavailable, no spoken line, the agent busy, a permission expiring, interruptions). §13 phase 0 → Task 14 Step 6 (listening test), Task 15 (talking-over spike); the CarPlay entitlement request is the Account Holder's and not in this plan. §14 app tests → Tasks 5, 7, 8, 3; manual → Tasks 21, 23.
- **Deliberately not here:** §7, §8, §9; the exhibit extractor; `voice_mode` presence; the Live Activity; voice mode on the Mac (the engine, player, feed and screen are in `MatronShared` and compile for macOS; `VoiceAudioSession` is a no-op session there).
- **Placeholders:** none; every code step carries the code.
- **Type consistency:** `VoiceEntry` / `VoiceSubject` / `SpokenReply` (Task 6) are what the engine (8), feed (17), runner (18) and host (20) use; `VoiceModeEngine.Effect` cases (8) are exactly the ones `VoiceModeRunner.perform` switches over (18); `VoiceCapturing` / `VoiceAudioControlling` / `SpeechPlaying` / `VoiceSending` / `VoiceFeeding` (15) are implemented by `VoiceCapture`, `VoiceAudioSession` (15), `SpeechPlayer` (12), `JournalVoiceSender` (16), `JournalVoiceFeed` (17) and by the fakes in Task 18; `AgentReplyRow` (2) is what the feed reads; `VoiceModeScreen.Model` (19) is what `VoiceModeScreenMapping` (20) builds.
- **Review Focus:** each of the six lines has its pinning test in the named task.
