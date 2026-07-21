# Minidisc

> Your music server, pocket-sized. A simple, ergonomic Subsonic client that feels right at home on iOS.

[![License: MPL 2.0](https://img.shields.io/badge/license-MPL--2.0-brightgreen.svg)](LICENSE)
[![Release](https://github.com/Loriage/Minidisc/actions/workflows/release.yml/badge.svg)](https://github.com/Loriage/Minidisc/actions/workflows/release.yml)
[![Platform](https://img.shields.io/badge/platform-iOS%2026%2B-blue.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)

---

## What is Minidisc?

Minidisc is a native Swift / SwiftUI music client for iOS, built for people who run their own music server. It speaks the Subsonic and OpenSubsonic API, so it works with [Navidrome](https://www.navidrome.org) and any other compliant server.

Minidisc is a fork of [Cassette](https://github.com/CassetteLab/cassette), with one goal: **keep everything that made it great, drop everything that got in the way, and make it feel truly at home on iOS.** One app, one platform, no clutter — simple, ergonomic, iOS-first.

It's a pure streaming client for *your* library — no accounts, no subscriptions, no tracking. Your music stays between your device and your server. Releases ship as an unsigned `.ipa` for sideloading.

Licensed under MPL-2.0.

---

## Features

**Listening**
- Native iOS 26 client with a Liquid Glass design language
- Background playback with lock screen and Control Center controls, plus AirPlay
- True offline mode: download albums, playlists, or individual tracks
- Playback powered by the AudioStreaming engine — FLAC, MP3, AAC, WAV, and Ogg/Vorbis
- Persistent playback session — pick up where you left off after relaunching
- Lyrics support
- Shuffle, repeat, and full queue management

**Library**
- Personalized Home feed: top picks, recently played, and genre shelves
- Browse by playlists, artists, albums, downloads, and favorites
- Pinned albums and playlists
- Full-text search across your library
- Favorites synced with your server (star / unstar)
- **Wrapped** — a yearly recap of your listening

**Integrations & extras**
- **ListenBrainz** — scrobble your listens and surface recommendations (fresh releases, similar artists)
- **AudioMuse-AI** — weekly mood playlists built from how your music actually sounds

**Server & privacy**
- Subsonic and OpenSubsonic API, with OpenSubsonic extensions where available
- Custom HTTP headers for servers behind a reverse proxy (Cloudflare Access, Authelia, etc.)
- Credentials stored only in the iOS Keychain — zero tracking, zero analytics, all traffic direct to your server

---

## Installation

### iOS — Sideloading

Download the unsigned `.ipa` from the [GitHub Releases](../../releases) page and install it with AltStore, Sideloadly, or any sideloading tool — it gets re-signed with your own Apple ID during installation.

### Build from source

1. **Requirements**
   - macOS 15 or later with Xcode 26 or later
   - A Subsonic / OpenSubsonic / Navidrome server to connect to
   - An Apple Developer account (the free tier works for personal device builds)

2. **Clone and open**
   ```bash
   git clone https://github.com/Loriage/Minidisc.git
   cd Minidisc
   open Minidisc.xcodeproj
   ```
   Swift Package Manager resolves the dependencies (SwiftSonic and AudioStreaming) automatically — no extra setup.

3. **Sign and run**
   - Select your team in Signing & Capabilities
   - Choose an iOS 26+ device/simulator
   - Build and run (⌘R)

4. **First launch**
   - Minidisc prompts for your server URL, username, and password
   - If your server sits behind a reverse proxy that needs custom request headers, expand **Advanced** and add them
   - Tap **Connect** — Minidisc verifies the connection and stores credentials in the Keychain

---

## Requirements

- iOS 26.1 or later
- A running Subsonic, OpenSubsonic, or Navidrome server

---

## Server compatibility

Minidisc works with any server that implements the Subsonic / OpenSubsonic API, and uses OpenSubsonic extensions where available. [Navidrome](https://www.navidrome.org) is the recommended and primary-tested server.

If your server implements the Subsonic API and something doesn't behave, [open an issue](https://github.com/Loriage/Minidisc/issues).

---

## Architecture

For developers curious about the internals:

- **UI** — SwiftUI views with `@Observable @MainActor` view models; no business logic in views.
- **Services** — Swift actors (`PlayerService`, `LibraryService`, `DownloadService`, `FavoritesService`, `NowPlayingService`, …) with no SwiftUI / UIKit imports.
- **Playback** — the [AudioStreaming](https://github.com/dimitris-c/AudioStreaming) engine, wired to `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for lock screen, Control Center, and AirPlay.
- **Subsonic API** — [SwiftSonic](https://github.com/CassetteLab/swiftsonic) (MIT) handles all Subsonic / OpenSubsonic communication.
- **Persistence** — SwiftData for app data (downloads, playlists, favorites cache); Keychain for credentials.
- **Concurrency** — Swift 6 strict concurrency, `Sendable` throughout, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- **Dependencies** — SwiftSonic and AudioStreaming (which brings Ogg/Vorbis binary frameworks for lossless decoding). That's the full list.

---

## Contributing

Contributions are welcome. A few things before you start:

- **Discuss before coding** — open an issue or discussion before working on a feature, especially architectural changes.
- **Match the existing style** — Swift 6 strict concurrency, no Foundation / UIKit leakage outside the service layer, dependencies kept minimal (SwiftSonic + AudioStreaming).
- **Test on real devices** — audio playback and Liquid Glass effects behave differently in the Simulator.
- **Conventional commits** — `feat`, `fix`, `refactor`, `docs`, `chore`, etc.

---

## License

Minidisc is licensed under [MPL-2.0](LICENSE).

- You can use, study, modify, and redistribute the source.
- Modified files stay under MPL-2.0; you may combine them with proprietary code in a Larger Work.

Dependencies: [SwiftSonic](https://github.com/CassetteLab/swiftsonic) (MIT) and [AudioStreaming](https://github.com/dimitris-c/AudioStreaming) by Dimitris C. (MIT) — both compatible with MPL-2.0.

> Code prior to commit 21f9227 was licensed under GPL-3.0-or-later.

---

## Acknowledgments

- [Cassette](https://github.com/CassetteLab/cassette) by Mathieu Dubart — the project Minidisc forked from
- The [Navidrome](https://www.navidrome.org) team for an excellent self-hosted music server
- The [OpenSubsonic](https://opensubsonic.netlify.app) community for modernizing the Subsonic API
