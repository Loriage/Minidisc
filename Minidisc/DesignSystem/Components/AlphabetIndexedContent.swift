import SwiftUI

/// IDs match the rows' explicit scroll anchors, including their type in mixed collections.
struct AlphabetScrollEntry: Identifiable {
    let id: String
    let name: String
}

/// One index for both List and lazy grids. A jump may first switch the collection to name order;
/// onChange then resolves the anchor from that updated view hierarchy.
struct AlphabetIndexedContent<Content: View>: View {
    let entries: [AlphabetScrollEntry]
    var prepareJump: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var destination: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            content()
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if !entries.isEmpty {
                        AlphabetJumpBar(availableLetters: entries.availableAlphabetLetters(keyPath: \.name)) { letter in
                            guard let id = firstAlphabetItemID(forLetter: letter, in: entries, keyPath: \.name) else { return }
                            prepareJump?()
                            destination = id
                        }
                        .padding(.trailing, 4)
                    }
                }
                .onChange(of: destination) { _, target in
                    guard let target else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    destination = nil
                }
        }
    }
}
