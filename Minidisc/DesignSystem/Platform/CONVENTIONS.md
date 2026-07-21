# Platform Wrappers

This folder contains SwiftUI modifiers and types that bridge platform-specific
APIs (iOS/macOS) into a unified Minidisc API. The goal is to keep `#if` directives
out of view bodies and service layer.

## Conventions

- Each file scopes a single concern (list styles, navigation transitions, etc.)
- Public modifiers are prefixed with `minidisc` (e.g. `minidiscSheetListStyle`)
- Wrappers MUST become no-op (or sensible default) on the unsupported platform,
  never crash, never throw a precondition failure
- iOS-only or macOS-only types are wrapped in `#if os(...)`. Public-facing types
  (parameters, enums) must compile on both platforms — define cross-platform
  enums and translate internally where needed

## Adding a new wrapper

1. Identify the iOS-only or macOS-only API
2. Determine the sensible behavior on the unsupported platform (no-op, fallback, etc.)
3. Create the wrapper as an extension on `View` (or appropriate type)
4. Use the `minidisc` prefix
5. Document why the wrapper exists in a doc comment

## Files

- `NavigationTitle+Minidisc.swift` — `navigationBarTitleDisplayModeInline/Large()` wrappers (no-op on macOS)
- `ListStyles+Minidisc.swift` — `minidiscSheetListStyle()` for cross-platform list styles in sheets
- `NavigationTransitions+Minidisc.swift` — `minidiscZoomTransition()` (zoom transition iOS 18+, no-op on macOS)

## Related

- `Utilities/PlatformImage.swift` — `PlatformImage` typealias (`UIImage`/`NSImage`) and `Image.init(platformImage:)`;
  lives in Utilities because it is used by both the service layer and the UI layer
- `DesignSystem/Platform/Color+Minidisc.swift` — platform-specific system color wrappers
