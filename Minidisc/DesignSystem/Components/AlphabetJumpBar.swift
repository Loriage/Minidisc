import SwiftUI

struct AlphabetJumpBar: View {
    let availableLetters: Set<String>
    let onLetterTap: (String) -> Void

    @State private var lastLetterReported: String?
    @State private var lastHapticTime: Date = .distantPast

    private static let letters = [
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
        "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "#"
    ]

    var body: some View {
        GeometryReader { geometry in
            let step = min(18, max(10, (geometry.size.height - 16) / CGFloat(Self.letters.count)))
            index(step: step)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 24)
    }

    private func index(step: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Self.letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: min(11, step), weight: .semibold))
                    .frame(width: 24, height: step)
                    .foregroundStyle(
                        availableLetters.contains(letter)
                            ? Color.minidiscAccent
                            : Color.secondary.opacity(0.3)
                    )
                    .accessibilityIdentifier("alphabet.jump.\(letter)")
                    .accessibilityLabel(Text("Jump to \(letter)"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHidden(!availableLetters.contains(letter))
                    .accessibilityAction { onLetterTap(letter) }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let index = max(0, min(Self.letters.count - 1, Int((value.location.y - 8) / step)))
                    let letter = Self.letters[index]
                    let now = Date()
                    guard letter != lastLetterReported,
                          availableLetters.contains(letter),
                          now.timeIntervalSince(lastHapticTime) > 0.04 else { return }
                    lastLetterReported = letter
                    lastHapticTime = now
                    HapticFeedback.selection.trigger()
                    onLetterTap(letter)
                }
                .onEnded { _ in
                    lastLetterReported = nil
                }
        )
    }
}

// MARK: - Helpers

/// Returns the A–Z bucket for `name`, or "#" for anything the bar cannot show a row for.
///
/// Diacritics are folded first, so "Édith" indexes under E. Everything that is still not an ASCII
/// letter — Cyrillic, Greek, CJK, digits, punctuation — belongs under "#". Returning the raw letter
/// instead (as this did) produced index entries like "Л" that no row in the bar could ever match:
/// those items were unreachable, and "#" stayed greyed out despite having content.
func alphabetFirstLetter(of name: String) -> String {
    guard let first = name.first else { return "#" }
    let folded = String(first)
        .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        .uppercased()
    guard let letter = folded.first, letter.isASCII, letter.isLetter else { return "#" }
    return String(letter)
}

extension Collection {
    /// Computes the set of first letters present in the collection for a given string key path.
    func availableAlphabetLetters(keyPath: KeyPath<Element, String>) -> Set<String> {
        Set(self.map { alphabetFirstLetter(of: $0[keyPath: keyPath]) })
    }
}

/// Returns the ID of the first item whose key-path value starts with `letter`.
func firstAlphabetItemID<T: Identifiable>(
    forLetter letter: String,
    in items: [T],
    keyPath: KeyPath<T, String>
) -> T.ID? {
    items.first { alphabetFirstLetter(of: $0[keyPath: keyPath]) == letter }?.id
}
