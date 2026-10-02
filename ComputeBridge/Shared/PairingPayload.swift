import Foundation

struct PairingPayload {
    let host: String
    let token: String

    var qrValue: String? {
        guard Self.isLocalHost(host), Self.isValidToken(token) else { return nil }
        var components = URLComponents()
        components.scheme = "computebridge"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "token", value: token)
        ]
        return components.string
    }

    static func parse(_ value: String) -> PairingPayload? {
        guard let components = URLComponents(string: value),
              components.scheme == "computebridge", components.host == "pair",
              let items = components.queryItems,
              items.count == 2,
              let host = items.first(where: { $0.name == "host" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              isLocalHost(host), isValidToken(token) else { return nil }
        return PairingPayload(host: host, token: token)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        if parts.count == 4 && octets.count == 4 {
            return octets[0] == 10
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 169 && octets[1] == 254)
        }
        return host.hasSuffix(".local")
            && host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }

    private static func isValidToken(_ token: String) -> Bool {
        token.range(of: "^[A-Za-z0-9-]{16,64}$", options: .regularExpression) != nil
    }
}
