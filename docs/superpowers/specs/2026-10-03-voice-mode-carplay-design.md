# Voice mode, the big-screen stage and CarPlay — design

Date: 2026-10-03. Status: approved by Dan on 3 Oct 2026, after he
answered each design question in the tracker (see "Decisions"). The Siri
section was added at his suggestion when he approved.

## Why

Dan talks to his agents by voice note already, but the agent can only
answer in text. He wants to hold a conversation without reading: he
speaks, the agent answers out loud, hands-free. When he is listening he
must not hear the whole message (tool output, tables, links), only the
part worth saying: a short summary that leads with the decision, a
longer version if he asks for more, and more again after that.

He wants this in two settings, designed together:

- **No screen**: driving, with a CarPlay app, or the phone in a pocket.
- **A big screen he isn't reading from**: walking at a treadmill desk.
  Voice still leads, but the screen shows one thing at a time, large,
  with nothing around it: screenshots to swipe through, or the text of
  one email on its own.

Matron differs from ChatGPT's voice mode in one way that shapes the whole
design: **an agent may take five minutes to answer.** A voice loop that
holds the microphone and the car's audio for the whole wait is wrong for
the driver and against Apple's CarPlay rules. So the design is a
turn-based loop that lets go of the audio between turns and gets it back
when there is something to say.

## Decisions

| Question | Answer |
|---|---|
| Where the voice is generated | Cloud, on the journal, Azure MAI-Voice-2.1-Flash; on-device voice as fallback (Dan, 3 Oct) |
| How the spoken version is written | The bridge's turn-end summary pass writes it (Dan, 3 Oct) |
| How much is said | Layered (Dan, 3 Oct): a short line first, a longer version on "more", then the message itself in sections |
| Turn-taking | Hands-free with end-of-speech detection, and Dan can talk over the agent to interrupt it, from the first version (Dan, 3 Oct). A tap also interrupts |
| Reply lands while Matron is not on screen | The notification plays the spoken summary as its sound (Dan, 3 Oct). Needs a cloud voice |
| Answering items and prompts by voice | Act on a clear match, confirm when unsure; always confirm tool permissions (Dan, 3 Oct) |
| CarPlay category | Voice-based conversational app (Dan, 3 Oct) |
| What voice mode opens to | A "what needs you" queue, then the last conversation (Dan, 3 Oct) |
| Phasing | Phases, with the CarPlay entitlement requested from Apple now (Dan, 3 Oct) |
| Hands-free with a screen | In scope, designed alongside the no-screen mode (Dan, 3 Oct) |
| Which device drives the big screen | A Mac with a monitor (Dan, 3 Oct) |
| Gestures at the treadmill | A clicker or remote, and hand gestures in the air tracked by a webcam, so it can be fully hands-free (Dan, 3 Oct) |
| Siri | Hooks through App Intents: start voice mode, and "what needs me" (Dan asked for Siri hooks when approving, 3 Oct) |
| Who picks what is shown | The app picks automatically now; an agent "show" tool is added later and overrides it (Dan, 3 Oct) |

## What exists today

- **Voice notes in.** The app records AAC `.m4a` (`VoiceRecorder`,
  `VoiceNoteSession`), uploads it with `POST /media`, and sends a `file`
  event. The journal transcribes at upload with Azure Speech fast
  transcription (MAI-Transcribe-2, 0.6 s median per note) and serves the
  words at `GET /media/:id/transcript?wait=N`. The bridge hands the
  transcript to the agent as `[Voice note transcription]: …`.
- **Nothing out.** No text-to-speech, no audio playback, no Siri or
  App Intents, no notification categories, no CarPlay code or
  entitlement. The audio session is `.record`, active only while a note
  records. The iOS app already has the `audio` background mode.
- **A turn** is several `text` events followed by `session_status:
  waiting`. Nothing marks which text is "the answer".
- **A turn-end summary pass** runs on the bridge
  (`maybeSummarizeAtTurnEnd`, `lib/summary-pass.js`): one call to a small
  model (OpenAI or Gemini, whichever key the box has) that returns
  `TITLE`, `NEW` and `ROSTER`. `NEW` is published as a `summary` event
  `{toc, detail, model}`, which every device syncs and no device shows in
  the timeline. It lands a second or three after the turn ends.
- **The journal** holds an Azure Speech key and makes no model calls.
- **Items** are answered with `POST /items/:id/comments {body, action?}`;
  `action` must exactly match one of the item's labels and only a client
  may send it. Ask-user prompts and tool-permission prompts are answered
  with the `prompt_reply` op. Permission prompts deny after five minutes.

## Overview

Three repos. Phase 1 touches all three; each part degrades cleanly
against an old version of the others.

1. **matron-bridge** — the summary pass writes two more lines, `SPOKEN`
   and `SPOKEN_MORE`, and publishes them on the `summary` event.
2. **matron-journal** — `POST /tts` turns text into audio with Azure and
   caches it. Later, pushes that carry a spoken clip.
3. **matron-apple** — a voice engine in `MatronShared`, a voice-mode
   screen on iPhone, a big-screen stage, and a CarPlay scene, all on the
   same engine.

```
 Dan speaks ─► app records ─► POST /media ─► journal transcribes (Azure)
                    │                              │
                    │◄──── transcript ─────────────┘
                    ├─ a command ("more", "skip")?    handled on the phone
                    ├─ answers an item/prompt?         comment / prompt_reply
                    └─ otherwise                       sent as a voice note
                                                           │
 agent works (seconds to minutes; audio released) ◄────────┘
        │
        ▼
 turn ends ─► bridge summary pass ─► summary event {…, spoken, spoken_more}
                                              │
 app: POST /tts {text: spoken} ─► journal ─► Azure ─► audio ─► plays
        │
        ▼
 Dan answers, says "more", or talks over the clip
```

## 1. The spoken version (matron-bridge)

### Three levels

Dan hears a reply in levels and decides how deep to go:

| Level | Said when | Length | Written by |
|---|---|---|---|
| 1. Short | Always, when the turn ends | 40 words, about 15 seconds | The summary pass (`SPOKEN`) |
| 2. Longer | He says "more" | 150 words, about a minute | The summary pass (`SPOKEN_MORE`) |
| 3. The message | He says "more" again | A section at a time, about a minute each | The cleaner (section 3), from the agent's own text |

After each section of level 3 the engine asks "Go on?". Beyond the
message itself, any question he speaks ("why not the second option?")
goes to the agent as usual, and its answer comes back as a new level 1.

Levels 1 and 2 are both written at the turn's end, so "more" answers at
once instead of waiting on a model. Only level 1 is ever played by a
notification, which is why it must stay well under thirty seconds.

### What is written

The summary prompt gains two output lines, placed before `ROSTER` (which
must stay last):

```
SPOKEN: <what someone listening while driving should hear about the
agent's latest reply, 40 words at most. First, anything the agent is
asking or needs decided, naming the options. Then the outcome in one
sentence. Then what it will do next, only if that matters. Plain spoken
English. No code, file paths, URLs, PR or issue numbers, markdown or
lists. If the reply has a table, a diff or a long list, say it is in the
chat instead of reading it.>
SPOKEN_MORE: <the next thing that listener would want if they said "tell
me more", 150 words at most. Do not repeat SPOKEN. Give the reasoning
behind the question or result, what each option would mean, and any risk
or caveat the agent raised. Same plain spoken style and the same
exclusions. Write NONE if SPOKEN already says everything.>
```

The order inside `SPOKEN` is the rule for "what gets said": what is
needed from Dan, then the result, then what happens next.

### Where it goes

The `summary` event payload becomes `{toc, detail, model, spoken,
spoken_more, spoken_ref}`. `spoken` is capped at 400 characters and
`spoken_more` at 1,200; `spoken_more` is omitted when the model wrote
`NONE`. `spoken_ref` is the `message_ref` of the agent's last reply (of
its first `text` event, when a long reply is split), so the app can tell
which reply the lines belong to. Old apps ignore the new keys.

Today only streamed replies carry a `message_ref`. The bridge now gives
every flushed reply one, so replies in interactive mode and from Codex
can be named too. `spoken` and `spoken_ref` are sent together or not at
all: a turn with no reply, or a reply with no ref, sends neither. A
summary can land after a newer reply has gone out; the app speaks a line
only when its `spoken_ref` is the newest reply's.

They are written on every turn, not only in voice mode: the cost is
about 250 output tokens on a call that already happens, and the bridge
needs no signal about who is listening.

### When it is missing

A box with no summary key, an old bridge, or a failed pass produces no
`spoken`. The app then speaks a trimmed version of the final message made
by a deterministic cleaner (section 3) as level 1, and "more" goes
straight to level 3. So voice mode works everywhere and is merely better
on an up-to-date box.

### Not chosen

- *The agent writes the spoken line.* Sharper, but it spends agent tokens
  on every turn, depends on the agent remembering, and needs the same
  work again for Codex.
- *A summariser on the journal.* The journal has no model key and would
  gain a new cost and a new place where message text is sent.

## 2. Text to speech (matron-journal)

### `POST /tts`

Request: `{text, voice?, format?}`. `text` is at most 2,000 characters.
`format` is `mp3` (default, 24 kHz) or `wav` (16 kHz 16-bit PCM, for
notification sounds). Response: the audio bytes, with a strong `ETag`.

- New module `src/cloud-tts.js`, shaped like `cloud-transcribe.js`. It
  posts SSML to `https://{region}.tts.speech.microsoft.com/cognitiveservices/v1`
  with a voice name such as `en-GB-Harry:MAI-Voice-2.1-Flash`.
- Config: `MATRON_TTS_AZURE_KEY` / `_KEY_FILE` (falls back to the
  transcription key, which is the same Azure Speech resource),
  `MATRON_TTS_AZURE_REGION`, `MATRON_TTS_VOICE`, `MATRON_TTS_MODEL`.
  With no key the route answers 501 and the app uses the on-device voice.
- The text is XML-escaped into the SSML; no caller-supplied markup.
- Cache: keyed by a hash of voice, model, format and text, kept for 24
  hours in its own `tts-cache` folder beside the database. (The media
  store charges every blob to a user's quota and has no age expiry, so
  clips do not go there.) The same line asked for twice (phone, then
  CarPlay, then a notification) is synthesised once.
- Limits: a per-user daily character budget (default 300,000, about $4.50
  at $15 per million), held in memory, and at most 4 requests at Azure
  with a short queue behind them. Over budget answers 429 and a full
  queue 503; on any failure the app falls back to the on-device voice.
- Because the key falls back to the transcription key, deploying this
  turns cloud speech on wherever that key is set. `MATRON_TTS_DISABLED=1`
  ships it switched off.
- `GET /tts/voices` lists the voices on offer. The journal has no
  capability endpoint today, so this doubles as the check: a 404 (old
  journal) or 501 (no key) tells the app to use the on-device voice.

### Voice

The app's voice-mode settings offer the British voices Azure lists for
the model (Emily, Harry) and send the choice as `voice`. The journal
checks it against an allow-list.

### Privacy

The text of the spoken line goes to Azure, the vendor that already
receives voice-note audio. Only the short spoken line is sent, not the
conversation. The privacy-policy draft gains a sentence. Cached clips
expire after 24 hours.

### Risk

MAI-Voice-2.1-Flash was released on 1 October 2026 and is a public
preview with no uptime guarantee. The first build step is a listening
test of Emily and Harry on real spoken lines. If the quality or
reliability disappoints, the module's vendor is swapped (Azure's older
neural voices need only a different voice name; OpenAI needs a new key);
nothing else in the design changes.

## 3. The voice engine (matron-apple, `MatronShared`)

One engine drives the iPhone screen, the Mac's stage and CarPlay.

### States

```
idle ─► listening ─► sending ─► waiting ─► speaking ─► listening …
                        │                      ▲
                        └─► confirming ────────┘
```

- **listening** — microphone open. Ends when Dan stops talking (about
  1.5 s of silence after speech), when he taps Send, or after two
  minutes. If he says nothing for eight seconds the microphone closes and
  the engine goes to waiting.
- **sending** — the recording uploads and the journal transcribes it.
- **confirming** — the engine has said "Sending: Go" or asked "Did you
  mean Go?" and is listening briefly for "cancel", "yes" or "no".
- **waiting** — nothing to say and nobody talking: the agent is working,
  or Dan has nothing to add. The audio session is released, so music or
  the radio comes back. No microphone. A tap opens it; a reply landing
  moves to speaking.
- **speaking** — a clip plays, with the microphone open underneath it.
  Dan talking, or a tap, stops the clip and the engine is listening.

The engine is a pure state machine (state, event → state, effects) with
the audio, network and clock behind protocols, so it is unit-tested
without a device.

### Listening

- Voice mode captures with `AVAudioEngine`, with Apple's voice
  processing switched on (echo cancellation and noise suppression), and
  plays its clips through the same engine. That is what lets the
  microphone stay open while the agent speaks without hearing the agent.
  `VoiceRecorder` is unchanged and keeps serving ordinary voice notes.
- The capture is written in the voice-note format and uses the same
  upload path. The words sent to the agent come from the journal's
  transcription, the same engine and vocabulary as voice notes, so "bev"
  and "PR" are heard the same way in both.
- An on-device recogniser (`SpeechAnalyzer`: `SpeechDetector` for "is
  someone speaking", `SpeechTranscriber` for rough words) runs alongside.
  Its words are never sent to the agent. They are used for three things:
  end of speech, talking over the agent, and commands.
- End of speech: speech seen, then about 1.5 s without it.
- Voice mode therefore needs iOS 26. The app's floor stays at iOS 18 and
  the voice-mode buttons are hidden below 26.

### Talking over the agent

While a clip plays, the echo-cancelled microphone is watched:

1. **Speech starts** (the detector reports speech for 300 ms): the clip
   drops to a low volume. Nothing is lost yet.
2. **Words follow** (the recogniser produces a word within a second): the
   clip stops and the engine is listening. The capture includes the half
   second before the speech started, kept in a rolling buffer, so the
   first word is not clipped.
3. **No words follow** (a cough, a door, road noise): the volume comes
   back and the clip carries on.

A command spoken over the clip ("stop", "more", "skip", "repeat") is
acted on from the on-device words at once, with no upload.

Limits, stated plainly:

- Anyone's voice triggers it, a passenger's included. A setting, "Talk
  over the agent", turns it off and leaves the tap.
- It depends on echo cancellation. That is dependable on AirPods and on
  the phone's own speaker. Through a car it varies with the car's audio
  delay, and cannot be known until it is tried in a real one. If a car
  defeats it (the agent keeps interrupting itself), the engine notices
  repeated self-triggers, switches talking-over off for that audio route
  and says so. The tap and the CarPlay Stop button always work.
- A tap anywhere on the voice screen interrupts, as before.

### What happens to what Dan said

When he stops speaking, in this order:

1. **A command.** If the on-device words are a command and nothing else,
   in any natural phrasing ("tell me more", "I want to know more", "go
   on"), it is handled on the device and nothing is uploaded. The
   commands are "repeat", "more", "skip" / "next", "stop" and "cancel".
2. **Otherwise the recording is uploaded** and the journal's transcript
   comes back, usually within a second or two.
3. **An answer to the thing just read out**, if that was an item or a
   prompt with options, is matched against the transcript (section 4).
   When it becomes a button press, the recording itself is not posted
   (the journal's media reaper removes the unreferenced upload).
4. **Anything else** is sent to the current conversation as a voice note,
   exactly as today, so the chat keeps the audio and the transcript.

If no transcript arrives within eight seconds (journal transcription off
or slow), the recording is sent as an ordinary voice note and the engine
says "Sent". Option matching is skipped for that turn.

### What is spoken

| Event in the voice conversation | Spoken |
|---|---|
| Turn ends | The `spoken` line for the turn's last reply. The engine waits up to four seconds after `session_status: waiting` for the `summary` event, then falls back to the cleaner. |
| Agent text in the middle of a turn | Nothing. |
| Ask-user prompt | The question, then "Options:" and the labels. |
| Tool-permission prompt | "bev wants to run a command: git push origin main. Allow or deny?" The command is cut at 80 characters. |
| Item created or handed to Dan | The item's title, then its action labels. |
| A secret request, a consent card, anything needing the screen | "That one needs the screen. It's in your tracker." |

"More" steps down a level: the first time it plays `spoken_more`, and
after that it reads the final message itself through the cleaner, a
section at a time (split at headings and paragraphs, about a minute
each), asking "Go on?" between sections. "Repeat" replays the level
just heard. After level 1 the engine says "Say more for the detail" the
first few times, then stops prompting.

**The cleaner** is a deterministic function from Markdown to speakable
text: code blocks, tables, diffs, images and URLs are dropped (a table
becomes "there's a table in the chat"), link text is kept, headings and
list markers are removed, and `[#12](matron://item/12)` becomes "item
twelve". For the fallback it keeps the first two sentences and, when the
message ends with a question, that question.

### Playing

`SpeechPlayer` asks the journal for a clip and plays it. On a 501, a 429,
no network, or no audio within two seconds, it speaks the same text with
`AVSpeechSynthesizer`. Fixed phrases ("Sent", "Three things need you")
are cached on the phone after first use. Short sounds mark the
microphone opening, a message sent, and an error, so no state needs a
glance at the screen.

### Audio session

`.playAndRecord` with voice processing, activated when the engine starts
listening or speaking and deactivated (notifying other apps) when it
enters waiting or idle.
`VoiceRecorder`'s interruption handling carries over: a call or Siri
pauses the engine. An ordinary voice note cannot be recorded while voice
mode is on.

## 4. Answering items and prompts by voice

When the engine has just read out something with options, the next
utterance is matched against the labels:

- **Clear match** — the utterance is a label, or a label with filler
  ("go", "yes, go", "option one", "the second one", "allow"). The engine
  says "Sending: Go", waits three seconds for "cancel", then sends the
  item comment with `action`, or the `prompt_reply`.
- **Unsure** — close to one label, or close to two. The engine asks "Did
  you mean Go?" and sends only on "yes".
- **No match** — sent as a spoken reply: a voice-note comment on the item,
  or free text on the prompt.

Tool-permission prompts always take the "Did you mean" path, whatever was
heard: allowing a command by mistake costs more than a mis-tapped item.
"Deny" needs no confirmation. Anything else said to a permission prompt
gets "Say allow or deny" rather than being sent as text.

A tap on a label's button on the phone is deliberate, so it sends at
once with no read-back.

The match is exact-label only at the server, so a wrong match cannot
invent an action; the risk is choosing the wrong one of the real labels,
which the read-back and the cancel window cover.

## 5. What voice mode opens to

Started from inside a conversation, voice mode talks to that
conversation. Started from anywhere else (the app shell, or CarPlay), it
opens on **what needs Dan**:

1. Pending tool-permission prompts (they expire in five minutes).
2. Pending ask-user prompts.
3. Tracker items awaiting Dan, in tracker order.
4. Conversations whose last turn ended with a reply he has not seen.

It says the count ("Three things need you"), reads the first, and
listens. "Skip" moves on; an answer moves on after it is sent. When the
queue is empty it says so and listens on the conversation used last.
The queue is built on the phone from data the app already syncs, so it
starts without waiting for a model.

## 6. iPhone voice mode

- **Entry.** A voice-mode button in the conversation toolbar, and one in
  the app shell that opens the queue.
- **Screen.** Full screen: the conversation's name and box, a large state
  indicator (listening, sending, working, speaking), the line being
  spoken as a caption, up to four buttons for the current item's labels,
  and End. Talk, or tap anywhere else, to interrupt. The screen stays
  awake while voice mode is on.
- **Scope.** Phase 1 works while the app is in front. Leaving the app or
  locking the phone pauses voice mode; coming back says anything that
  landed meanwhile.
- **Settings.** Voice (Emily, Harry, or on-device), speaking rate,
  "Talk over the agent" (on by default), and whether "more" is offered
  after each reply.

## 7. Speaking when Matron is not on screen

While Matron is in front (on the phone or on the CarPlay display) the app
is running, so a reply is spoken whenever it lands. Once Dan has switched
away or locked the phone, iOS suspends the app. Then:

- The app tells the journal that voice mode is on for this device
  (`voice_mode {until}`, renewed while it runs, cleared when it ends).
- When a `summary` event with `spoken` arrives for one of the user's
  conversations and a device has voice mode on, the journal synthesises
  the clip (`wav`, cut to 28 seconds) and sends that device a push with
  `mutable-content: 1` and a reference to the clip. The ordinary "Turn
  finished" push for that device is held for up to five seconds so the
  spoken one can replace it; if no spoken line arrives, the ordinary
  push goes as today. One notification per turn either way.
- The notification service extension downloads the clip (with the
  session token it reads from the shared keychain group) into the app
  group's `Library/Sounds` and sets it as the notification's sound. iOS
  plays it with the phone locked, through whatever the phone is routed
  to. The notification's text is the same spoken line.
- Tapping the notification, or the Matron icon in CarPlay, opens voice
  mode already listening on that conversation.

This is the technique payment apps use for spoken alerts. It is proved
with a spike before the rest of the phase is built, covering: phone
locked, CarPlay connected, a Driving Focus on, and AirPods. If it fails
any of them the fallback is a chime, and the line is spoken on return.

A Live Activity for the session ("bev is working", "bev has replied")
shows on the Lock Screen and the CarPlay Dashboard. It is optional in
this phase.

Self-hosted journals that push through the relay get the chime only; the
relay carries no content.

## 8. Hands-free with a screen: the stage

The same voice loop, with a second output. Where the no-screen mode can
only say "there's a table in the chat", the stage puts the table up.

### Exhibits

An **exhibit** is one showable thing from the turn. The app picks them
out with a deterministic extractor that shares its Markdown parse with
the cleaner: what the cleaner leaves out of speech is what the stage
shows.

| Exhibit | From |
|---|---|
| Image | Images and screenshots the agent attached during the turn |
| Text | A quoted draft (an email, a support reply), or a long quoted passage |
| Table | A Markdown table |
| Code or diff | A fenced block, or a diff card |
| Item | A tracker item handed to Dan: its title, and its options as large buttons |
| Prompt | An ask-user or permission prompt, with its options as large buttons |

Exhibits keep the order they have in the turn.

### The screen

One exhibit at a time, filling the screen, in large type, with nothing
around it except a thin strip: the conversation's name, the engine's
state, and "2 of 5". Images are shown whole and can be zoomed. Text is
set as large as fits; long text scrolls. With nothing to show, the stage
shows the short spoken line as a large caption.

The spoken line plays as in any voice mode. When a turn has exhibits the
engine adds a sentence it composes itself ("Three screenshots and a
draft are on screen").

### Moving around

Three ways, all doing the same things:

| Action | Voice | Clicker or keys | Hand gesture |
|---|---|---|---|
| Next or previous exhibit | "next", "back" | Right / left, page down / up | Swipe left or right |
| Jump to a kind | "show the screenshots", "show the draft" | — | — |
| Zoom | "bigger", "smaller" | + / − | — |
| Scroll long text | "down", "up" | Down / up, space | — |
| Move between an item's options | — | Right / left | Swipe |
| Choose an option | Say its label | Return | Pinch |
| Stop the agent talking | Talk over it, or "stop" | Escape | Open palm, held |
| Clear the stage | "clear" | — | — |

Choosing an option by clicker or gesture goes through the same
read-back as voice ("Sending: Go", three seconds to cancel), and a tool
permission still asks first (section 4).

**Clicker.** A presentation clicker or Bluetooth remote appears to the
Mac as a keyboard, so it needs no pairing code: the stage handles the
keys above. A trackpad's two-finger swipe does next and back as well.

### Hand gestures by webcam

The Mac's camera, or a webcam, watches for Dan's hand while the stage is
showing. Apple's Vision framework finds the hand's joints in each frame,
on the Mac. No frame is stored or leaves the machine, and there is no
third-party library.

- **Arming.** Arms swing when walking, so nothing counts until a hand is
  raised: an open hand held above chest height for about a third of a
  second arms the tracker. The strip at the edge of the stage shows a
  hand mark when a hand is seen and fills it when armed, so Dan can tell
  without guessing.
- **Swipe.** With the tracker armed, the hand moving across about a
  quarter of the frame within half a second is next or back.
- **Pinch.** Thumb and forefinger together chooses the highlighted
  option.
- **Open palm, held for a second,** stops the agent talking.
- After any gesture the tracker ignores the hand for 0.7 seconds, so one
  movement is one step.

The thresholds are starting values. They are tuned on the real
treadmill, and the phase begins with a spike there: walking pace, arm
swing, the camera's distance and the room's light all matter, and none
can be judged from a desk.

The camera runs only while the stage is showing and "Hand gestures" is
on in settings (the Mac's camera light is lit for that time). The Mac
app gains the camera entitlement and a usage string.

### Where it runs

The Mac app drives the big screen. It gains the voice engine (macOS 26,
for the same on-device speech APIs) and a voice-mode command that opens
the stage full screen on the chosen display. The stage itself is a
SwiftUI view in `MatronShared`, so the iPhone can host it later.
Microphone and speaker are whatever the Mac is using: its own, AirPods,
or a desk microphone. The Mac's existing voice-note hotkey is unchanged. The driving-safety rules in section 11 do not apply here; the
stage is never shown in CarPlay.

### Later: the agent's "show" tool

Automatic extraction shows everything in order; it cannot know which
piece matters. A later addition gives agents a bridge tool to say "put
these on screen, in this order". When a turn carries the agent's choice,
it replaces the automatic one; when it does not, extraction runs as
above. It is out of scope for this spec and gets its own short design
once the automatic stage has been used for a while.

## 9. CarPlay

### Category and entitlement

Matron applies as a **voice-based conversational app**
(`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4 or
later), the category added for assistants such as Claude and ChatGPT.
The rest of the app stays on iOS 18; the CarPlay scene is gated on 26.4.

Apple's rules for the category (CarPlay Developer Guide, June 2026) and
how the design meets them:

| Rule | Design |
|---|---|
| Voice is the primary modality on launch | The root is the voice-control screen, opening on the queue and listening |
| Hold an audio session only while voice features are in use | The session is released in `waiting` and `idle` |
| Don't show text or imagery in response to queries | The car screen never shows reply text: only state, a conversation name and buttons |
| At most three templates deep | Voice control, a list, nothing deeper |
| Recording only together with the voice-control template | The microphone opens only while that template shows |
| No wake word; cannot control the car or the phone | Not needed |

Not chosen: the **communication** category. Siri would read messages in
its own voice and take replies by its own dictation, the app could not
record, three SiriKit intents would be required, and Apple limits the
category to "short form text messaging". An app cannot hold both.

The category does not allow CarPlay notification banners. The spoken
notification in section 7 is a phone notification, heard through the
car's speakers; the Live Activity covers the visual side.

### Screens

- **Voice control (root).** One `CPVoiceControlState` per engine state,
  each with a short title ("Listening", "bev is working", "Speaking")
  and an animated symbol. Up to two action buttons, chosen by state: the
  current item's labels when there are exactly two, otherwise Skip and
  Stop. Navigation-bar buttons: Chats, and Needs you with its count.
- **Chats.** A list of recent conversations: title, box, and whether it
  is working or waiting. Choosing one returns to voice control, listening
  on it.
- **Needs you.** The queue as a list of titles. Choosing one reads it.

An item with three or four labels is answered by voice only; the labels
are spoken, not shown.

### Build

A `CPTemplateApplicationScene` and its delegate are added to the iOS
target, with the CarPlay scene in the Info.plist scene manifest and the
entitlement in the provisioning profile. The scene delegate owns a thin
adapter that maps engine state to templates and template buttons to
engine events. No voice logic lives in the CarPlay code.

Checks before building: the app's data must be readable with the phone
locked (the keychain items are already "after first unlock"; the
database's file protection needs confirming), and the reconnect path,
since CarPlay scenes disconnect and reconnect often.

### Entitlement request

Only the Account Holder can submit the form at
developer.apple.com/carplay. It asks for the category and a description
of the app. Draft:

> Matron is a client for conversational AI agents. In CarPlay the user
> speaks a request to an agent and hears a short spoken answer. Voice is
> the primary way to use it: the app opens to the CarPlay voice control
> template, already listening, and does not show the text of answers on
> the car display. The audio session is active only while the app is
> listening or speaking, and is released while the agent works so that
> other audio in the car resumes. The app has two levels of templates:
> the voice control screen and a list of conversations to choose from.
> It does not control vehicle or iPhone functions.

Apple does not publish how long approval takes. The request goes in at
the start of phase 1 so the wait runs alongside the build. Development
in the iOS Simulator's CarPlay window is expected to work before the
grant; running on a phone connected to a car needs it.

## 10. Siri

Siri is the hands-free way in. Apple allows no wake word for a CarPlay
voice app, but "Hey Siri" is one, and Siri can start Matron.

The hooks are App Intents, published as App Shortcuts, so they work as
soon as the app is installed with nothing for Dan to set up. They also
appear in Spotlight and the Shortcuts app and can be put on the Action
Button. They are not the SiriKit messaging intents, which belong to the
CarPlay communication category that was not chosen.

| Phrase | What happens | Phase |
|---|---|---|
| "Start voice mode in Matron" | Matron opens in voice mode on the queue, listening. On the Mac it opens the stage. | 1 |
| "What needs me in Matron" | Siri answers by itself, without opening the app: the count and the first thing's title. | 1 |
| "Tell bev in Matron …" | Siri takes the message with its own dictation and posts it to that conversation as text. | Later |

Apple requires the app's name in each phrase. Each shortcut has a few
phrasings ("Open Matron voice mode", "What's waiting in Matron").

Limits:

- Siri answers "what needs me" in its own voice, not Matron's, and gives
  only the count and a title. Hearing the summary and answering happen in
  voice mode.
- A shortcut that opens the app needs the phone unlocked. From a locked
  phone in a pocket, Siri will ask for Face ID. Whether CarPlay lifts
  that for an app on the car display is checked in the CarPlay phase.
- "Tell bev …" uses Siri's dictation, which does not know Matron's
  vocabulary, and has to match a conversation by spoken name. It is left
  for later; in voice mode the same thing is already possible.

In CarPlay, "Hey Siri, open Matron" needs no code at all: Siri launches
the app on the car display and the app starts listening.

## 11. Driving safety

These hold in voice mode everywhere, and are enforced by the engine
rather than by each screen:

- The car display never shows the text of a reply.
- A spoken reply is about fifteen seconds. Each "more" adds at most a
  minute, and going further always takes another spoken request.
- Every state change has a sound, so nothing needs a glance.
- The agent can be stopped by voice, so interrupting never needs a hand
  off the wheel. The tap remains for when a car's audio defeats that.
- Nothing is sent on an uncertain match without a spoken confirmation.
  Tool permissions are always confirmed.
- Anything that needs reading or typing (secrets, consent cards, diffs)
  is refused by voice and left in the tracker.
- Matron speaks unprompted only while voice mode is switched on, and
  voice mode ends itself after thirty minutes without an exchange.
- Lists in CarPlay hold at most twelve rows.

## 12. Errors

| Failure | Behaviour |
|---|---|
| No network when sending | Error sound, "No connection. I'll send it when you're back online." The recording is kept and retried, as a failed voice note is today. |
| Transcript late or unavailable | The recording is sent as a voice note; "Sent". |
| Cloud voice unavailable or over budget | The on-device voice speaks the same text. |
| No `spoken` line for a turn | The cleaner's version of the final message; "more" reads the message in sections. |
| The agent is busy when a message arrives | It is queued as today; "bev is busy. It will get this when it finishes." |
| A permission prompt expires unanswered | "That permission request timed out and was denied." |
| A call or Siri interrupts | The engine pauses and resumes when iOS allows. |

## 13. Phasing and compatibility

| Phase | Ships | Repos |
|---|---|---|
| 0 | Listening test of the cloud voices; a talking-over spike on the phone's loudspeaker at full volume and on AirPods; CarPlay entitlement request submitted | — |
| 1 | `SPOKEN` and `SPOKEN_MORE` in the summary pass; `POST /tts`; the voice engine; the iPhone voice-mode screen; items and prompts by voice; the queue; the two Siri shortcuts | bridge, journal, apple |
| 2 | Voice mode on the Mac and the stage: exhibits, the full-screen view, voice, clicker and keys. Then hand gestures by webcam, after a spike on the treadmill | apple |
| 3 | Spoken notification (after its spike); voice-mode presence; optional Live Activity | journal, apple |
| 4 | CarPlay scene on the same engine; talking-over tried in a real car | apple |

Phases 2 to 4 do not depend on each other, only on phase 1, so their
order can change. Phase 4 also waits on Apple granting the entitlement.

Each piece is safe against older neighbours: an old bridge sends no
`spoken` and the cleaner is used; a journal without `/tts` answers 404 or
501 and the on-device voice is used; old apps ignore the new payload
keys.

## 14. Testing

- **Bridge:** the prompt carries the `SPOKEN` and `SPOKEN_MORE` lines;
  parsing with and without them, and with `NONE`; the character caps;
  `spoken_ref` points at the last assistant message.
- **Journal:** `/tts` against a stubbed Azure: SSML escaping, the voice
  allow-list, cache hit, budget and concurrency limits, 501 with no key.
- **App:** the engine's state machine event by event; the command and
  label matcher against a table of utterances (including near-misses
  that must ask for confirmation); the cleaner against real messages
  with code, tables and links; the queue's ordering; talking over a clip
  (speech then words stops it, speech without words resumes it, repeated
  self-triggers switch it off for the route), driven by scripted detector
  and recogniser events; the exhibit extractor against real turns
  (images, a table, a quoted draft, an item) and stage navigation; the
  gesture recogniser against recorded sequences of hand positions (arm,
  swipe, pinch, palm, and arm-swing that must do nothing); the "what
  needs me" intent's answer for an empty queue, one thing and several.
- **Manual** (added to `manual-tests.md`): a full exchange on a phone;
  interrupting a clip by voice and by tap, on the loudspeaker and on
  AirPods; a cough during a clip; answering a two-button item; a
  permission prompt;
  flight mode mid-turn; the stage on the big screen driven by voice, by
  clicker and by hand gesture, walking; and each of the voice checks in
  the CarPlay simulator plus a locked phone.

## 15. Out of scope

- An agent "show" tool for the stage (a later addition).
- Sending a message to a named conversation through Siri (later).
- SiriKit messaging intents.
- The phone as a remote for the stage.
- The stage on iPhone, iPad or Apple TV.
- A wake word.
- Live, streaming speech-to-speech models.
- Voice mode on iOS 18 to 25.
- Spoken content through the push relay for self-hosted journals.
- Reading older messages or searching by voice.
