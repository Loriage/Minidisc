import SwiftUI

/// Keeps the photo visible outside the crop frame. Pan and zoom must always cover the square.
struct SquareCropView: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var dragT: CGSize = .zero
    @State private var cropSide: CGFloat = 0

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let F = max(0, min(geo.size.width, geo.size.height) - MinidiscSpacing.l * 2)
                let base = baseSize(forFrame: F)
                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .frame(width: base.width, height: base.height)
                        .scaleEffect(scale * pinch)
                        .offset(x: offset.width + dragT.width, y: offset.height + dragT.height)

                    dimAndGrid(in: geo.size, frame: F)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .updating($pinch) { v, s, _ in s = v }
                        .onEnded { v in
                            scale = min(max(scale * v, 1), 8)
                            offset = clampedOffset(offset, frame: F)
                        }
                        .simultaneously(with:
                            DragGesture()
                                .updating($dragT) { v, s, _ in s = v.translation }
                                .onEnded { v in
                                    offset = clampedOffset(
                                        CGSize(width: offset.width + v.translation.width,
                                               height: offset.height + v.translation.height),
                                        frame: F
                                    )
                                }
                        )
                )
                .onAppear { cropSide = F }
                .onChange(of: F) { _, new in cropSide = new }
            }
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }.tint(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") { performCrop() }.tint(.white).fontWeight(.semibold)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Geometry

    private func baseSize(forFrame F: CGFloat) -> CGSize {
        let minDim = max(min(image.size.width, image.size.height), 1)
        let f = F / minDim
        return CGSize(width: image.size.width * f, height: image.size.height * f)
    }

    private func clampedOffset(_ o: CGSize, frame F: CGFloat) -> CGSize {
        let base = baseSize(forFrame: F)
        let maxX = max(0, (base.width * scale - F) / 2)
        let maxY = max(0, (base.height * scale - F) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }

    // MARK: - Overlay (dim + frame + rule-of-thirds grid)

    private func dimAndGrid(in size: CGSize, frame F: CGFloat) -> some View {
        let rect = CGRect(x: (size.width - F) / 2, y: (size.height - F) / 2, width: F, height: F)
        return ZStack {
            // Dim everything except the crop square (even-odd hole).
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(rect)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

            Path { $0.addRect(rect) }
                .stroke(Color.white.opacity(0.9), lineWidth: 1)

            Path { p in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }

    // MARK: - Render

    @MainActor
    private func performCrop() {
        let F = cropSide
        guard F > 0 else { onCancel(); return }
        let base = baseSize(forFrame: F)
        let framed = Image(uiImage: image)
            .resizable()
            .frame(width: base.width, height: base.height)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: F, height: F)
            .clipped()
        let renderer = ImageRenderer(content: framed)
        renderer.scale = max(2, 1024 / F)
        if let ui = renderer.uiImage {
            onCrop(ui)
        } else {
            onCancel()
        }
    }
}

/// Shared image wrapper for fullScreenCover(item:) in the create and edit flows.
struct CroppableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
