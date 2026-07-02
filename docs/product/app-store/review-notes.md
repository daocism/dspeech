# App Review notes (paste into ASC "Notes" for the review team)

Draft — paste-ready English for the App Review information field. No credentials are
needed: the app has no accounts, no login, no server of its own.

---

Dspeech is a receive-only cockpit aid for pilots: it listens to air-traffic-control
audio and shows a live on-device transcript. It never transmits anything on air and
never sends audio or transcripts off the device (see the bundled privacy manifest;
processing is Apple's on-device speech recognition).

**What you will see on first launch:** a four-card intro (advisory-only notice,
receive-only, on-device privacy, audio-input guidance), then the main screen with a
clearly labeled DEMO transcript illustrating the display format. The DEMO badge marks
illustrative content; it disappears permanently after the first real session.

**To exercise live transcription without aviation audio:** tap the microphone button,
grant microphone + speech-recognition permissions, and read any sentence aloud — for
example: "November one two three alpha bravo, descend and maintain three thousand."
The words appear live and persist as a card when you pause. Session history (clock
icon) stores transcripts locally; Settings shows the privacy mode (LOCAL badge is
always visible on the main screen).

**Optional model downloads:** Settings offers an alternative on-device recognition
model (WhisperKit) and a speaker-identification pack. Both are optional multi-hundred-
megabyte downloads of public model files from huggingface.co, SHA-256-verified, used
strictly on device. The app is fully functional without them.

**Advisory nature:** the app states in onboarding and in the store description that
transcripts can be wrong and never replace listening to the radio. It is a situational
awareness aid, not certified avionics.
