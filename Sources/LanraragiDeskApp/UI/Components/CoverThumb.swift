import AppKit
import SwiftUI

struct CoverThumb: View {
    let profile: Profile
    let arcid: String
    let thumbnails: ThumbnailLoader
    let size: CGSize
    let contentInset: CGFloat

    @State private var image: NSImage?
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    init(
        profile: Profile,
        arcid: String,
        thumbnails: ThumbnailLoader,
        size: CGSize = .init(width: 56, height: 72),
        contentInset: CGFloat = 4
    ) {
        self.profile = profile
        self.arcid = arcid
        self.thumbnails = thumbnails
        self.size = size
        self.contentInset = contentInset
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(contentInset)
            } else if let errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(8)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: arcid) {
            // When switching between pairs, the view may be reused; reload for the new arcid.
            image = nil
            errorText = nil
            task?.cancel()
            task = Task {
                do {
                    let img = try await fetch()
                    await MainActor.run { image = img }
                } catch {
                    if Task.isCancelled || ErrorPresenter.isCancellationLike(error) {
                        return
                    }
                    await MainActor.run {
                        self.errorText = ErrorPresenter.short(error)
                    }
                }
            }
        }
        .onDisappear {
            task?.cancel()
            task = nil
        }
    }

    private func fetch() async throws -> NSImage? {
        let bytes = try await thumbnails.thumbnailBytes(profile: profile, arcid: arcid)
        return await MainActor.run { NSImage(data: bytes) }
    }
}
