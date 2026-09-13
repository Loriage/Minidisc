import SwiftUI

struct WrappedStoryProgressBar: View {
    let totalSlides: Int
    let currentIndex: Int
    let progress: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<totalSlides, id: \.self) { index in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.35))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * segmentFill(for: index))
                    }
                }
                .frame(height: 2.5)
            }
        }
    }

    private func segmentFill(for index: Int) -> Double {
        if index < currentIndex { return 1.0 }
        if index == currentIndex { return max(0, min(1, progress)) }
        return 0.0
    }
}
