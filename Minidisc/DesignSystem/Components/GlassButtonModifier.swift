// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension View {
    /// Applies a circular Liquid Glass effect to a button label.
    /// Apply this to the *label* of a Button (not the Button itself)
    /// so that the parent .buttonStyle(.borderless) gesture fix is preserved.
    func minidiscGlassButton(size: CGFloat = 44, tint: Color? = nil) -> some View {
        // .interactive() removed — causes infinite StyleModifier recursion during
        // NavigationStack transitions (54k-frame stack overflow).
        // Re-evaluate when Apple fixes Glass StyleModifier composition (rdar://TODO).
        let glass: Glass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
        return self
            .frame(width: size, height: size)
            .glassEffect(glass, in: .circle)
    }

    /// Solid dark circular button for the detail-header action row (shuffle / download). A semi-opaque
    /// dark disc reads consistently over any themed melt background — unlike Liquid Glass, which washes
    /// out on light covers. Pair the glyph with `.foregroundStyle(.white)`.
    func minidiscSolidCircleButton(size: CGFloat = 44) -> some View {
        self
            .frame(width: size, height: size)
            .background(Color.black.opacity(0.3), in: Circle())
    }

    /// Applies a capsule Liquid Glass effect (for wider controls).
    func minidiscGlassCapsule(tint: Color? = nil) -> some View {
        // .interactive() removed — same crash risk as minidiscGlassButton.
        let glass: Glass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
        return self.glassEffect(glass, in: .capsule)
    }

    /// Over-cover HERO round button: TRANSPARENT — no surface/fill. Just the tap area + a soft shadow so the
    /// glyph stays legible on a busy cover without a backing (the Apple-Music trick). The caller colors the
    /// glyph for direct contrast on the cover (the over-cover title color). Pair with `.buttonStyle(.plain)`
    /// to drop the native iOS 26 toolbar glass.
    func minidiscHeroButton(size: CGFloat = 44) -> some View {
        self
            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
            .frame(width: size, height: size)
            .contentShape(Circle())
    }
}
