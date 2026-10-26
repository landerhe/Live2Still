# Live2Still 📸

> **Convert Apple Live Photos to lightweight stills, reclaim your device storage, and keep 100% of your privacy.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: iOS](https://img.shields.io/badge/Platform-iOS%2026%2B-green.svg)]()
[![Tests: 68 passed](https://img.shields.io/badge/Tests-68%20passed-brightgreen.svg)]()
[![Privacy: Zero Tracking](https://img.shields.io/badge/Privacy-100%25%20On--Device-success.svg)]()

---

## 🌟 Why Live2Still?

Apple Live Photos capture a 3-second high-definition video (`.mov`) paired with every still photo (`.heic`/`.jpeg`), easily consuming **2x to 3x more storage space** than standard still images. Over years of photography, Live Photos quietly bloat device and iCloud storage.

Existing photo cleaning apps on the App Store often charge steep weekly/monthly subscriptions, bombard users with ads, or require questionable cloud access. 

**Live2Still** is an open-source, private, native iOS application designed to solve this problem gracefully:
- **On-Device First**: 100% processed locally on your iPhone using Apple's official `PhotoKit`. Zero telemetry, zero analytics, zero external network requests.
- **Accurate Key Frame & Metadata**: Preserves full Exif data (date, location, orientation, color space, camera settings) and exports the exact current key photo (including edits).
- **Safe by Design**: Atomic operations, crash-resilient journal logging, and explicit confirmation before removing original Live Photos.

---

## ✨ Features

- **🖼️ Smart Album Grid**:
  - Filter your library to view all Live Photos or only those stored locally on-device.
  - Long-press / 3D Touch preview to view Live motion before converting.
- **⚡ Swipe Review Queue**:
  - Intuitive card swipe workflow: swipe left to convert to still, swipe right to keep, swipe down to queue for deletion.
  - Non-destructive queue: review all queued decisions in a batch sheet before applying.
  - Multi-level undo support.
- **🛡️ Data Safety & Integrity**:
  - Safe conversion pipeline: verifies the newly saved still photo in the photo library before any original is deleted.
  - Atomic journal logging (`ConversionJournalStore`): gracefully recovers from low-memory interruptions or background kills.
  - Supports both Full Library Access and Limited Photo Selection modes.

---

## 🏗️ Architecture

```
Live2Still/
├── Core Domain & Stores
│   ├── LivePhotoConverter.swift        # Core PhotoKit conversion & export pipeline
│   ├── LocalAssetIndexStore.swift      # High-performance metadata caching & indexing
│   ├── PhotoCleanupStore.swift         # Queue state machine (Still / Keep / Delete)
│   ├── ConversionJournal.swift         # Transaction logging & atomic rollback protection
│   └── PhotoResourceIO.swift           # Safe file operations & image decompression
├── Views & Presentation
│   ├── ContentView.swift               # Root navigation shell
│   ├── LivePhotoGridView.swift         # Lazy grid album browser with sizing cache
│   ├── LivePhotoReviewView.swift       # Interactive swipe-card deck review interface
│   ├── LivePhotoQueuedReviewSheet.swift# Batch queue confirmation sheet
│   └── LivePhotoAboutViews.swift       # In-app privacy disclosure & settings
└── Tests
    └── Live2StillTests/                # Comprehensive unit & regression test suite (68 tests)
```

---

## 🚀 Building & Testing

### Prerequisites
- macOS Sonoma / Sequoia
- Xcode 16+
- iOS Simulator or physical iPhone running compatible iOS version

### Run Unit Tests
```bash
# Clone the repository
git clone https://github.com/landerhe/Live2Still.git
cd Live2Still

# Run tests via command line
xcodebuild test \
  -project Live2Still.xcodeproj \
  -scheme Live2Still \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

---

## 🔒 Privacy Guarantee

Live2Still adheres to the strictest privacy principles:
- **No Third-Party SDKs**: No Google Firebase, no Meta SDK, no ads, no trackers.
- **No Network Requests**: All image decoding, keyframe extraction, and metadata replication stay entirely inside the local iOS sandbox.
- **No Hidden Deletions**: Deleting original Live Photos is strictly optional and requires explicit confirmation through standard iOS PhotoKit system dialogs.

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.
