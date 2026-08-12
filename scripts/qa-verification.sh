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
  - Queue Apply: progress visible; sheet dismisses when done
  - Denied screen: primary button is Open Settings (not misleading Allow)

Accessibility:
  - VoiceOver: grid items include date/index; swipe custom actions work
  - Largest Dynamic Type: action bars and queue summary readable

Regression:
  - Convert 1/N with/without remove original
  - Limited library: Add Photos
  - Partial batch failure → Retry in alert

EOF
