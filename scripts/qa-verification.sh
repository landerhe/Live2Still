#!/usr/bin/env bash
# Live2Still manual QA checklist (run on a physical device with Xcode Instruments).
set -euo pipefail

cat <<'EOF'
Live2Still QA verification checklist
====================================

Build (simulator):
  xcodebuild -scheme Live2Still -destination 'platform=iOS Simulator,name=iPhone 17' build

Memory (Instruments → Allocations / Leaks):
  - Scroll album grid for 2+ minutes
  - Swipe through 50+ cards
  - Pass: no unbounded memory growth

CPU (Instruments → Time Profiler):
  - Scroll grid, swipe, batch convert
  - Pass: no multi-second main-thread hangs during scroll

Energy (Instruments → Energy Log):
  - 5 min swipe + live preview hold/release
  - Pass: no sustained high CPU when idle; playback stops on release

UX:
  - Deny photos → Open Settings → grant → return: library loads
  - Album Queue badge opens queue sheet (not Swipe-only)
  - Queue Apply: progress visible; sheet dismisses when done
  - Denied screen: primary button is Open Settings (not misleading Allow)
  - Welcome Continue works while library is still scanning
  - Select All shows confirmation with count
  - Swipe Undo restores last card
  - Swipe Again keeps existing queue
  - Long-press album cell opens preview; hold plays Live motion
  - Cancel system delete after convert: stills remain
  - About → Privacy Policy opens in-app

Accessibility:
  - VoiceOver: grid items include date; swipe custom actions work
  - Largest Dynamic Type: action bars and queue summary readable

Regression:
  - Convert 1/N with/without remove original
  - Limited library: Add Photos
  - Partial batch failure → Retry retries failed IDs only
  - Offline / On this device only filter

App Store listing:
  - See APP_STORE_CHECKLIST.md for Connect URLs, screenshots, and review notes

EOF
