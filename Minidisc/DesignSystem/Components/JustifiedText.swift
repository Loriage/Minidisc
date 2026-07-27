// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import UIKit

/// Multiline text with **justified** alignment (both edges flush) — which SwiftUI's `Text` cannot do
/// natively (it only offers leading/center/trailing). Wraps a platform label and reports its height via
/// `sizeThatFits`, so it lays out and clamps like a normal view inside SwiftUI stacks. Uses the dynamic
/// `.body` text style to match `.minidiscBody`. `lineLimit` of 0 means unlimited.
struct JustifiedText: View {
    let text: String
    var lineLimit: Int = 0
    var color: Color = .secondary

    var body: some View {
        Backing(text: text, lineLimit: lineLimit, color: color)
    }
}

private struct Backing: UIViewRepresentable {
    let text: String
    let lineLimit: Int
    let color: Color

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.numberOfLines = lineLimit
        let para = NSMutableParagraphStyle()
        para.alignment = .justified
        para.lineBreakMode = .byWordWrapping
        label.attributedText = NSAttributedString(string: text, attributes: [
            .paragraphStyle: para,
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor(color)
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        let fit = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }
}
