import AppKit
import SwiftUI

@MainActor
private enum CoverThumbCache {
    // Cache decoded thumbnails so tab switching doesn't force reload/spinners.
    // NSCache is thread-safe and auto-purges under memory pressure.
    static let images: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 900
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()

    nonisolated static func key(arcid: String, size: CGSize, contentInset: CGFloat, reloadToken: Int) -> String {
        "\(arcid)|\(Int(size.width))x\(Int(size.height))|inset=\(Int(contentInset))|rev=\(reloadToken)"
    }

    static func decodedCost(of image: NSImage) -> Int {
        let representationCost = image.representations.reduce(into: 0) { total, representation in
            let width = max(1, representation.pixelsWide)
            let height = max(1, representation.pixelsHigh)
            let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            if pixelOverflow || byteOverflow || total > Int.max - bytes {
                total = Int.max
            } else {
                total += bytes
            }
        }
        if representationCost > 0 {
            return representationCost
        }

        // Some lazily backed NSImages do not expose a representation yet.
        let width = max(1, Int(image.size.width.rounded(.up)))
        let height = max(1, Int(image.size.height.rounded(.up)))
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { return Int.max }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return byteOverflow ? Int.max : bytes
    }
}

struct CoverThumb: View {
    let profile: Profile
    let arcid: String
    let thumbnails: ThumbnailLoader
    let size: CGSize
    let contentInset: CGFloat
    let showsBorder: Bool
    let reloadToken: Int

    @State private var image: NSImage?
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    @AppStorage("thumbs.cropToFill") private var cropToFill: Bool = false

    init(
        profile: Profile,
        arcid: String,
        thumbnails: ThumbnailLoader,
        size: CGSize = .init(width: 56, height: 72),
        contentInset: CGFloat = 4,
        showsBorder: Bool = true,
        reloadToken: Int = 0
    ) {
        self.profile = profile
        self.arcid = arcid
        self.thumbnails = thumbnails
        self.size = size
        self.contentInset = contentInset
        self.showsBorder = showsBorder
        self.reloadToken = reloadToken
    }

    var body: some View {
        let clipShape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        ZStack {
            clipShape
                .fill(.quaternary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .if(cropToFill) { v in
                        v.scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .clipped()
                    }
                    .if(!cropToFill) { v in
                        v.scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(contentInset)
                    }
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
        .clipShape(clipShape)
        .contentShape(clipShape)
        .overlay {
            if showsBorder {
                clipShape
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
        }
        .task(id: "\(arcid)|\(reloadToken)") {
            // When switching between pairs, the view may be reused; reload for the new arcid.
            let cacheKey = CoverThumbCache.key(arcid: arcid, size: size, contentInset: contentInset, reloadToken: reloadToken)
            if let cached = await MainActor.run(body: { CoverThumbCache.images.object(forKey: cacheKey as NSString) }) {
                image = cached
                errorText = nil
                return
            }

            image = nil
            errorText = nil
            task?.cancel()
            let maxPixelSize = Int(max(size.width, size.height) * 2.5)
            task = Task.detached(priority: .userInitiated) { [profile, arcid, thumbnails, cacheKey] in
                do {
                    let img: NSImage?
                    do {
                        let bytes = try await thumbnails.thumbnailBytes(profile: profile, arcid: arcid)
                        img = ImageDownsampler.thumbnail(from: bytes, maxPixelSize: maxPixelSize)
                    }
                    await MainActor.run {
                        image = img
                        if let img {
                            CoverThumbCache.images.setObject(
                                img,
                                forKey: cacheKey as NSString,
                                cost: CoverThumbCache.decodedCost(of: img)
                            )
                        }
                    }
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
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
