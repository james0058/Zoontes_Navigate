import Foundation

public struct Place: Equatable {
    public var name: String
    public var detail: String
    public var coordinate: LatLon
}

/// Place search through Photon (OpenStreetMap data, free, no key). Results are biased towards `near`.
public enum Geocoder {
    public typealias Fetcher = (_ url: URL, _ completion: @escaping (Data?) -> Void) -> Void

    public static let defaultFetcher: Fetcher = { url, done in
        var req = URLRequest(url: url); req.timeoutInterval = 10
        req.setValue("RideScreen-iOS/0.1 (personal dashboard app)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { d, r, _ in done((r as? HTTPURLResponse)?.statusCode == 200 ? d : nil) }.resume()
    }

    public static func search(_ query: String, near: LatLon?, limit: Int = 8, fetcher: Fetcher = defaultFetcher,
                              completion: @escaping ([Place]) -> Void) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { completion([]); return }
        var comps = URLComponents(string: "https://photon.komoot.io/api/")!
        comps.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: "\(limit)")]
        if let n = near {
            comps.queryItems! += [URLQueryItem(name: "lat", value: "\(n.lat)"), URLQueryItem(name: "lon", value: "\(n.lon)")]
        }
        fetcher(comps.url!) { data in completion(data.map(parse) ?? []) }
    }

    public static func parse(_ data: Data) -> [Place] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }
        return features.compactMap { f in
            guard let g = f["geometry"] as? [String: Any], let c = g["coordinates"] as? [Double], c.count >= 2,
                  let p = f["properties"] as? [String: Any] else { return nil }
            let street = [p["street"], p["housenumber"]].compactMap { $0 as? String }.joined(separator: " ")
            let parts = [street, p["district"] as? String ?? p["locality"] as? String ?? "", p["city"] as? String ?? p["state"] as? String ?? ""]
                .filter { !$0.isEmpty }
            let name = (p["name"] as? String) ?? (street.isEmpty ? (parts.first ?? "Pinned place") : street)
            return Place(name: name, detail: parts.joined(separator: ", "), coordinate: LatLon(lat: c[1], lon: c[0]))
        }
    }
}
