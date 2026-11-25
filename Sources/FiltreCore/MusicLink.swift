import Foundation

/// A catalog link with an explicit entity type, so an album ID cannot silently
/// become a song ID. Only Apple's HTTPS catalog hosts are accepted.
public struct MusicLink: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case artist, song, album }
    public let url: URL
    public let kind: Kind
    public let catalogID: String
    public let countryCode: String?

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              ["music.apple.com", "itunes.apple.com"].contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }

        var path = url.pathComponents.filter { $0 != "/" }
        var country: String?
        if let first = path.first, first.count == 2, first.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) {
            country = first.lowercased()
            path.removeFirst()
        }
        guard (2...3).contains(path.count), let pathKind = Kind(rawValue: path[0].lowercased()),
              let last = path.last, let pathID = Self.numericID(last) else { return nil }
        let itemValues = (components.queryItems ?? []).filter { $0.name == "i" }
        guard itemValues.count <= 1 else { return nil }

        let resolvedKind: Kind
        let resolvedID: String
        if let item = itemValues.first {
            guard let value = item.value, let itemID = Self.numericID(value),
                  pathKind == .album || (pathKind == .song && itemID == pathID) else { return nil }
            resolvedKind = .song
            resolvedID = itemID
        } else {
            resolvedKind = pathKind
            resolvedID = pathID
        }
        self.url = url
        kind = resolvedKind
        catalogID = resolvedID
        countryCode = country
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    private static func numericID(_ input: String) -> String? {
        let digits = input.hasPrefix("id") ? String(input.dropFirst(2)) : input
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(digits), value > 0 else { return nil }
        return String(value)
    }
}
