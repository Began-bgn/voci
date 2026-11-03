---
# gstack: design-md-format=spec
name: Voci
description: A quiet macOS system HUD that shows color only while the mic is live and vanishes once the English lands in your chat.
colors:
  record: "#FF453A"
  success: "#30D158"
  error: "#FF9F0A"
  hud-dark: "rgba(36,36,38,0.78)"
  hud-light: "rgba(246,246,248,0.80)"
  hud-stroke-dark: "rgba(255,255,255,0.10)"
  hud-stroke-light: "rgba(0,0,0,0.08)"
  text: "labelColor"
  text-muted: "secondaryLabelColor"
  accent: "controlAccentColor"
typography:
  pill:
    fontFamily: SF Pro Text
    fontWeight: 500
    fontSize: 13pt
  body:
    fontFamily: SF Pro Text
    fontSize: 13pt
    lineHeight: 1.45
  label:
    fontFamily: SF Pro Text
    fontSize: 11pt
  mono:
    fontFamily: SF Mono
    fontSize: 12pt
    fontFeature: tnum
rounded:
  sm: 5px
  md: 8px
  lg: 10px
  full: 9999px
spacing:
  xs: 4px
  sm: 8px
  md: 14px
  lg: 20px
components:
  pill:
    backgroundColor: "{colors.hud-dark}"
    textColor: "{colors.text}"
    rounded: "{rounded.full}"
    height: 36px
    padding: 8px 14px
    gap: 8px
  pill-record-dot:
    backgroundColor: "{colors.record}"
    size: 8px
  level-bar:
    backgroundColor: "{colors.text}"
    width: 3px
    gap: 2px
    height: 4px to 18px
  settings-group:
    rounded: "{rounded.md}"
---

# Voci

## Overview

**Creative North Star:** a macOS system HUD that happens to speak Romanian. It looks like part of the OS, so the only thing that ever pulls your eye is the red "mic is live" dot.
**Product context:** native macOS menu-bar utility (SwiftUI + AppKit). Press ⌃⌥Space, speak Romanian, and polished English is pasted into the chat box of the front app. Single user: a Romanian speaker who writes to AI tools all day. Peers: Wispr Flow, Superwhisper, Spokenly, Lispr.
**Mode per surface:** Pill = Operate (glanceable status, about 1 to 30 s). Settings = Operate (set once, rarely revisited). Menu = Operate.
**Reference sites:** https://wisprflow.ai/, https://superwhisper.com/, https://spokenly.app/dictation-for-mac, https://lispr.ai/ (marketing pages; their in-app pills were not visible in the screenshots).
**Key characteristics:**
- It disappears: native materials, system faces, no brand color.
- Color means state: red = recording, green = pasted, orange = needs you.
- Text only when it adds information you can't see (working, errors).
- Every failure names the way back.

## Colors

**Strategy:** Restrained. The neutrals are system materials and semantic colors (`labelColor`, `secondaryLabelColor`, `controlAccentColor`), so they track the user's appearance, accent and Increase Contrast settings. The three signal colors are Apple's system red, green and orange (dark-appearance values), each with exactly one meaning.
**Light or dark:** follows the system. The pill floats over whatever app you are in, so it matches the system appearance through HUD vibrancy (`NSVisualEffectView` material `.hudWindow`, or SwiftUI `.ultraThinMaterial`) instead of always being black.
Red appears only while recording, never for errors: an error that lost nothing (no text box, clipboard holds the English) must not look like data loss. The level bars and spinner use the label color, so they stay legible over light and dark windows.

## Typography

System faces on purpose: SF Pro Text and SF Mono, from `/System/Library/Fonts/SFNS.ttf` and `SFNSMono.ttf`, used through `.system(...)` and `.monospaced` design. These are licensed for apps on Apple platforms. This deliberately departs from the gstack "pick a real typeface" rule: on a native utility whose goal is to blend into macOS, a custom face would be the thing that stands out.
Four sizes only: pill 13pt Medium, settings body 13pt (system controls), hints 11pt secondary, mono 12pt for the shortcut label and model ID. Use tabular numerals for the silence value ("3.0 s").

## Layout

- **Pill:** content-sized width, 36pt tall, centered horizontally, 8pt below the menu bar on the screen under the pointer. Multi-line error text wraps to a maximum of 280pt wide and grows in height.
- **Settings:** 460pt-wide standard grouped `Form`, fixed frame. Groups: key, shortcut and silence, toggles, model. One level of grouping, rows separated by hairlines.
- **Menu:** standard `NSMenu`, no custom views.

## Elevation & Depth

The pill is the only floating layer: HUD vibrancy plus a 0.5pt stroke (`hud-stroke-*`) and a soft offset shadow (0 4px 14px, 18% black). No zero-offset glow. The Settings window uses the default window shadow.

## Shapes

The pill is a full capsule. Settings groups use an 8pt radius, inputs 5pt. Level bars are 3pt-wide capsules. Nothing else is rounded.

## Components

- **Pill, listening:** 8pt red dot + 5 level bars driven by the real mic RMS, no text. Bars range from 4pt to 18pt with 80 ms ease-out smoothing.
- **Pill, working:** small `ProgressView` + "Translating". Neutral colors only.
- **Pill, pasted:** the bars collapse (120 ms ease-in) into a green checkmark, held about 600 ms, then the pill exits.
- **Pill, nowhere to paste:** orange `exclamationmark.triangle.fill` + "No text box in this window — English copied to clipboard", held 3 s.
- **Pill, failed:** orange triangle + the cause + the way back, e.g. "No internet — use “Retry last recording” in the menu", held 3 s.
- **Pill invariants:** non-activating panel, never takes focus, ignores mouse events, never shows after a successful paste.
- **Menu-bar icon:** monochrome template image, so macOS tints it in light, dark and highlighted states.
- **Settings controls:** system controls only, with the system accent color. The shortcut recorder shows the keys in SF Mono.

## Do's and Don'ts

- Do: show red only while the mic is recording.
- Do: drive the level bars from the real mic level, never a looping animation.
- Do: give every error message a way back (Retry, clipboard, Settings).
- Do: follow the system appearance, accent and Reduce Motion settings.
- Don't: add a brand color, gradient or glow to the pill or the icon.
- Don't: show a "Listening…" label; the red dot already says it.
- Don't: keep the pill visible after a successful paste, or steal focus during dictation.
- Don't: use yellow for errors (low contrast on light HUD); use system orange.

## Motion

- **Approach:** minimal-functional.
- **Easing:** enter(ease-out) exit(ease-in) move(ease-in-out)
- **Duration:** micro(80ms level bars) short(150ms enter, 200ms exit) medium(600ms success hold)
- **Enter/exit:** opacity 0 to 1 and scale 0.96 to 1. With Reduce Motion, fade only.
- **The one authored moment:** on paste, the level bars collapse into a green check, then the pill fades away.

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-11-03 | Initial design system created | Created by /design-consultation from product context and research on Wispr Flow, Superwhisper, Spokenly and Lispr; north star "it disappears" |
| 2026-11-03 | System faces (SF Pro, SF Mono) instead of a custom typeface | A native utility that should blend into macOS; a custom face would stand out |
| 2026-11-03 | No "Listening…" text, no brand color, pill follows system appearance | The three accepted risks, all serving "it disappears" |
