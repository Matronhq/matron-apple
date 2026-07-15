# Shipping Matron to TestFlight and the App Store

Status as of 2026-07-16. One App Store Connect record covers both apps: iOS and
macOS share the bundle ID `chat.matron.app` (universal purchase), so there is
one listing, one TestFlight page, and one APNs topic.

This document is the audit trail behind the submission settings. Where it says
"verified", it means it was observed on a real Release build, not inferred.

---

## 1. What is done, and how it was checked

| Item | State | How it was verified |
|---|---|---|
| Bundle IDs unified (`chat.matron.app`) | done (PR #35) | — |
| Versioning (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) | done | Release build: `1.0.0` / `1` |
| NSE version keys match host (App Store validation rejects a mismatch) | done | Release build: both `1.0.0` / `1` |
| Release entitlements split (production APNs, sandbox on) | done (PR #35) | — |
| Export compliance (`ITSAppUsesNonExemptEncryption`) | present, **needs Dan's sign-off** — see §4 | Release build: `false` |
| App category (`LSApplicationCategoryType`) | done | Release build: `public.app-category.social-networking` |
| Copyright (`NSHumanReadableCopyright`) | done | Release build: present |
| Mic usage string | done | Release build: present |
| Photo library usage string | **added** | Release build: present |
| Privacy manifests (iOS + Mac) | **added** | Release builds: at bundle root / `Contents/Resources`, `plutil -lint` OK |
| Hardened runtime (Mac, Release only) | **added** | Ad-hoc Release build: `codesign -d` → `flags=0x10002(adhoc,runtime)` |
| App icons | complete | iOS 1024 single-size; Mac 16→512@2x all present |
| Release builds compile (both platforms) | verified | `xcodebuild -configuration Release` → BUILD SUCCEEDED |

### The privacy manifest audit

Apple rejects uploads that use a "required reason" API without declaring it
(ITMS-91053). Neither app had a manifest at all. Every entry was derived by
grepping the shipping code:

- **UserDefaults → `CA92.1`** (both apps). Used for the appearance setting,
  recent `/start` folders, answered ask-user prompts, the `MatronDebug` flag,
  and the Mac's registered window defaults. All via `UserDefaults.standard` —
  app-local, no app-group suite in shipping code (only tests build suites),
  which is exactly the case `CA92.1` describes.
- **File timestamp → `C617.1`** (**iOS only**). `SearchSchema` calls
  `FileManager.attributesOfItem(atPath:)` to assert `NSFileProtectionComplete`
  on the search index. It reads `.protectionKey`, not a timestamp, and is gated
  to `#if os(iOS) && !targetEnvironment(simulator)` — declared defensively
  because Apple's static check flags the call site, and the file is in our own
  container. The Mac manifest omits it: that path never compiles on macOS.
- **MatronNSE has no manifest** — it links nothing and uses no required-reason
  API. Add one the moment that changes.
- Not used, so not declared: disk space, system boot time, active keyboards.

### Archive dry-run (2026-07-16)

Both archives were actually attempted, so the signing story below is observed
rather than assumed.

**iOS: `** ARCHIVE SUCCEEDED **`.** The Release build archives, signs, and
embeds the NSE — nothing in the code or project config blocks an upload. One
caveat, and it's the important one: it signed with **`Apple Development: Dan
Barker`**, and Xcode rewrote the entitlement to `aps-environment: development`
to match the profile it chose. It fell back to a development identity because
there is **no Apple Distribution certificate / App Store profile for
`chat.matron.app` on this machine**. So:

- The archive proves the pipeline works.
- It is *not* the artifact you'd ship. The distribution-signed export
  (`method: app-store-connect`) needs §2.1/§2.2 first, and that export is what
  restores `aps-environment: production`.
- A TestFlight build that ships with the *development* APNs environment gets
  silent push failure, not an error. Check the exported artifact's entitlement
  the first time through — not just the archive's.

**Mac: `** ARCHIVE FAILED **`** — exactly the documented gotcha, verbatim:

```
error: No Accounts: Add a new account in Accounts settings.
error: Provisioning profile "Mac Team Provisioning Profile: *" doesn't include
       the Push Notifications capability.
error: Provisioning profile "Mac Team Provisioning Profile: *" doesn't include
       the com.apple.developer.aps-environment entitlement.
```

The Mac app cannot archive at all until an Apple ID is added to Xcode and a
`chat.matron.app` + macOS **push-capable** profile exists. Both fall out of
§2.1/§2.2. No build-setting work moves this gate.

---

## 2. Blockers only Dan can clear

Nothing below can be done from this side. Ordered by what blocks what.

1. **Create the App Store Connect app record** on `chat.matron.app`, add the
   **macOS platform** to the same record, and add yourself as an internal
   tester. Everything else waits on this.
2. **Generate an App Store Connect API key.** Send it via the secure form when
   asked — never paste a key into chat. `scripts/testflight-upload.sh` reads
   `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH`.
   - This also fixes the local Mac signing gotcha: team-signed Mac builds fail
     ("No Accounts", team profile lacks Push) until a `chat.matron.app` + macOS
     push-capable profile exists. The first archive with the API key (or one
     Xcode signing pass) creates it.
3. **Host a privacy policy** and put its URL in App Store Connect — a required
   field, submission is blocked without it. Draft ready at
   `docs/privacy-policy-draft.md`; it needs your review and a real URL.
4. **Answer the App Privacy questions** in App Store Connect. They must agree
   with `NSPrivacyCollectedDataTypes` in both manifests — see §4.
5. **Screenshots.** iOS needs 6.9" (1320×2868); Mac needs one of
   1280×800 / 1440×900 / 2560×1600 / 2880×1800. Not generated here: the app
   needs a signed-in account and a live agent to show anything, and any real
   screenshot contains your actual conversations. Your call what to show.
6. **Set `MATRON_APNS_TOPIC=chat.matron.app`** (+ `MATRON_APNS_KEY_FILE` /
   `KEY_ID` / `TEAM_ID`) on the remote journal server, or push silently fails
   for both platforms.

---

## 3. The App Review risk worth thinking about first

**App Review must be able to actually use the app.** Matron is a client for a
journal server plus a paired agent on your machine. A reviewer who downloads it
gets a sign-in screen and cannot get past it. That is a Guideline 2.1 rejection
(and 5.1.1 if they can't evaluate it), and it will not be caught by any build
setting.

You need at least:

- A **demo account** (credentials go in App Review's "Sign-In Information"
  field, which is the sanctioned place for them), pointed at a journal server
  that stays up for the review window, with
- a **live agent session** attached to it, so the reviewer sees a working
  conversation rather than an empty shell, and
- **review notes** explaining what Matron is: a remote control for a coding
  agent running on the user's own computer.

Worth deciding early whether the reviewer gets a sandbox agent with a scripted
demo conversation rather than anything real. This is likely the single most
probable cause of a first-submission rejection — every other item on this page
is mechanical by comparison.

---

## 4. Open questions that need your judgement

**iPad.** `TARGETED_DEVICE_FAMILY` is `"1,2"`, so the listing claims iPad
support and App Review will test on an iPad. The iOS app is a plain
`NavigationStack` with no size-class or idiom handling anywhere in the target —
on an iPad it renders as a stretched iPhone layout. SwiftUI means it will
*work*; whether it looks like an iPad app is another matter (Guideline 4.0).

The asymmetry that matters: **adding** iPad support in a later update is easy
and uncontroversial; **removing** it after release strands users who bought it
on iPad. If you haven't actually run Matron on an iPad and liked it, shipping
v1 as iPhone-only (`"1"`) is the reversible choice. Left as-is — flipping it is
one line, but it's a product call, not a build fix.



**Export compliance.** `ITSAppUsesNonExemptEncryption` is `false`, claiming
exemption. Matron uses HTTPS (exempt) and decrypts push payloads. If that
decryption uses only OS-provided standard crypto it's very likely still exempt,
but "we ship our own crypto" and "we only call Apple's" land differently, and
a wrong answer here is a legal declaration, not a build setting. Confirm before
the first upload. Left untouched deliberately.

**Data collection.** `NSPrivacyCollectedDataTypes` in both manifests is a draft
I wrote from what the client demonstrably transmits: email address, user ID,
messages, photo attachments, voice notes, other file attachments, and the APNs
device token. All marked linked-to-user, none used for tracking, all purpose
"App Functionality".

The judgement it encodes: the journal server stores messages, and the default
deployment is a server you operate, so that content counts as "collected" by
the developer. A user who self-hosts sends nothing to you — but the declaration
has to describe the shipping default. If you'd rather frame Matron as
bring-your-own-server, that changes both the manifests and the App Privacy
answers, and it's your call, not mine.

---

## 5. Listing copy — draft

Required fields, drafted so you're not starting from an empty box. This is your
product's voice, not mine; treat it as a starting point. The 30-character
subtitle and 100-character keyword limits are hard.

**Name (30):** `Matron`
**Subtitle (30):** `Your coding agent, anywhere` (27)

**Promotional text (170):**
> Start a session on your Mac, keep it going from your phone. Watch tool calls
> and diffs stream in live, answer prompts, and send photos or files straight
> to your agent.

**Description:**
> Matron is a remote control for the coding agent running on your own computer.
>
> Start a session at your desk and pick it up from your phone. Matron shows the
> conversation as it happens — tool calls, terminal output, and diffs stream in
> live, so you can see what your agent is doing rather than waiting for it to
> finish.
>
> • Follow sessions in real time, on iPhone and Mac
> • Read diffs and command output in a proper terminal-style view
> • Answer your agent's questions without going back to your desk
> • Send photos, files, and voice notes into the conversation
> • Jump into subagent sub-chats to see the detail
> • Search your history
> • Push notifications when your agent needs you
>
> Matron connects to a Matron journal server and an agent running on your own
> machine. You'll need both set up before signing in.

That last paragraph is deliberate: setting expectations up front is worth more
than the install it costs, and it's the same fact App Review will hit (§3).

**Keywords (100, comma-separated, no spaces):**
> `coding,agent,claude,developer,terminal,remote,ssh,devtools,programming,ai,assistant,code`

**Category:** Developer Tools (primary). The Mac Info.plist currently declares
`public.app-category.social-networking` — that predates this doc and is
probably wrong for a dev tool; the ASC category and the plist key should agree.
Worth changing to `public.app-category.developer-tools` unless you specifically
want the social framing.

**Support URL / Marketing URL:** required — needs a real page.

**Age rating:** likely 4+, but the questionnaire asks about
"Unrestricted Web Access". Matron renders agent output, not arbitrary web
content, so 4+ should hold.

---

## 6. Upload runbook (once §2.1 and §2.2 are done)

```bash
export ASC_KEY_ID=...        # from the secure form, not from chat
export ASC_ISSUER_ID=...
export ASC_KEY_PATH=/path/to/AuthKey_XXXX.p8

scripts/testflight-upload.sh ios     # or: mac | all
```

The build number is `git rev-list --count HEAD`, so it's unique and monotonic
per commit — App Store Connect rejects a re-used build number.

After the first successful archive, re-check that local team-signed Mac builds
work; if they do, the ad-hoc signing workaround in
`project_testflight_prep` memory can be dropped.
