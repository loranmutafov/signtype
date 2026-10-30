# SignType

Tap **fn** three times. The camera comes on in a small floating window. Sign to it. The text lands wherever your cursor is.

A macOS menu-bar app, in the spirit of Wispr Flow but for sign language. Everything runs on-device
(Apple's Vision hand-pose model plus a small classifier), with an optional Gemma 4 cloud mode.

> Hackathon-grade. Two recognisers, both on-device:
> * **Fingerspelling** of the 24 static letters out of the box, from hand-written geometry rules.
>   Spend two minutes in **Teach ▸ Letters** and it uses *your* hand as the reference instead, which is much better.
> * **Whole-word signs** you teach it: perform "hello" a few times in **Teach ▸ Words** and it will
>   recognise it from the motion of both hands relative to your shoulders and face.
>
> Anything that moves but matches no taught word is dropped, or, in **Hybrid** mode, sent to Gemma 4.

## Build (on your Mac)

Requires Xcode 15 or later (for the Swift 5.9 toolchain and the macOS 13 SDK). Works on Intel and Apple Silicon; an M1 Pro is plenty.

```bash
git clone https://github.com/loranmutafov/signtype
cd signtype
scripts/build.sh
open build/SignType.app
```

**Signing matters.** macOS ties the Accessibility and Camera grants to the app's code signature. With
ad-hoc signing the signature changes on every build, so the app is "new" each time and asks again
(the toggle in System Settings looks on, but no longer matches). The build script therefore looks for
a stable identity: an `Apple Development` certificate if you have one, or a free self-signed one.

To make the free one, once: Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…
Name `SignType Dev`, Identity Type `Self Signed Root`, Certificate Type `Code Signing`. Rebuild;
the script picks it up. You can also force an identity:

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build.sh
```

After switching identities, clear the stale grants once and re-grant; from then on they survive rebuilds:

```bash
scripts/reset-permissions.sh
```

## First run

macOS will ask for two permissions. Both are needed.

| Permission | Why |
|---|---|
| Camera | to see your hands |
| Accessibility | to hear the fn key from any app and to type into other apps |

Accessibility covers keyboard event taps too, so no separate Input Monitoring grant is required.

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

Whole-word signs you have taught are typed as words (with a trailing space) the moment your hands come to rest.
While a hand is moving the skeleton turns orange and letters are paused, so a sign never gets typed as a
jumble of letters on the way.

Four modes, chosen from the menu:

- **Live (on-device)**: letters and taught words are typed as they are recognised. Unknown motion signs are dropped ("?" in the preview).
- **Batch, type at the end (on-device)**: same recognition, but everything accumulates in the preview and is typed when you stop.
- **Hybrid: on-device, Gemma 4 for unknown signs**: like Live, but a motion sign that matches none of your taught words is sent to Gemma 4 (just that second or two of frames, plus the text so far as context). Gemma's word is typed in the right place; if it answers "?" nothing is typed. Output stays in signing order even while a lookup is in flight.
- **Batch via Gemma 4 (cloud)**: about two frames per second of the whole session go to Gemma 4 when you stop, with the on-device transcript as a hint.

Gemma modes need an API key in Settings. The model defaults to `gemma-4-26b-a4b-it`; `gemma-4-31b-it` is the bigger one.
Those two modes are the only ones that send anything off the machine, and Hybrid only sends the unknown bits.

## Teach it your signing

Menu ▸ **Teach letters…** opens a window with two tabs.

**Letters.** Pick a letter, hold the sign, press Record. Two seconds of hand poses are stored.
Do two or three recordings per letter from slightly different angles and distances. Taught letters take
priority over the built-in rules. The tab shows the live prediction and the rule classifier's top three
guesses, which is the quickest way to debug a letter that keeps misreading.

**Words.** Type the word, press Record sign, perform the sign once at normal speed, and come to a clear stop.
The app waits for a motion segment (a hand travelling at least about half a shoulder width, then stopping)
and stores the trajectory of both hands in shoulder-centred coordinates, resampled to 30 steps. Record each
word two or three times. Keep your shoulders in frame; if they are not, it falls back to your ears and nose
to place the frame. The tab shows every segment it sees with its nearest taught words and their distances,
so you can tell whether a sign is being segmented at all and how close it is to matching.

Samples are plain JSON in `~/Library/Application Support/SignType/` (`templates.json` for letters,
`motions.json` for words), easy to share with a teammate or reset.

## How it works

```
fn ×3 (CGEvent tap) ─▶ AVCaptureSession 640×480, ~15 fps
                         ▼
       Vision: hand pose ×2 (21 landmarks each) + body pose (upper body), on-device
                         │
         ┌───────────────┴────────────────────┐
         ▼                                    ▼
 HandFeatures (primary hand)        MotionFrame (both hands in a shoulder-centred
 wrist-centred, palm-scaled,        frame: wrist position + fingertip layout)
 rotated upright, mirrored                    ▼
         ▼                          MotionSegmenter: wrist speed → "a sign happened"
 Classifier: kNN over taught                  ▼
 samples, else geometry rules       MotionMatcher: DTW vs taught templates
         ▼                                    │ no match + Hybrid mode
 Decoder: stable-frame letters,               ▼
 paused while hands move            Gemma 4: frames of that segment → word, or "?"
         └───────────────┬────────────────────┘
                         ▼
             OutputQueue keeps signing order ─▶ Typist: CGEvent unicode key events
```

Source map:

| File | Role |
|---|---|
| `HotkeyMonitor.swift` | fn triple-tap via a listen-only CGEvent tap |
| `CameraSession.swift` | capture session, JPEG encoder for the cloud path |
| `HandPoseTracker.swift` | Vision hand pose (two hands) + body pose → `FrameObservation` |
| `HandFeatures.swift` | letter normalisation and geometry helpers |
| `Classifier.swift` | rule classifier, kNN, ensemble (letters) |
| `MotionSigns.swift` | body frame, motion features, segmenter, DTW matcher, ordered output queue (words) |
| `Decoder.swift` | temporal smoothing into letters and spaces |
| `Typist.swift` | synthetic typing |
| `SessionController.swift` | glues it together, modes, auto-stop |
| `OverlayPanel.swift` | floating non-activating preview |
| `TeachWindow.swift`, `SettingsWindow.swift` | SwiftUI windows |
| `GemmaClient.swift` | Gemini API call for Gemma 4 |

## Known limits and next steps

- J and Z are motion letters: teach them on the Words tab as "j" and "z" (they will be typed with a trailing space, which is wrong mid-word; a per-word "no space" flag is a small follow-up).
- Letter rules are tuned blind. If a letter is stubborn, teach it; then look at the rule scores in the teach window and adjust the thresholds in `Classifier.swift`.
- Word recognition is template matching, so it only knows signs you have taught it (realistically a few dozen). Segmentation thresholds (`MotionSegmenter`) and the match distance (`MotionMatcher.maxDistance`, 0.6) were set without a camera; the Words tab prints every segment's distance so they are quick to tune.
- No facial expression or mouth shape, which carry grammar in real ASL.
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

## Licence

Apache License 2.0. See [LICENCE](LICENCE). Permissive (no copyleft), with an explicit patent licence
from every contributor and termination of that licence for anyone who brings a patent claim over the code.
