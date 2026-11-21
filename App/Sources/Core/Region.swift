import Foundation

/// Where websites think this browser is. The IP address already says «the server's
/// country»; the clock must say the same, or a page sees a Moscow clock behind a Tashkent
/// address. The time zone and the country of the exit address are asked once per address
/// through the tunnel itself (the services see only the exit address, like any website)
/// and kept on the phone. Pages then get that zone in every window, frame and script
/// worker (Shield); the profile bar shows the country.
final class Region {
    static let shared = Region()
    static let changed = Notification.Name("Region.changed")

    private let defaults = UserDefaults.standard
    private let zonesKey = "exitZones"  // [exit IPv4: IANA zone]
    private let countriesKey = "exitCountries"  // [exit IPv4: ISO 3166 code]
    private let followKey = "zoneFromServer"
    private var asking: Set<String> = []

    /// On by default: pages see the server's clock. Off: the phone's own clock.
    var followsServer: Bool {
        get { defaults.object(forKey: followKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: followKey)
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    private var zones: [String: String] {
        get { defaults.dictionary(forKey: zonesKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: zonesKey) }
    }
    private var countries: [String: String] {
        get { defaults.dictionary(forKey: countriesKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: countriesKey) }
    }

    /// The zone of this exit address, if known (whether or not pages get it).
    func knownZone(for ip: String?) -> String? { ip.flatMap { zones[$0] } }
    /// The country of this exit address, if known.
    func knownCountry(for ip: String?) -> String? { ip.flatMap { countries[$0] } }
    /// Both are known: nothing to ask.
    func isKnown(_ ip: String) -> Bool { zones[ip] != nil && countries[ip] != nil }

    /// The zone pages get for this exit, or nil = the phone's own clock.
    func zone(for ip: String?) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments  // lab: force a zone
        if let i = args.firstIndex(of: "-zone"), i + 1 < args.count { return args[i + 1] }
        #endif
        return followsServer ? knownZone(for: ip) : nil
    }

    /// «Asia/Tashkent · UTC+5» for Settings.
    static func describe(_ zone: String) -> String {
        guard let tz = TimeZone(identifier: zone) else { return zone }
        let s = tz.secondsFromGMT()
        let h = abs(s) / 3600
        let m = abs(s) % 3600 / 60
        return zone + " · UTC" + (s < 0 ? "−" : "+") + "\(h)" + (m > 0 ? String(format: ":%02d", m) : "")
    }

    /// 🇫🇮 from «FI».
    static func flag(_ code: String?) -> String? {
        guard let code, code.count == 2 else { return nil }
        var s = ""
        for u in code.uppercased().unicodeScalars {
            guard let f = UnicodeScalar(127397 + u.value) else { return nil }
            s.unicodeScalars.append(f)
        }
        return s
    }

    /// Ask the zone and country of `ip` through the tunnel. `done` is called once: with the
    /// zone, or with nil after `wait` seconds (the answer is still stored when it comes later,
    /// and pages get it from their next load). Three independent services, the first valid
    /// answer wins.
    func lookup(_ ip: String, through session: URLSession, wait: TimeInterval = 6, done: @escaping (String?) -> Void) {
        var finished = false
        let finish: (String?, String?) -> Void = { zone, country in
            DispatchQueue.main.async {
                var changed = false
                if let zone, self.zones[ip] != zone {
                    var all = self.zones
                    if all.count > 64 { all.removeAll() }
                    all[ip] = zone
                    self.zones = all
                    changed = true
                }
                if let country, self.countries[ip] != country {
                    var all = self.countries
                    if all.count > 64 { all.removeAll() }
                    all[ip] = country
                    self.countries = all
                    changed = true
                }
                if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
                self.asking.remove(ip)
                if !finished {
                    finished = true
                    done(zone)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            if !finished {
                finished = true
                done(nil)
            }
        }
        guard !asking.contains(ip) else { return }
        asking.insert(ip)
        func json(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        // Each service answers {zone, country} for the address the request comes from.
        let services: [(URL, (Data) -> (String?, String?))] = [
            (
                URL(string: "https://ipapi.co/json/")!,
                { data in
                    let o = json(data)
                    return (o?["timezone"] as? String, o?["country_code"] as? String)
                }
            ),
            (
                URL(string: "https://ipwho.is/?fields=timezone,country_code")!,
                { data in
                    let o = json(data)
                    return ((o?["timezone"] as? [String: Any])?["id"] as? String, o?["country_code"] as? String)
                }
            ),
            (
                URL(string: "https://api.ip.sb/geoip")!,
                { data in
                    let o = json(data)
                    return (o?["timezone"] as? String, o?["country_code"] as? String)
                }
            ),
        ]
        func attempt(_ i: Int) {
            guard i < services.count else {
                finish(nil, nil)
                return
            }
            var request = URLRequest(url: services[i].0, timeoutInterval: 5)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            session.dataTask(with: request) { data, response, error in
                let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
                let (z, c) = ok ? data.map(services[i].1) ?? (nil, nil) : (nil, nil)
                let zone = z?.trimmingCharacters(in: .whitespacesAndNewlines)
                let country = c?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let validZone = zone.flatMap { $0.contains("/") && TimeZone(identifier: $0) != nil ? $0 : nil }
                let validCountry = country.flatMap {
                    $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isLetter } ? $0 : nil
                }
                if validZone != nil { finish(validZone, validCountry) } else { attempt(i + 1) }
            }.resume()
        }
        attempt(0)
    }
}
