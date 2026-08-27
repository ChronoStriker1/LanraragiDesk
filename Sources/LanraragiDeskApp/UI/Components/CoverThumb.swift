import AppKit
import Combine
import SwiftUI

struct CoverThumbIdentity: Hashable, Sendable {
    let profileID: Profile.ID
    let arcid: String
}

struct CoverThumbRequestKey: Hashable, Sendable {
    let identity: CoverThumbIdentity
    let pixelWidth: Int
    let pixelHeight: Int
    let contentInset: Int
    let reloadToken: Int
    let revision: UInt64

    init(
        profileID: Profile.ID,
        arcid: String,
        size: CGSize,
        contentInset: CGFloat,
        reloadToken: Int,
        revision: UInt64
    ) {
        self.identity = CoverThumbIdentity(profileID: profileID, arcid: arcid)
        self.pixelWidth = Int(size.width)
        self.pixelHeight = Int(size.height)
        self.contentInset = Int(contentInset)
        self.reloadToken = reloadToken
        self.revision = revision
    }

    var cacheKey: String {
        "\(identity.profileID.uuidString)|\(identity.arcid)|\(pixelWidth)x\(pixelHeight)|inset=\(contentInset)|reload=\(reloadToken)|rev=\(revision)"
    }
}

private final class CoverThumbCacheEntry: NSObject {
    let token = UUID()
    let key: String
    let identity: CoverThumbIdentity
    let image: NSImage

    init(key: String, identity: CoverThumbIdentity, image: NSImage) {
        self.key = key
        self.identity = identity
        self.image = image
    }
}

private final class CoverThumbCacheIndex: NSObject, NSCacheDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var tokensByIdentityAndKey: [CoverThumbIdentity: [String: UUID]] = [:]

    func register(_ entry: CoverThumbCacheEntry) {
        lock.lock()
        tokensByIdentityAndKey[entry.identity, default: [:]][entry.key] = entry.token
        lock.unlock()
    }

    func removeKeys(for identity: CoverThumbIdentity) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let entries = tokensByIdentityAndKey.removeValue(forKey: identity) else { return [] }
        return Set(entries.keys)
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject object: Any) {
        guard let entry = object as? CoverThumbCacheEntry else { return }
        lock.lock()
        if tokensByIdentityAndKey[entry.identity]?[entry.key] == entry.token {
            tokensByIdentityAndKey[entry.identity]?.removeValue(forKey: entry.key)
        }
        if tokensByIdentityAndKey[entry.identity]?.isEmpty == true {
            tokensByIdentityAndKey.removeValue(forKey: entry.identity)
        }
        lock.unlock()
    }
}

@MainActor
private enum CoverThumbCache {
    // Cache decoded thumbnails so tab switching doesn't force reload/spinners.
    // NSCache is thread-safe and auto-purges under memory pressure.
    private static let index = CoverThumbCacheIndex()
    private static let entries: NSCache<NSString, CoverThumbCacheEntry> = {
        let c = NSCache<NSString, CoverThumbCacheEntry>()
        c.countLimit = 900
        c.totalCostLimit = 128 * 1024 * 1024
        c.delegate = index
        return c
    }()

    static func image(for request: CoverThumbRequestKey) -> NSImage? {
        entries.object(forKey: request.cacheKey as NSString)?.image
    }

    static func insert(_ image: NSImage, for request: CoverThumbRequestKey) {
        let key = request.cacheKey
        let entry = CoverThumbCacheEntry(key: key, identity: request.identity, image: image)
        index.register(entry)
        entries.setObject(entry, forKey: key as NSString, cost: decodedCost(of: image))
    }

    static func invalidate(_ identity: CoverThumbIdentity) {
        let keys = index.removeKeys(for: identity)
        for key in keys {
            entries.removeObject(forKey: key as NSString)
        }
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

@MainActor
enum CoverThumbCacheTestSupport {
    static func insert(_ image: NSImage, for request: CoverThumbRequestKey) {
        CoverThumbCache.insert(image, for: request)
    }

    static func contains(_ request: CoverThumbRequestKey) -> Bool {
        CoverThumbCache.image(for: request) != nil
    }
}

@MainActor
final class CoverThumbInvalidationStore {
    static let shared = CoverThumbInvalidationStore()

    private let invalidations = PassthroughSubject<CoverThumbIdentity, Never>()

    func publisher(for identity: CoverThumbIdentity) -> AnyPublisher<Void, Never> {
        invalidations
            .filter { $0 == identity }
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func invalidate(profileID: Profile.ID, arcid: String) {
        let identity = CoverThumbIdentity(profileID: profileID, arcid: arcid)
        CoverThumbCache.invalidate(identity)
        invalidations.send(identity)
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

    private let invalidationPublisher: AnyPublisher<Void, Never>
    @State private var image: NSImage?
    @State private var errorText: String?
    @State private var activeRequest: CoverThumbRequestKey?
    @State private var task: Task<Void, Never>?
    @State private var revision: UInt64 = 0

    @AppStorage("thumbs.cropToFill") private var cropToFill: Bool = false

    @MainActor
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
        self.invalidationPublisher = CoverThumbInvalidationStore.shared.publisher(
            for: CoverThumbIdentity(profileID: profile.id, arcid: arcid)
        )
    }

    var body: some View {
        let clipShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let request = CoverThumbRequestKey(
            profileID: profile.id,
            arcid: arcid,
            size: size,
            contentInset: contentInset,
            reloadToken: reloadToken,
            revision: revision
        )

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
        .task(id: request) {
            // Profile, archive, dimensions, caller reloads, and cover updates all identify the load.
            activeRequest = request
            task?.cancel()
            task = nil
            if let cached = CoverThumbCache.image(for: request) {
                image = cached
                errorText = nil
                return
            }

            image = nil
            errorText = nil
            let maxPixelSize = Int(max(size.width, size.height) * 2.5)
            task = Task.detached(priority: .userInitiated) { [profile, arcid, thumbnails, request] in
                do {
                    let bytes = try await thumbnails.thumbnailBytes(profile: profile, arcid: arcid)
                    try Task.checkCancellation()
                    let decodedImage = ImageDownsampler.thumbnail(from: bytes, maxPixelSize: maxPixelSize)
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard activeRequest == request else { return }
                        image = decodedImage
                        if let decodedImage {
                            CoverThumbCache.insert(decodedImage, for: request)
                        }
                    }
                } catch {
                    if Task.isCancelled || ErrorPresenter.isCancellationLike(error) {
                        return
                    }
                    await MainActor.run {
                        guard activeRequest == request else { return }
                        errorText = ErrorPresenter.short(error)
                    }
                }
            }
        }
        .onDisappear {
            activeRequest = nil
            task?.cancel()
            task = nil
        }
        .onReceive(invalidationPublisher) {
            revision &+= 1
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
