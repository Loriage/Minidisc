import SwiftUI

/// A track credits several artists: choose which one to open.
struct ArtistPickerRequest: Identifiable {
    let id = UUID()
    let trackTitle: String
    let credits: [ArtistCredit]
}

struct ArtistPickerSheet: View {
    let request: ArtistPickerRequest
    let onSelect: (ArtistCredit) -> Void

    @Environment(\.dismiss) private var dismiss

    private static let avatarSize: CGFloat = 44

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(request.credits.enumerated()), id: \.offset) { _, credit in
                        Button {
                            dismiss()
                            onSelect(credit)
                        } label: {
                            HStack(spacing: MinidiscSpacing.m) {
                                ArtistPlaceholderView(name: credit.name, size: Self.avatarSize)
                                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                                    .clipShape(Circle())
                                    .accessibilityHidden(true)
                                Text(verbatim: credit.name)
                                    .font(.minidiscBody)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.minidiscCaption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(verbatim: request.trackTitle)
                }
            }
            .navigationTitle("Select Artist")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    ArtistPickerSheet(
        request: ArtistPickerRequest(
            trackTitle: "The Mountain",
            credits: [
                ArtistCredit(id: "1", name: "Gorillaz"),
                ArtistCredit(id: "2", name: "Dennis Hopper"),
                ArtistCredit(id: nil, name: "Ajay Prasanna")
            ]
        ),
        onSelect: { _ in }
    )
}
