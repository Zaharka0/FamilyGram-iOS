import Foundation

struct FGReleaseVersion: Comparable {
    let major: Int64
    let minor: Int64
    let patch: Int64
    let build: Int64
    static func parse(_ tag: String) -> FGReleaseVersion? {
        let pattern = "^(?:familygram-|v)?([0-9]+)\\.([0-9]+)\\.([0-9]+)(?:-b([0-9]+))?$"
        guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        func number(_ index: Int) -> Int64? {
            let range = match.range(at: index)
            if range.location == NSNotFound { return 0 }
            guard let swiftRange = Range(range, in: tag) else { return nil }
            return Int64(tag[swiftRange])
        }
        guard let major = number(1), let minor = number(2), let patch = number(3), let build = number(4) else { return nil }
        return FGReleaseVersion(major: major, minor: minor, patch: patch, build: build)
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return lhs.build < rhs.build
    }
}
enum FGReleasePolicy {
    static func newer(_ tag: String, version: String, build: Int64) -> Bool {
        guard let candidate = FGReleaseVersion.parse(tag), let own = FGReleaseVersion.parse(version) else { return false }
        return candidate > FGReleaseVersion(major: own.major, minor: own.minor, patch: own.patch, build: build)
    }
    static func trustedIPA(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !value.contains("%"), !value.contains("\\") else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 6, Array(parts.prefix(4)).map(String.init) == ["Zaharka0","FamilyGram-iOS","releases","download"],
              FGReleaseVersion.parse(String(parts[4])) != nil, parts[5].lowercased().hasSuffix(".ipa"),
              !parts.contains(".."), !parts.contains(".") else { return nil }
        return url
    }
}
