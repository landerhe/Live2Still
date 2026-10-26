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
  - First-use retention choice explicitly defaults to keeping originals
  - Select All shows confirmation with count
  - Swipe Undo restores last card
  - Continue Next Batch excludes reviewed IDs; Review Again preserves pending queues
  - Tap album cell opens preview; hold plays Live motion
  - Cancel system delete after convert: stills remain
  - About → Privacy Policy opens in-app

Accessibility:
  - VoiceOver: grid items include date; swipe custom actions work
  - Largest Dynamic Type: action bars and queue summary readable

Regression:
  - Convert 1/N with/without remove original
  - Limited library: Add Photos
  - Partial batch failure → Retry retries failed IDs only; Last Conversion survives relaunch
  - Queued Still/Delete decisions survive relaunch in Swipe and Clean Up
  - Keep cancels an earlier queued action; Undo restores the earlier checked state
  - Edited/current-key-photo output matches what Photos displays
  - Date/location/favorite/hidden/albums verified before removal
  - Conversion: cancel, background expiration, force quit, low disk; originals retained
  - Deleted/unverifiable earlier output: no silent duplicate; explicit fresh-copy/keep choice
  - Local/cloud scope changes preserve pending actions outside display scope
  - Clean Up: left=still (Live only), right=keep, down=delete; Undo has a separate button
  - Analysis failures are retryable and are not cached as no matches
  - Release requires real-device iCloud/edited/key-photo material and accessibility checks
  - Offline / On this device only filter

App Store listing:
  - See APP_STORE_CHECKLIST.md for Connect URLs, screenshots, and review notes

EOF
