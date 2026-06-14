import Foundation

enum PairingParser {
    static func parse(_ rawValue: String) throws -> PairingPayload {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw AppError.invalidPairingCode
        }

        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let instanceID = string(object, keys: ["instance_id", "instanceId"]),
           let token = string(object, keys: ["pairing_token", "token"]),
           let base = string(object, keys: ["api_base_url", "apiBaseUrl", "base_url"]),
           let baseURL = normalizedBaseURL(base) {
            return PairingPayload(apiBaseURL: baseURL, instanceID: instanceID, token: token)
        }

        guard let components = URLComponents(string: raw),
              let instanceID = components.queryValue(named: "instance_id")
                ?? components.queryValue(named: "instanceId"),
              let token = components.queryValue(named: "pairing_token")
                ?? components.queryValue(named: "token") else {
            throw AppError.invalidPairingCode
        }
        let explicitBase = components.queryValue(named: "api_base_url")
            ?? components.queryValue(named: "apiBaseUrl")
            ?? components.queryValue(named: "base_url")
        let origin = components.scheme.flatMap { scheme in
            components.host.map { host in
                "\(scheme)://\(host)\(components.port.map { ":\($0)" } ?? "")"
            }
        }
        guard let baseURL = normalizedBaseURL(explicitBase ?? origin ?? "") else {
            throw AppError.invalidServerURL
        }
        return PairingPayload(apiBaseURL: baseURL, instanceID: instanceID, token: token)
    }

    static func normalizedBaseURL(_ value: String) -> URL? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }
        guard var components = URLComponents(string: candidate),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        keys.lazy
            .compactMap { object[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private extension URLComponents {
    func queryValue(named name: String) -> String? {
        queryItems?.first(where: { $0.name == name })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
