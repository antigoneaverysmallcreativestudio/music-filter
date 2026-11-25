import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

#if canImport(FiltreCore)
import FiltreCore
#endif

/// Fetches unambiguous catalog covers and artist portraits. Portraits must come
/// from the matching artist's public Apple Music MusicGroup structured data;
/// album covers and social sharing images are never used as artist portraits.
/// Catalog search/lookup: https://performance-partners.apple.com/search-api
/// Public artist structured data is optional, not an authenticated MusicKit API.
@MainActor
final class ExclusionArtworkProvider {
    private let images = NSCache<NSString, NSImage>()
    private let worker = ExclusionArtworkWorker()
    private var misses: [String: Date] = [:]
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    private var queue: [ExclusionArtworkRequest] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    init() {
        images.countLimit = 128
        images.totalCostLimit = 8 * 1_024 * 1_024
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    /// Completion always runs on the main actor. No Apple Events are sent.
    func load(for rule: BanRule, completion: @escaping (NSImage?) -> Void) {
        guard let request = ExclusionArtworkRequest(rule: rule) else {
            completion(nil)
            return
        }
        let key = request.key
        if let image = images.object(forKey: key as NSString) {
            completion(image)
            return
        }
        if let expiry = misses[key], expiry > Date() {
            completion(nil)
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        // Keep a very large exclusions list from creating unbounded network work.
        guard pending.count < 64 else {
            completion(nil)
            return
        }
        pending[key] = [completion]
        queue.append(request)
        startQueuedRequests()
    }

    private func startQueuedRequests() {
        while tasks.count < 2, !queue.isEmpty {
            let request = queue.removeFirst()
            tasks[request.key] = Task { [weak self, worker] in
                let bitmap = await worker.load(request)
                guard let self else { return }
                let image = bitmap.map {
                    NSImage(cgImage: $0.image,
                            size: NSSize(width: $0.image.width, height: $0.image.height))
                }
                if let image, let bitmap {
                    self.images.setObject(image, forKey: request.key as NSString, cost: bitmap.cost)
                    self.misses.removeValue(forKey: request.key)
                } else {
                    self.misses[request.key] = Date().addingTimeInterval(300)
                    if self.misses.count > 256,
                       let oldest = self.misses.min(by: { $0.value < $1.value })?.key {
                        self.misses.removeValue(forKey: oldest)
                    }
                }
                self.tasks.removeValue(forKey: request.key)
                let callbacks = self.pending.removeValue(forKey: request.key) ?? []
                self.startQueuedRequests()
                for callback in callbacks { callback(image) }
            }
        }
    }
}

private struct ExclusionArtworkRequest: Sendable {
    let isArtist: Bool
    let isAlbum: Bool
    let name: String
    let artist: String
    let album: String
    let term: String
    let country: String

    init?(rule: BanRule) {
        let credit = rule.kind == .artist ? rule.name : (rule.artist ?? "")
        let title = normalizedMusicText(rule.name)
        let artist = normalizedMusicText(credit)
        guard !title.isEmpty, !artist.isEmpty,
              rule.name.utf8.count + credit.utf8.count <= 768 else { return nil }
        isArtist = rule.kind == .artist
        isAlbum = rule.kind == .album
        name = title
        self.artist = artist
        album = rule.kind == .track ? normalizedMusicText(rule.album ?? "") : ""
        term = rule.name + " " + credit
        let region = Locale.current.region?.identifier.uppercased() ?? "FR"
        country = region.utf8.count == 2 && region.utf8.allSatisfy { (65...90).contains($0) }
            ? region : "FR"
    }

    var key: String {
        let identity = ["v3", isArtist ? "artist" : (isAlbum ? "album" : "song"), name, artist, album, country]
            .map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func searchURL(artistOnly: Bool = false) -> URL? {
        var url = URLComponents(string: "https://itunes.apple.com/search")
        url?.queryItems = [
            URLQueryItem(name: "term", value: artistOnly ? artist : term),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: isAlbum ? "album" : "song"),
            URLQueryItem(name: "limit", value: "50")
        ]
        if artistOnly { url?.queryItems?.append(URLQueryItem(name: "attribute", value: "artistTerm")) }
        return url?.url
    }

    func matches(_ item: ExclusionArtworkCatalogItem) -> Bool {
        guard !isArtist, normalizedMusicText(item.artistName ?? "") == artist else { return false }
        if isAlbum {
            return item.wrapperType == "collection" && item.collectionType == "Album"
                && normalizedMusicText(item.collectionName ?? "") == name
        }
        return item.wrapperType == "track" && item.kind == "song"
            && normalizedMusicText(item.trackName ?? "") == name
            && (album.isEmpty || normalizedMusicText(item.collectionName ?? "") == album)
    }

    func artworkURL(in results: [ExclusionArtworkCatalogItem]) -> URL? {
        let matches = results.filter(matches)
        // An old song rule may lack its album. Do not arbitrarily choose between
        // multiple releases, or between different covers with the same names.
        guard !matches.isEmpty else { return nil }
        let albums = Set(matches.map { normalizedMusicText($0.collectionName ?? "") })
        guard albums.count == 1, !albums.contains("") else { return nil }
        let urls = matches.compactMap { item -> URL? in
            guard let value = item.artworkUrl100 ?? item.artworkUrl60,
                  let url = URL(string: value), ExclusionArtworkURLPolicy.isArtwork(url) else { return nil }
            return url
        }
        guard urls.count == matches.count, Set(urls).count == 1 else { return nil }
        return urls.first
    }
}

private struct ExclusionArtworkCatalogResponse: Decodable {
    let results: [ExclusionArtworkCatalogItem]
}

private struct ExclusionArtworkCatalogItem: Decodable, Sendable {
    let wrapperType: String?
    let collectionType: String?
    let kind: String?
    let artistName: String?
    let artistId: UInt64?
    let artistLinkUrl: String?
    let collectionName: String?
    let trackName: String?
    let artworkUrl100: String?
    let artworkUrl60: String?
}

private struct ExclusionArtworkArtist: Sendable {
    let id: UInt64
    let name: String
    let pageURL: URL

    static func resolve(_ results: [ExclusionArtworkCatalogItem], name: String) -> Self? {
        let matches = results.filter {
            $0.wrapperType == "artist" && normalizedMusicText($0.artistName ?? "") == name
        }
        let ids = Set(matches.compactMap(\.artistId))
        guard !matches.isEmpty, matches.allSatisfy({ ($0.artistId ?? 0) > 0 }),
              ids.count == 1, let id = ids.first else { return nil }
        // Repeated identical rows are harmless, but distinct artist IDs with the
        // same name cannot be resolved from the stored exclusion's name alone.
        let pages = matches.compactMap { item -> URL? in
            guard let value = item.artistLinkUrl, let url = URL(string: value),
                  ExclusionArtworkURLPolicy.artistID(url) == String(id) else { return nil }
            return url
        }
        guard pages.count == matches.count, let page = pages.first else { return nil }
        return Self(id: id, name: name, pageURL: page)
    }

    func portraitURL(in data: Data) -> URL? {
        guard let html = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script\s*>"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let blocks = expression.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard blocks.count <= 8 else { return nil }
        var portraits: [URL] = []
        for block in blocks {
            guard let range = Range(block.range(at: 1), in: html) else { return nil }
            let body = Data(html[range].utf8)
            guard body.count <= 65_536,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
            guard object["@type"] as? String == "MusicGroup" else { continue }
            guard let title = object["name"] as? String, normalizedMusicText(title) == name,
                  let value = object["url"] as? String, let url = URL(string: value),
                  ExclusionArtworkURLPolicy.artistID(url) == String(id),
                  let image = object["image"] as? String, let portrait = URL(string: image),
                  ExclusionArtworkURLPolicy.isArtwork(portrait) else { return nil }
            portraits.append(portrait)
        }
        // This public page format can change. Missing or conflicting structured
        // data keeps the placeholder; never guess from og:image or album cards.
        guard !portraits.isEmpty, Set(portraits).count == 1 else { return nil }
        return portraits.first
    }
}

/// CGImage is immutable; only the main actor wraps it in an NSImage.
private struct ExclusionArtworkBitmap: @unchecked Sendable {
    let image: CGImage
    var cost: Int { image.bytesPerRow * image.height }
}

private actor ExclusionArtworkWorker {
    private let session: URLSession
    private var nextSearch = Date.distantPast
    private var catalogCache: [URL: (expires: Date, results: [ExclusionArtworkCatalogItem])] = [:]
    private var catalogTasks: [URL: Task<[ExclusionArtworkCatalogItem], Error>] = [:]
    private let maximumImageBytes = 1_048_576
    private let maximumCatalogBytes = 524_288
    private let maximumArtistPageBytes = 2_097_152
    private let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration,
                             delegate: ExclusionArtworkRedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func load(_ request: ExclusionArtworkRequest) async -> ExclusionArtworkBitmap? {
        do {
            try Task.checkCancellation()
            if let cached = cachedBitmap(for: request.key) { return cached }
            let artwork: URL?
            if request.isArtist {
                guard let artist = try await resolveArtist(for: request) else { return nil }
                try await reserveCatalogSlot()
                let page = try await fetch(artist.pageURL, kind: .artistPage)
                artwork = artist.portraitURL(in: page)
            } else {
                var results = try await search(request)
                if request.isAlbum, !results.contains(where: request.matches) {
                    results = try await search(request, artistOnly: true)
                }
                if request.isAlbum, !results.contains(where: request.matches),
                   let artist = try await resolveArtist(for: request) {
                    // Search can omit an album even when it is in this artist's
                    // catalog. A single bounded lookup retains the exact match.
                    results = try await albums(for: artist, country: request.country)
                }
                artwork = request.artworkURL(in: results)
            }
            guard let artwork else { return nil }
            let largerArtwork = ExclusionArtworkURLPolicy.largerArtwork(artwork)
            let candidates = largerArtwork == artwork ? [artwork] : [largerArtwork, artwork]
            var resolved: ExclusionArtworkBitmap?
            for candidate in candidates {
                try Task.checkCancellation()
                do {
                    let imageData = try await fetch(candidate, kind: .artwork)
                    if let bitmap = Self.decode(imageData) {
                        resolved = bitmap
                        break
                    }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                }
            }
            try Task.checkCancellation()
            guard let bitmap = resolved else { return nil }
            cache(bitmap, for: request.key)
            return bitmap
        } catch {
            return nil
        }
    }

    private func search(_ request: ExclusionArtworkRequest, artistOnly: Bool = false) async throws -> [ExclusionArtworkCatalogItem] {
        guard let url = request.searchURL(artistOnly: artistOnly) else { throw URLError(.badURL) }
        return try await catalogResults(at: url)
    }

    private func resolveArtist(for request: ExclusionArtworkRequest) async throws -> ExclusionArtworkArtist? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: request.artist),
            URLQueryItem(name: "country", value: request.country),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "attribute", value: "artistTerm"),
            URLQueryItem(name: "limit", value: "200")
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let results = try await catalogResults(at: url)
        // A full result page may conceal another homonym beyond the limit.
        guard results.count < 200 else { return nil }
        return ExclusionArtworkArtist.resolve(results, name: request.artist)
    }

    private func albums(for artist: ExclusionArtworkArtist, country: String) async throws -> [ExclusionArtworkCatalogItem] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(artist.id)),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "200")
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let results = try await catalogResults(at: url)
        guard results.contains(where: {
            $0.wrapperType == "artist" && $0.artistId == artist.id
                && normalizedMusicText($0.artistName ?? "") == artist.name
        }) else { return [] }
        // The lookup includes the artist row. If its album page is full, we
        // cannot exclude another release with the same title beyond the limit.
        guard results.filter({ $0.wrapperType == "collection" }).count < 200 else { return [] }
        return results.filter { $0.artistId == artist.id }
    }

    private func catalogResults(at url: URL) async throws -> [ExclusionArtworkCatalogItem] {
        try Task.checkCancellation()
        if let cached = catalogCache[url], cached.expires > Date() { return cached.results }
        let task: Task<[ExclusionArtworkCatalogItem], Error>
        if let pending = catalogTasks[url] {
            task = pending
        } else {
            task = Task {
                try await self.reserveCatalogSlot()
                let data = try await self.fetch(url, kind: .catalog)
                return try JSONDecoder().decode(ExclusionArtworkCatalogResponse.self, from: data).results
            }
            catalogTasks[url] = task
        }
        do {
            let results = try await task.value
            catalogTasks.removeValue(forKey: url)
            catalogCache[url] = (Date().addingTimeInterval(results.isEmpty ? 300 : 900), results)
            if catalogCache.count > 64, let oldest = catalogCache.min(by: { $0.value.expires < $1.value.expires })?.key {
                catalogCache.removeValue(forKey: oldest)
            }
            // A shared catalog request is not canceled by one consumer. Its
            // timeout is bounded; canceled artwork consumers stop here.
            try Task.checkCancellation()
            return results
        } catch {
            catalogTasks.removeValue(forKey: url)
            throw error
        }
    }

    private func reserveCatalogSlot() async throws {
        try Task.checkCancellation()
        // Apple's public Search API documents approximately 20 calls/minute.
        // Public artist pages share this same cadence instead of adding a burst.
        let delay = max(0, nextSearch.timeIntervalSinceNow)
        nextSearch = Date().addingTimeInterval(delay + 3.1)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
    }

    private enum FetchKind { case catalog, artistPage, artwork }

    private func fetch(_ url: URL, kind: FetchKind) async throws -> Data {
        try Task.checkCancellation()
        let allowed: (URL) -> Bool
        let limit: Int
        let accept: String
        switch kind {
        case .catalog:
            allowed = ExclusionArtworkURLPolicy.isCatalog
            limit = maximumCatalogBytes
            accept = "application/json"
        case .artistPage:
            let id = ExclusionArtworkURLPolicy.artistID(url)
            allowed = { id != nil && ExclusionArtworkURLPolicy.artistID($0) == id }
            limit = maximumArtistPageBytes
            accept = "text/html"
        case .artwork:
            allowed = ExclusionArtworkURLPolicy.isArtwork
            limit = maximumImageBytes
            accept = "image/jpeg,image/png,image/webp"
        }
        guard allowed(url) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode), let finalURL = response.url,
              allowed(finalURL),
              response.expectedContentLength <= Int64(limit) else { throw URLError(.badServerResponse) }
        if kind == .artwork {
            guard let mime = response.mimeType?.lowercased(),
                  ["image/jpeg", "image/png", "image/webp"].contains(mime) else { throw URLError(.cannotDecodeContentData) }
        } else if kind == .artistPage, response.mimeType?.lowercased() != "text/html" {
            throw URLError(.cannotDecodeContentData)
        }
        var data = Data()
        data.reserveCapacity(16_384)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    private static func decode(_ data: Data) -> ExclusionArtworkBitmap? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4_096, height <= 4_096,
              width * height <= 16_000_000 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return ExclusionArtworkBitmap(image: image)
    }

    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.julienmerault.FiltreMusique", isDirectory: true)
            .appendingPathComponent("ExclusionArtwork-v3", isDirectory: true)
    }

    private func cachedBitmap(for key: String) -> ExclusionArtworkBitmap? {
        guard let directory = cacheDirectory else { return nil }
        let url = directory.appendingPathComponent(key + ".png")
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let date = values.contentModificationDate,
              Date().timeIntervalSince(date) < cacheLifetime,
              let size = values.fileSize, size <= maximumImageBytes,
              let data = try? Data(contentsOf: url), let bitmap = Self.decode(data) else { return nil }
        return bitmap
    }

    private func cache(_ bitmap: ExclusionArtworkBitmap, for key: String) {
        guard let directory = cacheDirectory else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, bitmap.image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= maximumImageBytes else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (data as Data).write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
            pruneCache(directory)
        } catch { }
    }

    private func pruneCache(_ directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.filter { $0.pathExtension == "png" }.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let date = values.contentModificationDate, let size = values.fileSize else { return nil }
            return (url, date, size)
        }.sorted { $0.1 > $1.1 }
        var total = 0
        for (index, entry) in entries.enumerated() {
            total += entry.2
            if index >= 256 || total > 20 * 1_024 * 1_024 || Date().timeIntervalSince(entry.1) >= cacheLifetime {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }
}

private enum ExclusionArtworkURLPolicy {
    private static func secure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    static func isCatalog(_ url: URL) -> Bool {
        secure(url) && url.host?.lowercased() == "itunes.apple.com"
            && ["/search", "/lookup"].contains(url.path)
    }

    static func artistID(_ url: URL) -> String? {
        guard secure(url), url.host?.lowercased() == "music.apple.com",
              let link = MusicLink(url: url), link.kind == .artist else { return nil }
        return link.catalogID
    }

    static func isArtwork(_ url: URL) -> Bool {
        guard secure(url), let host = url.host?.lowercased() else { return false }
        return host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
            || host.hasSuffix(".itunes.apple.com")
    }

    static func largerArtwork(_ url: URL) -> URL {
        guard isArtwork(url), let host = url.host?.lowercased(),
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com"),
              url.lastPathComponent.range(of: #"^(60x60|100x100)bb(-[0-9]{1,3})?\.(jpg|jpeg|png|webp)$"#,
                                          options: .regularExpression) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let name = url.lastPathComponent.replacingOccurrences(of: #"^(60x60|100x100)"#,
                                                              with: "600x600", options: .regularExpression)
        components.path = url.deletingLastPathComponent().appendingPathComponent(name).path
        // Only Apple's known size suffix is changed; failed larger requests fall
        // back to the exact catalog URL, never to a different artwork identity.
        return components.url ?? url
    }
}

private final class ExclusionArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let url = request.url else {
            completionHandler(nil)
            return
        }
        let allowed: Bool
        if ExclusionArtworkURLPolicy.isCatalog(original) {
            allowed = ExclusionArtworkURLPolicy.isCatalog(url)
        } else if let artistID = ExclusionArtworkURLPolicy.artistID(original) {
            allowed = ExclusionArtworkURLPolicy.artistID(url) == artistID
        } else {
            allowed = ExclusionArtworkURLPolicy.isArtwork(original) && ExclusionArtworkURLPolicy.isArtwork(url)
        }
        completionHandler(allowed ? request : nil)
    }
}
