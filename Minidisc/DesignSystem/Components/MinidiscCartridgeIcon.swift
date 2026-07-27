// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// MiniDisc cartridge silhouette: a square shell with the disc window punched out of it, centred and
/// filling nearly the whole face. Fill with `FillStyle(eoFill: true)` so whatever sits behind — the
/// spinning disc — shows through the window.
nonisolated struct MinidiscCartridgeIcon: Shape {
    /// Window centre and radius, exposed so callers can line the disc up with the opening.
    static func windowCenter(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    static func windowRadius(in rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) * 0.42
    }

    static func cornerRadius(in rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) * 0.07
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corner = Self.cornerRadius(in: rect)

        // Shell
        path.addRoundedRect(
            in: rect,
            cornerSize: CGSize(width: corner, height: corner)
        )

        // Disc window — centred, leaving only a thin frame of shell around it.
        let centre = Self.windowCenter(in: rect)
        let radius = Self.windowRadius(in: rect)
        path.addEllipse(in: CGRect(
            x: centre.x - radius,
            y: centre.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        return path
    }
}

/// The shell outline alone, without the window. Stroked separately from `MinidiscCartridgeIcon` so a
/// caller can draw the square's border *over* whatever covers the window — the shutter — while the
/// window's own rim stays underneath it. Stroking the full icon does both at once, which puts the
/// window's arc across the shutter.
nonisolated struct MinidiscCartridgeShell: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corner = MinidiscCartridgeIcon.cornerRadius(in: rect)
        path.addRoundedRect(
            in: rect,
            cornerSize: CGSize(width: corner, height: corner)
        )
        return path
    }
}

#Preview {
    HStack(spacing: 24) {
        MinidiscCartridgeIcon()
            .fill(MinidiscColors.accent, style: FillStyle(eoFill: true))
            .frame(width: 72, height: 72)

        MinidiscCartridgeIcon()
            .fill(.white, style: FillStyle(eoFill: true))
            .frame(width: 44, height: 44)
            .padding(8)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
    }
    .padding()
}
