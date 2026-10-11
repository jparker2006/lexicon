# Indicator prototype

Throwaway prototype for [Recording indicator and sounds (#29)](https://github.com/jparker2006/lexicon/issues/29). It answers one question: what do the recording indicator and its sounds look and sound like? Not production code.

Run it (Command Line Tools only, no Xcode):

```sh
./prototypes/indicator/run.sh
```

It builds `build/LexiconIndicator.app` with `swiftc`, signs it with "Lexicon Dev" if that identity exists (ad-hoc otherwise), and opens a demo panel plus a menu bar icon. Quit from the menu bar icon. No fn key, mic or Accessibility needed; the audio level is faked.

## Demo panel

- **Look**: A, bottom pill (floating at bottom center, like Wispr Flow). B, a smaller pill near the cursor (the mouse stands in for the caret). C, menu bar only. Every look also updates the menu bar icon.
- **Sounds**: system sounds (Tink start, Pop stop, Morse landed, Glass warning, Funk error) or synth tones (60 to 160 ms sine blips from a warm AVAudioEngine: rising pair to start, falling pair to stop, a tiny high tick for landed, three beeps for the warning, a low falling pair for error). Sounds on checkbox and a volume slider, 25% by default.
- **Sequences**: Auto play (start chime, held 3 s, finishing 0.4 s, landed, fade), the same hands-free, and one that ends in "Nothing typed".
- **States**: held, hands-free (lock and "Tap fn to stop"), finishing (bars settle into gray dots that ripple), landed (green check, fades out by 0.45 s), paste-last ("Not typed. Press Control-Command-V to paste it.", 4.5 s), one-minute warning (orange dot and "1 min left"), error.

Reduce Motion skips fades, pulses and ripples. Colors follow light and dark mode.

Screenshots are in `screenshots/`. For more: `run.sh --look A|B|C --state held|handsfree|finishing|landed|paste|warning|error`.

## Open questions for Jake

- Paste-last plays no sound of its own (the stop chime already played). Should it?
- The menu bar icon draws red, orange, green or blue in color while active, because the menu bar ignores the tint on template images. Fine, or keep it monochrome?
- The synth engine runs all the time so cues have no delay. That costs a little idle CPU; the real app would start it on fn-down.
