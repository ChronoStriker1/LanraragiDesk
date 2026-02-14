import AppKit
import SwiftUI

struct CoverThumb: View {
    let profile: Profile
    let arcid: String
    let thumbnails: ThumbnailLoader
    let size: CGSize

    @State private var image: NSImage?
    @State private var task: Task<Void, Never>?

    init(profile: Profile, arcid: String, thumbnails: ThumbnailLoader, size: CGSize = .init(width: 56, height: 72)) {
        self.profile = profile
        self.arcid = arcid
        self.thumbnails = thumbnails
        self.size = size
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
                    .padding(4)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: arcid) {
            // When switching between pairs, the view may be reused; reload for the new arcid.
            image = nil
            task?.cancel()
            task = Task {
                if let img = await fetch() {
                    await MainActor.run { image = img }
                }
            }
        }
        .onDisappear {
            task?.cancel()
            task = nil
        }
    }

    private func fetch() async -> NSImage? {
        do {
            let bytes = try await thumbnails.thumbnailBytes(profile: profile, arcid: arcid)
            return await MainActor.run { NSImage(data: bytes) }
        } catch {
            return nil
        }
    }
}
