# SignType

Tap **fn** three times. The camera comes on in a small floating window. Sign to it. The text lands wherever your cursor is.

A macOS menu-bar app, in the spirit of Wispr Flow but for sign language. Everything runs on-device
(Apple's Vision hand-pose model plus a small classifier), with an optional Gemma 4 cloud mode.

> Hackathon-grade. ASL **fingerspelling** of the 24 static letters (no J or Z yet: they need motion).
> Out of the box it uses hand-written geometry rules, which are serviceable but fussy. Spend two
> minutes in **Teach letters…** and it uses *your* hand as the reference instead, which is much better.

## Build (on your Mac)

Requires Xcode 15 or later (for the Swift 5.9 toolchain and the macOS 13 SDK). Works on Intel and Apple Silicon; an M1 Pro is plenty.

```bash
git clone https://github.com/loranmutafov/signtype
cd signtype
scripts/build.sh
open build/SignType.app
```

If you have an Apple Development certificate, sign with it so macOS does not forget your permission
grants after every rebuild (ad-hoc signatures change on each build):

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build.sh
```

## First run

macOS will ask for three permissions. All three are needed.

| Permission | Why |
|---|---|
| Camera | to see your hands |
| Accessibility | to type into other apps (synthetic key events) |
| Input Monitoring | to hear the fn key from any app |

Then one keyboard setting: **System Settings ▸ Keyboard ▸ "Press 🌐 key to" → Do Nothing**.
By default macOS starts Dictation on a double tap of fn, which gets in the way of a triple tap.
If you already use Wispr Flow you have done this.

Open **Settings…** from the menu-bar hand icon to see which permissions are granted.

## Use

1. Put the cursor where you want text (Notes, Slack, a terminal, anywhere).
2. Tap fn three times. A small preview appears bottom-right with a green hand skeleton.
3. Fingerspell. Hold each letter still for about half a second; the ring around the letter fills up and the letter is accepted.
   - Same letter twice: sign it, drop or relax the hand briefly, sign it again.
   - Space: keep the hand out of view for a little over a second.
4. Tap fn three times to finish, or just lower your hand for 4 seconds and it stops on its own.

Three modes, chosen from the menu:

- **Live letters (on-device)**: each letter is typed the moment it is accepted. Most fun; most garbage if a letter misreads.
- **Batch, type at the end (on-device)**: letters accumulate in the preview, and everything is typed when you stop.
- **Batch via Gemma 4 (cloud)**: about two frames per second are kept while you sign. When you stop, the frames plus the on-device guess go to Gemma 4 through the Gemini API, and its transcript is typed. Needs an API key in Settings. Model defaults to `gemma-4-26b-a4b-it`; `gemma-4-31b-it` is the bigger one. This mode is the only one that sends anything off the machine.

## Teach it your hand

Menu ▸ **Teach letters…**. Pick a letter, hold the sign, press Record. Two seconds of hand poses are stored.
Do two or three recordings per letter from slightly different angles and distances. Taught letters take
priority over the built-in rules. Samples are plain JSON in `~/Library/Application Support/SignType/templates.json`,
so they are easy to share or reset.

The teach window shows the live prediction and the rule classifier's top three guesses, which is also the
quickest way to debug a letter that keeps misreading.

## How it works

```
fn ×3 (CGEvent tap) ─▶ AVCaptureSession 640×480
                         │ ~15 fps
                         ▼
             Vision VNDetectHumanHandPoseRequest  (21 landmarks, on-device)
                         ▼
             HandFeatures: wrist-centred, palm-length-scaled, rotated upright,
                           mirrored for left hands  (+ real on-screen orientation)
                         ▼
             Classifier: kNN over your taught samples, falling back to
                         fuzzy geometry rules for the 24 static letters
                         ▼
             Decoder: letter accepted after N stable frames, gap for repeats,
                      space after ~1.2 s with no hand
                         ▼
             Typist: CGEvent keyboard events with a unicode payload → frontmost app
```

Source map:

| File | Role |
|---|---|
| `HotkeyMonitor.swift` | fn triple-tap via a listen-only CGEvent tap |
| `CameraSession.swift` | capture session, JPEG encoder for the cloud path |
| `HandPoseTracker.swift` | Vision hand pose → 21 points |
| `HandFeatures.swift` | normalisation and geometry helpers |
| `Classifier.swift` | rule classifier, kNN, ensemble |
| `Decoder.swift` | temporal smoothing into letters and spaces |
| `Typist.swift` | synthetic typing |
| `SessionController.swift` | glues it together, modes, auto-stop |
| `OverlayPanel.swift` | floating non-activating preview |
| `TeachWindow.swift`, `SettingsWindow.swift` | SwiftUI windows |
| `GemmaClient.swift` | Gemini API call for Gemma 4 |

## Known limits and next steps

- J and Z are motion letters. Easiest add: track the index-tip trajectory while I or D is held, match a hook or a zigzag.
- Rules are tuned blind. If a letter is stubborn, teach it; then look at the rule scores in the teach window and adjust the thresholds in `Classifier.swift`.
- Only fingerspelling. Full-sign (word-level) recognition on-device would need a sequence model over landmark windows; the Gemma mode is the shortcut for that today.
- Typing goes through Accessibility events, so secure text fields (password prompts) ignore it.
- The overlay is pinned bottom-right of the main display. Drag it anywhere; it does not steal focus.

## Debugging

Every fn event the app sees, every start/stop and why, goes to unified logging:

```bash
log stream --predicate 'subsystem == "dev.loran.signtype"' --level debug
```

Some keyboards deliver more than one fn event per press; the hotkey monitor de-duplicates
those and ignores fn for a second after each trigger, and a session cannot be stopped by the
hotkey within its first 1.5 s.
