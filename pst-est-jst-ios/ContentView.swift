//import SwiftUI
//import Combine
//
//// MARK: - Weather
//
//struct WeatherResponse: Codable {
//    let current: CurrentWeather
//}
//
//struct CurrentWeather: Codable {
//    let temperature_2m: Double
//    let weather_code: Int
//}
//
//@MainActor
//class WeatherManager: ObservableObject {
//
//    @Published var temperature = "--°"
//    @Published var condition = "Loading..."
//    @Published var icon = "cloud.fill"
//
//    func load(latitude: Double, longitude: Double) async {
//
//        guard let url = URL(
//            string:
//            "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code&temperature_unit=fahrenheit"
//        ) else { return }
//
//        do {
//
//            let (data, _) = try await URLSession.shared.data(from: url)
//
//            let weather = try JSONDecoder().decode(
//                WeatherResponse.self,
//                from: data
//            )
//
//            temperature = "\(Int(weather.current.temperature_2m.rounded()))°"
//
//            switch weather.current.weather_code {
//
//            case 0:
//                condition = "Clear"
//                icon = "sun.max.fill"
//
//            case 1, 2, 3:
//                condition = "Partly Cloudy"
//                icon = "cloud.sun.fill"
//
//            case 45, 48:
//                condition = "Fog"
//                icon = "cloud.fog.fill"
//
//            case 51...67:
//                condition = "Rain"
//                icon = "cloud.rain.fill"
//
//            case 71...77:
//                condition = "Snow"
//                icon = "snowflake"
//
//            case 80...82:
//                condition = "Showers"
//                icon = "cloud.heavyrain.fill"
//
//            case 95...99:
//                condition = "Storm"
//                icon = "cloud.bolt.rain.fill"
//
//            default:
//                condition = "Cloudy"
//                icon = "cloud.fill"
//            }
//
//        } catch {
//            temperature = "--°"
//            condition = "Unavailable"
//            icon = "exclamationmark.triangle"
//        }
//    }
//}
//
//// MARK: - City Events
//
//struct CityEvent: Identifiable {
//    let id: String
//    let title: String
//    let category: String
//    let dateLabel: String
//    let venue: String?
//    let isFree: Bool
//    let url: String?
//}
//
//enum EventsError: LocalizedError {
//    case missingAPIKey(String)
//    case badResponse(Int)
//    case unsupportedCountry(String)
//
//    var errorDescription: String? {
//        switch self {
//        case .missingAPIKey(let service):
//            return "Add your \(service) API key to CityEventsManager to load real events."
//        case .badResponse(let code):
//            return "The events API returned an error (status \(code))."
//        case .unsupportedCountry(let code):
//            return "No events source configured for country \(code)."
//        }
//    }
//}
//
//@MainActor
//class CityEventsManager: ObservableObject {
//
//    @Published var events: [CityEvent] = []
//    @Published var isLoading = false
//    @Published var errorMessage: String?
//
//    // Ticketmaster covers: US, CA, IE, GB, AU, NZ, MX, AT, BE, DE, DK, ES, FI, NL, NO, PL, SE, FR
//    // Get a free key at https://developer.ticketmaster.com
//    // (register -> default app is created instantly -> copy the Consumer Key)
//    private let ticketmasterKey = "VZGLABmlOrPw2s8RwDH4U6d0FA79LsfE" // e.g. "AbCdEfGhIjKlMnOpQrStUvWxYz"
//
//    // PredictHQ has real Japan coverage but the free trial is 14 days and
//    // evaluation-only — not viable to ship on. Japan events are instead
//    // scraped in-app from Japan Cheapo's public events page (see
//    // loadJapanEventsByScraping below).
//
//    private static let ticketmasterCountries: Set<String> = [
//        "US", "CA", "IE", "GB", "AU", "NZ", "MX",
//        "AT", "BE", "DE", "DK", "ES", "FI", "NL", "NO", "PL", "SE", "FR",
//    ]
//
//    /// countryCode should be the ISO country code for the city, e.g. "US" or "JP"
//    func load(city: String, countryCode: String) async {
//        isLoading = true
//        errorMessage = nil
//        defer { isLoading = false }
//
//        do {
//            if CityEventsManager.ticketmasterCountries.contains(countryCode) {
//                events = try await loadFromTicketmaster(city: city, countryCode: countryCode)
//            } else if countryCode == "JP" {
//                events = try await loadJapanEventsByScraping(city: city)
//            } else {
//                throw EventsError.unsupportedCountry(countryCode)
//            }
//
//            if events.isEmpty {
//                errorMessage = "No events found for \(city) right now."
//            }
//
//        } catch let error as EventsError {
//            errorMessage = error.localizedDescription
//            events = []
//        } catch {
//            errorMessage = "Couldn't load events: \(error.localizedDescription)"
//            events = []
//        }
//    }
//
//    // MARK: Ticketmaster (US, CA, UK, etc.)
//
//    private func loadFromTicketmaster(city: String, countryCode: String) async throws -> [CityEvent] {
//        guard !ticketmasterKey.isEmpty else {
//            throw EventsError.missingAPIKey("Ticketmaster")
//        }
//
//        var components = URLComponents(string: "https://app.ticketmaster.com/discovery/v2/events.json")!
//        components.queryItems = [
//            URLQueryItem(name: "apikey", value: ticketmasterKey),
//            URLQueryItem(name: "city", value: city),
//            URLQueryItem(name: "countryCode", value: countryCode),
//            URLQueryItem(name: "sort", value: "date,asc"),
//            URLQueryItem(name: "size", value: "20"),
//        ]
//
//        let url = components.url!
//        let (data, response) = try await URLSession.shared.data(from: url)
//
//        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
//            throw EventsError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
//        }
//
//        let decoded = try JSONDecoder().decode(TicketmasterResponse.self, from: data)
//
//        return (decoded.embedded?.events ?? []).map { event in
//            CityEvent(
//                id: event.id,
//                title: event.name,
//                category: event.classifications?.first?.segment?.name ?? "Event",
//                dateLabel: CityEventsManager.formatTicketmasterDate(
//                    date: event.dates?.start?.localDate,
//                    time: event.dates?.start?.localTime
//                ),
//                venue: event.embedded?.venues?.first?.name,
//                isFree: (event.priceRanges?.first?.min ?? -1) == 0,
//                url: event.url
//            )
//        }
//    }
//
//    private static func formatTicketmasterDate(date: String?, time: String?) -> String {
//        guard let date else { return "Date TBD" }
//
//        let inputFormatter = DateFormatter()
//        inputFormatter.dateFormat = time != nil ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd"
//        let combined = time != nil ? "\(date)T\(time!)" : date
//
//        guard let parsed = inputFormatter.date(from: combined) else { return date }
//
//        let display = DateFormatter()
//        display.dateFormat = time != nil ? "EEE, MMM d · h:mm a" : "EEE, MMM d"
//        return display.string(from: parsed)
//    }
//
//    // MARK: Japan events (scraped in-app, no backend needed)
//    //
//    // PredictHQ's free trial is 14 days and evaluation-only (can't ship on it).
//    // Ticketmaster doesn't cover Japan. So this fetches Japan Cheapo's public
//    // events page directly and extracts events with regex.
//    //
//    // IMPORTANT: I can't see Japan Cheapo's actual HTML from here (my tools
//    // only return extracted text, not raw markup), so the regex patterns
//    // below are a best-effort guess, not confirmed against real markup.
//    // If this comes back empty, open https://japancheapo.com/events/ in
//    // Safari, use "View Source" or Web Inspector, and adjust the pattern
//    // in `extractEvents(from:)` to match what's actually there — most
//    // likely you'll need to change the tag/class names in the regex.
//
//    private func loadJapanEventsByScraping(city: String) async throws -> [CityEvent] {
//        guard let url = URL(string: "https://japancheapo.com/events/") else {
//            throw EventsError.badResponse(-1)
//        }
//
//        var request = URLRequest(url: url)
//        request.setValue("Mozilla/5.0 (compatible; PersonalEventsApp/1.0)", forHTTPHeaderField: "User-Agent")
//
//        let (data, response) = try await URLSession.shared.data(for: request)
//
//        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
//            throw EventsError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
//        }
//
//        guard let html = String(data: data, encoding: .utf8) else {
//            throw EventsError.badResponse(-1)
//        }
//
//        let allEvents = CityEventsManager.extractEvents(from: html)
//
//        // Filter to events whose title/snippet mentions the requested city.
//        // Crude, but Japan Cheapo's page isn't split by city.
//        let cityLower = city.lowercased()
//        return allEvents.filter {
//            $0.title.lowercased().contains(cityLower) ||
//            $0.snippet.lowercased().contains(cityLower)
//        }.enumerated().map { index, e in
//            CityEvent(
//                id: "\(city)-\(index)",
//                title: e.title,
//                category: "Festival / Event",
//                dateLabel: "See details",
//                venue: nil,
//                isFree: e.snippet.lowercased().contains("free"),
//                url: e.url
//            )
//        }
//    }
//
//    private struct ScrapedEvent {
//        let title: String
//        let snippet: String
//        let url: String?
//    }
//
//    /// Best-effort HTML extraction using regex. Fragile by nature — this is
//    /// the tradeoff of not having a real API. Adjust the pattern once you've
//    /// inspected the live page's actual structure.
//    private static func extractEvents(from html: String) -> [ScrapedEvent] {
//        var results: [ScrapedEvent] = []
//
//        // Looks for <article ...> ... </article> blocks, a common
//        // WordPress pattern for post/event cards.
//        guard let articleRegex = try? NSRegularExpression(
//            pattern: "<article[^>]*>(.*?)</article>",
//            options: [.dotMatchesLineSeparators, .caseInsensitive]
//        ) else { return results }
//
//        let nsHTML = html as NSString
//        let matches = articleRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
//
//        let titleRegex = try? NSRegularExpression(
//            pattern: "<h[23][^>]*>(?:<a[^>]*>)?([^<]+)",
//            options: [.caseInsensitive]
//        )
//        let linkRegex = try? NSRegularExpression(
//            pattern: "<a[^>]+href=\"([^\"]+)\"",
//            options: [.caseInsensitive]
//        )
//        let paragraphRegex = try? NSRegularExpression(
//            pattern: "<p[^>]*>([^<]+)</p>",
//            options: [.caseInsensitive]
//        )
//
//        for match in matches {
//            let block = nsHTML.substring(with: match.range(at: 1))
//            let blockNS = block as NSString
//
//            guard let titleMatch = titleRegex?.firstMatch(in: block, range: NSRange(location: 0, length: blockNS.length)) else {
//                continue
//            }
//            let title = blockNS.substring(with: titleMatch.range(at: 1))
//                .trimmingCharacters(in: .whitespacesAndNewlines)
//
//            let snippet = paragraphRegex?.firstMatch(in: block, range: NSRange(location: 0, length: blockNS.length))
//                .map { blockNS.substring(with: $0.range(at: 1)) } ?? ""
//
//            let link = linkRegex?.firstMatch(in: block, range: NSRange(location: 0, length: blockNS.length))
//                .map { blockNS.substring(with: $0.range(at: 1)) }
//
//            if !title.isEmpty {
//                results.append(ScrapedEvent(title: title, snippet: snippet, url: link))
//            }
//        }
//
//        return results
//    }
//}
//
//struct TicketmasterResponse: Codable {
//    let embedded: TicketmasterEmbeddedEvents?
//
//    enum CodingKeys: String, CodingKey {
//        case embedded = "_embedded"
//    }
//}
//
//struct TicketmasterEmbeddedEvents: Codable {
//    let events: [TicketmasterEvent]?
//}
//
//struct TicketmasterEvent: Codable {
//    let id: String
//    let name: String
//    let url: String?
//    let dates: TicketmasterDates?
//    let classifications: [TicketmasterClassification]?
//    let priceRanges: [TicketmasterPriceRange]?
//    let embedded: TicketmasterEmbeddedVenues?
//
//    enum CodingKeys: String, CodingKey {
//        case id, name, url, dates, classifications, priceRanges
//        case embedded = "_embedded"
//    }
//}
//
//struct TicketmasterEmbeddedVenues: Codable {
//    let venues: [TicketmasterVenue]?
//}
//
//struct TicketmasterVenue: Codable {
//    let name: String?
//}
//
//struct TicketmasterDates: Codable {
//    let start: TicketmasterStart?
//}
//
//struct TicketmasterStart: Codable {
//    let localDate: String?
//    let localTime: String?
//}
//
//struct TicketmasterClassification: Codable {
//    let segment: TicketmasterSegment?
//}
//
//struct TicketmasterSegment: Codable {
//    let name: String?
//}
//
//struct TicketmasterPriceRange: Codable {
//    let min: Double?
//}
//
//struct CityDetailView: View {
//    let city: String
//    let abbreviation: String
//    let countryCode: String
//
//    @StateObject private var events = CityEventsManager()
//    @Environment(\.dismiss) private var dismiss
//
//    var body: some View {
//        NavigationStack {
//            Group {
//                if events.isLoading {
//                    ProgressView("Loading events…")
//                        .frame(maxWidth: .infinity, maxHeight: .infinity)
//                } else if events.events.isEmpty {
//                    ContentUnavailableFallback(message: events.errorMessage ?? "Nothing found.")
//                } else {
//                    List(events.events) { event in
//                        VStack(alignment: .leading, spacing: 6) {
//                            HStack {
//                                Text(event.title)
//                                    .font(.headline)
//                                Spacer()
//                                if event.isFree {
//                                    Text("FREE")
//                                        .font(.caption2.bold())
//                                        .padding(.horizontal, 6)
//                                        .padding(.vertical, 2)
//                                        .background(Color.green.opacity(0.15))
//                                        .foregroundStyle(.green)
//                                        .clipShape(Capsule())
//                                }
//                            }
//                            Text(event.dateLabel)
//                                .font(.subheadline)
//                                .foregroundStyle(.secondary)
//                            if let venue = event.venue {
//                                Label(venue, systemImage: "mappin.and.ellipse")
//                                    .font(.caption)
//                                    .foregroundStyle(.tertiary)
//                            }
//                            HStack {
//                                Text(event.category)
//                                    .font(.caption2)
//                                    .foregroundStyle(.blue)
//                                if let urlString = event.url, let url = URL(string: urlString) {
//                                    Spacer()
//                                    Link("Details", destination: url)
//                                        .font(.caption2)
//                                }
//                            }
//                        }
//                        .padding(.vertical, 4)
//                    }
//                    .listStyle(.plain)
//                }
//            }
//            .navigationTitle("What's on in \(city)")
//            .navigationBarTitleDisplayMode(.inline)
//            .toolbar {
//                ToolbarItem(placement: .topBarTrailing) {
//                    Button("Done") { dismiss() }
//                }
//            }
//            .task {
//                await events.load(city: city, countryCode: countryCode)
//            }
//        }
//    }
//}
//
//// Small fallback view so this compiles cleanly on iOS versions
//// without ContentUnavailableView (iOS 17+).
//struct ContentUnavailableFallback: View {
//    let message: String
//    var body: some View {
//        VStack(spacing: 8) {
//            Image(systemName: "calendar.badge.exclamationmark")
//                .font(.system(size: 32))
//                .foregroundStyle(.secondary)
//            Text(message)
//                .foregroundStyle(.secondary)
//        }
//        .frame(maxWidth: .infinity, maxHeight: .infinity)
//    }
//}
//
//struct ContentView: View {
//    @State private var now = Date()
//
//    let timer = Timer.publish(
//        every: 1,
//        on: .main,
//        in: .common
//    ).autoconnect()
//
//    var body: some View {
//
//        ZStack {
//            LinearGradient(
//                colors: [
//                    Color.blue.opacity(0.08),
//                    Color.gray.opacity(0.10)
//                ],
//                startPoint: .top,
//                endPoint: .bottom
//            )
//            .ignoresSafeArea()
//
//            ScrollView {
//                VStack(spacing: 10) {
//
//                    TimeZoneCard(
//                        abbreviation: "PST",
//                        city: "Los Angeles",
//                        countryCode: "US",
//                        latitude: 34.0522,
//                        longitude: -118.2437,
//                        timeZoneID: "America/Los_Angeles",
//                        now: now
//                    )
//                    
//                    TimeZoneCard(
//                        abbreviation: "PST",
//                        city: "Anaheim",
//                        countryCode: "US",
//                        latitude: 33.7174,
//                        longitude: -117.8311,
//                        timeZoneID: "America/Los_Angeles",
//                        now: now
//                    )
//
//                    TimeZoneCard(
//                        abbreviation: "EST",
//                        city: "New York",
//                        countryCode: "US",
//                        latitude: 40.7128,
//                        longitude: -74.0060,
//                        timeZoneID: "America/New_York",
//                        now: now
//                    )
//
//                    TimeZoneCard(
//                        abbreviation: "JST",
//                        city: "Tokyo",
//                        countryCode: "JP",
//                        latitude: 35.6762,
//                        longitude: 139.6503,
//                        timeZoneID: "Asia/Tokyo",
//                        now: now
//                    )
//
//                    TimeZoneCard(
//                        abbreviation: "JST",
//                        city: "Sapporo",
//                        countryCode: "JP",
//                        latitude: 43.0618,
//                        longitude: 141.3545,
//                        timeZoneID: "Asia/Tokyo",
//                        now: now
//                    )
//
//                    TimeZoneCard(
//                        abbreviation: "JST",
//                        city: "Fukuoka",
//                        countryCode: "JP",
//                        latitude: 33.5904,
//                        longitude: 130.4017,
//                        timeZoneID: "Asia/Tokyo",
//                        now: now
//                    )
//
//                    TimeZoneCard(
//                        abbreviation: "JST",
//                        city: "Oita",
//                        countryCode: "JP",
//                        latitude: 33.2382,
//                        longitude: 131.6126,
//                        timeZoneID: "Asia/Tokyo",
//                        now: now
//                    )
//
//                    TimeZoneCard(
//                        abbreviation: "JST",
//                        city: "Hiroshima",
//                        countryCode: "JP",
//                        latitude: 34.3853,
//                        longitude: 132.4553,
//                        timeZoneID: "Asia/Tokyo",
//                        now: now
//                    )
//
//                    Spacer()
//                }
//                .padding()
//            }
//        }
//        .onReceive(timer) { value in
//            now = value
//        }
//    }
//}
//
//struct TimeZoneCard: View {
//    let abbreviation: String
//    let city: String
//    let countryCode: String
//    let latitude: Double
//    let longitude: Double
//    let timeZoneID: String
//    let now: Date
//
//    @StateObject private var weather = WeatherManager()
//    @State private var showingDetail = false
//
//    private var timeZone: TimeZone {
//        TimeZone(identifier: timeZoneID)!
//    }
//
//    private var hour: Int {
//        Calendar.current.dateComponents(
//            in: timeZone,
//            from: now
//        ).hour ?? 12
//    }
//
//    private var isDay: Bool {
//        hour >= 6 && hour < 18
//    }
//
//    var body: some View {
//        HStack {
//
//            VStack(alignment: .leading, spacing: 12) {
//
//                HStack {
//                    Image(systemName: weather.icon)
//                        .font(.system(size: 34))
//                        .foregroundStyle(isDay ? .yellow : .blue)
//
//                    Text(weather.temperature)
//                        .font(.title3.bold())
//
//                    Text(weather.condition)
//                        .font(.caption)
//                        .foregroundStyle(.secondary)
//                }
//
//                VStack(alignment: .leading, spacing: 2) {
//
//                    HStack {
//                        Text(abbreviation)
//                            .font(.title2.bold())
//
//                        Text(city)
//                            .foregroundStyle(.secondary)
//                    }
//
//                    HStack {
//                        Text(dayLabel())
//                            .font(.caption)
//                            .foregroundStyle(.secondary)
//                    }
//                }
//            }
//
//            Spacer()
//
//            VStack(alignment: .trailing, spacing: 8) {
//
//                Text(timeString())
//                    .font(.system(size: 36, weight: .light))
//                    .monospacedDigit()
//
//                HStack {
//                    Label(
//                        isBusinessHours ? "Business Hours" : "After Hours",
//                        systemImage: "briefcase.fill"
//                    )
//                    .font(.caption2)
//                    .foregroundStyle(isBusinessHours ? .green : .secondary)
//
//                    Text(utcOffset())
//                        .font(.caption2)
//                        .foregroundStyle(.tertiary)
//                }
//
//                Text(dateString())
//                    .font(.headline)
//                    .foregroundStyle(.secondary)
//            }
//        }
//        .padding(24)
//        .background(
//            RoundedRectangle(cornerRadius: 28)
//                .fill(
//                    isDay ?
//                    Color.yellow.opacity(0.12) :
//                    Color.indigo.opacity(0.12)
//                )
//        )
//        .overlay(
//            RoundedRectangle(cornerRadius: 28)
//                .stroke(Color.primary.opacity(0.08))
//        )
//        .contentShape(Rectangle())
//        .onTapGesture {
//            showingDetail = true
//        }
//        .task {
//            await weather.load(
//                latitude: latitude,
//                longitude: longitude
//            )
//        }
//        .sheet(isPresented: $showingDetail) {
//            CityDetailView(city: city, abbreviation: abbreviation, countryCode: countryCode)
//        }
//    }
//
//    private var isBusinessHours: Bool {
//        hour >= 9 && hour < 17
//    }
//
//    func timeString() -> String {
//        let formatter = DateFormatter()
//        formatter.timeZone = timeZone
//        formatter.dateFormat = "h:mm a"
//
//        return formatter.string(from: now)
//    }
//
//    func dateString() -> String {
//        let formatter = DateFormatter()
//        formatter.timeZone = timeZone
//        formatter.dateFormat = "EEE, MMM d"
//
//        return formatter.string(from: now)
//    }
//
//    func utcOffset() -> String {
//        let offset = timeZone.secondsFromGMT(for: now) / 3600
//
//        if offset >= 0 {
//            return "UTC +\(offset)"
//        } else {
//            return "UTC \(offset)"
//        }
//    }
//
//    func dayLabel() -> String {
//        let localDay = Calendar.current.startOfDay(for: now)
//
//        let remoteDate = now.addingTimeInterval(
//            TimeInterval(
//                timeZone.secondsFromGMT(for: now)
//                - TimeZone.current.secondsFromGMT(for: now)
//            )
//        )
//
//        let remoteDay = Calendar.current.startOfDay(for: remoteDate)
//
//        let difference = Calendar.current.dateComponents(
//            [.day],
//            from: localDay,
//            to: remoteDay
//        ).day ?? 0
//
//        switch difference {
//
//        case -1:
//            return "Yesterday"
//
//        case 1:
//            return "Tomorrow"
//
//        default:
//            return "Today"
//        }
//    }
//}
//
//#Preview {
//    ContentView()
//}
import SwiftUI
import Combine

// MARK: - Weather

struct WeatherResponse: Codable {
    let current: CurrentWeather
}

struct CurrentWeather: Codable {
    let temperature_2m: Double
    let weather_code: Int
}

@MainActor
class WeatherManager: ObservableObject {
    @Published var temperature = "--°"
    @Published var condition = "Loading..."
    @Published var icon = "cloud.fill"

    func load(latitude: Double, longitude: Double) async {
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code&temperature_unit=fahrenheit") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let weather = try JSONDecoder().decode(WeatherResponse.self, from: data)
            temperature = "\(Int(weather.current.temperature_2m.rounded()))°"
            switch weather.current.weather_code {
            case 0: condition = "Clear"; icon = "sun.max.fill"
            case 1, 2, 3: condition = "Partly Cloudy"; icon = "cloud.sun.fill"
            case 45, 48: condition = "Fog"; icon = "cloud.fog.fill"
            case 51...67: condition = "Rain"; icon = "cloud.rain.fill"
            case 71...77: condition = "Snow"; icon = "snowflake"
            case 80...82: condition = "Showers"; icon = "cloud.heavyrain.fill"
            case 95...99: condition = "Storm"; icon = "cloud.bolt.rain.fill"
            default: condition = "Cloudy"; icon = "cloud.fill"
            }
        } catch {
            temperature = "--°"
            condition = "Unavailable"
            icon = "exclamationmark.triangle"
        }
    }
}

// MARK: - City Events

struct CityEvent: Identifiable {
    let id: String
    let title: String
    let category: String
    let dateLabel: String
    let venue: String?
    let isFree: Bool
    let url: String?
}

enum EventsError: LocalizedError {
    case missingAPIKey(String)
    case badResponse(Int)
    case unsupportedCountry(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let service):
            return "Add your \(service) API key to CityEventsManager to load real events."
        case .badResponse(let code):
            return "The events source returned an error (status \(code))."
        case .unsupportedCountry(let code):
            return "No events source configured for country \(code)."
        }
    }
}

@MainActor
class CityEventsManager: ObservableObject {
    @Published var events: [CityEvent] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let ticketmasterKey = "VZGLABmlOrPw2s8RwDH4U6d0FA79LsfE"

    private static let ticketmasterCountries: Set<String> = [
        "US", "CA", "IE", "GB", "AU", "NZ", "MX",
        "AT", "BE", "DE", "DK", "ES", "FI", "NL", "NO", "PL", "SE", "FR"
    ]

    func load(city: String, countryCode: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if countryCode == "JP" {
                events = loadJapanOfficialLinks(city: city)
            } else if Self.ticketmasterCountries.contains(countryCode) {
                events = try await loadFromTicketmaster(city: normalizedCityForTicketmaster(city), countryCode: countryCode)
            } else {
                throw EventsError.unsupportedCountry(countryCode)
            }

            if events.isEmpty {
                errorMessage = "No events found for \(city) right now."
            }
        } catch let error as EventsError {
            errorMessage = error.localizedDescription
            events = []
        } catch {
            errorMessage = "Couldn't load events: \(error.localizedDescription)"
            events = []
        }
    }

    private func normalizedCityForTicketmaster(_ city: String) -> String {
        switch city.lowercased() {
        case "orange county":
            return "Anaheim"
        default:
            return city
        }
    }

    // MARK: Ticketmaster

    private func loadFromTicketmaster(city: String, countryCode: String) async throws -> [CityEvent] {
        guard !ticketmasterKey.isEmpty else {
            throw EventsError.missingAPIKey("Ticketmaster")
        }

        var components = URLComponents(string: "https://app.ticketmaster.com/discovery/v2/events.json")!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: ticketmasterKey),
            URLQueryItem(name: "city", value: city),
            URLQueryItem(name: "countryCode", value: countryCode),
            URLQueryItem(name: "sort", value: "date,asc"),
            URLQueryItem(name: "size", value: "20")
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw EventsError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(TicketmasterResponse.self, from: data)

        return (decoded.embedded?.events ?? []).map { event in
            CityEvent(
                id: event.id,
                title: event.name,
                category: event.classifications?.first?.segment?.name ?? "Event",
                dateLabel: Self.formatTicketmasterDate(date: event.dates?.start?.localDate, time: event.dates?.start?.localTime),
                venue: event.embedded?.venues?.first?.name,
                isFree: (event.priceRanges?.first?.min ?? -1) == 0,
                url: event.url
            )
        }
    }

    private static func formatTicketmasterDate(date: String?, time: String?) -> String {
        guard let date else { return "Date TBD" }
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = time != nil ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd"
        let combined = time != nil ? "\(date)T\(time!)" : date
        guard let parsed = inputFormatter.date(from: combined) else { return date }
        let display = DateFormatter()
        display.dateFormat = time != nil ? "EEE, MMM d · h:mm a" : "EEE, MMM d"
        return display.string(from: parsed)
    }

    // MARK: Japan official links

    private func loadJapanOfficialLinks(city: String) -> [CityEvent] {
        let cityLower = city.lowercased()

        if cityLower.contains("tokyo") {
            return [
                CityEvent(id: "tokyo-1", title: "Tokyo Event Calendar", category: "Official Tourism", dateLabel: "Open current listings", venue: "GO TOKYO", isFree: true, url: "https://www.gotokyo.org/en/calendar/index.html"),
                CityEvent(id: "tokyo-2", title: "Tokyo Events and Tickets", category: "Official Tourism", dateLabel: "Tickets and experiences", venue: "GO TOKYO", isFree: true, url: "https://www.tickets.gotokyo.org/en/"),
                CityEvent(id: "tokyo-3", title: "Tokyo Travel Guide", category: "Official Tourism", dateLabel: "Plan your visit", venue: "GO TOKYO", isFree: true, url: "https://www.gotokyo.org/en/index.html")
            ]
        } else if cityLower.contains("kyoto") {
            return [
                CityEvent(id: "kyoto-1", title: "Kyoto Festivals & Events", category: "Official Tourism", dateLabel: "Current listings", venue: "Kyoto Travel", isFree: true, url: "https://kyoto.travel/en/events/"),
                CityEvent(id: "kyoto-2", title: "Kyoto Travel Guide", category: "Official Tourism", dateLabel: "Plan your visit", venue: "Kyoto Travel", isFree: true, url: "https://kyoto.travel/en/"),
                CityEvent(id: "kyoto-3", title: "Kyoto Festivals & Events Overview", category: "Official Tourism", dateLabel: "See guide", venue: "Kyoto Travel", isFree: true, url: "https://kyoto.travel/en/see-and-do/festivals.html")
            ]
        }
        else if cityLower.contains("fukuoka") {
            return [
                CityEvent(id: "fukuoka-1", title: "Fukuoka City Events Calendar", category: "Official Tourism", dateLabel: "Latest city events", venue: "Fukuoka City", isFree: true, url: "https://gofukuoka.jp/calendar.html"),
                CityEvent(id: "fukuoka-2", title: "VISIT FUKUOKA Events", category: "Official Tourism", dateLabel: "Prefecture events and festivals", venue: "VISIT FUKUOKA", isFree: true, url: "https://www.crossroadfukuoka.jp/en/event"),
                CityEvent(id: "fukuoka-3", title: "Fukuoka Festivals Guide", category: "Official Tourism", dateLabel: "Annual festivals", venue: "Fukuoka City", isFree: true, url: "https://www.welcome-fukuoka.or.jp/english/convention/fukuoka/fukuoka_events")
            ]
        } else if cityLower.contains("oita") {
            return [
                CityEvent(id: "oita-1", title: "Oita Events", category: "Official Tourism", dateLabel: "Prefecture events", venue: "Visit Oita", isFree: true, url: "https://oita-tourism.com/en/events/index.html"),
                CityEvent(id: "oita-2", title: "Oita Tanabata Festival", category: "Official Tourism", dateLabel: "Featured event", venue: "Visit Oita", isFree: true, url: "https://oita-tourism.com/en/events/detail_1102.html")
            ]
        } else if cityLower.contains("beppu") {
            return [
                CityEvent(id: "beppu-1", title: "Beppu Tourism", category: "Official Tourism", dateLabel: "Local events and travel info", venue: "Beppu Tabi", isFree: true, url: "https://beppu-tourism.com/en/"),
                CityEvent(id: "beppu-2", title: "Oita Events – Beppu Area", category: "Official Tourism", dateLabel: "Beppu Bay area events", venue: "Visit Oita", isFree: true, url: "https://oita-tourism.com/en/events/index_1_2_13.html")
            ]
        }
        else {
            return [
                CityEvent(id: "jp-1", title: "Japan National Tourism Organization", category: "Official Tourism", dateLabel: "Festivals and events", venue: "JNTO", isFree: true, url: "https://www.japan.travel/en/"),
                CityEvent(id: "jp-2", title: "Japan Cultural Expo Events", category: "Official Tourism", dateLabel: "Arts and culture events", venue: "Japan Cultural Expo", isFree: true, url: "https://japanculturalexpo.bunka.go.jp/en/events/?type=All&region=All&status=All"),
                CityEvent(id: "jp-3", title: "Tokyo Event Calendar", category: "Official Tourism", dateLabel: "Tokyo listings", venue: "GO TOKYO", isFree: true, url: "https://www.gotokyo.org/en/calendar/index.html")
            ]
        }
    }
}

struct TicketmasterResponse: Codable {
    let embedded: TicketmasterEmbeddedEvents?
    enum CodingKeys: String, CodingKey { case embedded = "_embedded" }
}

struct TicketmasterEmbeddedEvents: Codable { let events: [TicketmasterEvent]? }

struct TicketmasterEvent: Codable {
    let id: String
    let name: String
    let url: String?
    let dates: TicketmasterDates?
    let classifications: [TicketmasterClassification]?
    let priceRanges: [TicketmasterPriceRange]?
    let embedded: TicketmasterEmbeddedVenues?

    enum CodingKeys: String, CodingKey { case id, name, url, dates, classifications, priceRanges; case embedded = "_embedded" }
}

struct TicketmasterEmbeddedVenues: Codable { let venues: [TicketmasterVenue]? }
struct TicketmasterVenue: Codable { let name: String? }
struct TicketmasterDates: Codable { let start: TicketmasterStart? }
struct TicketmasterStart: Codable { let localDate: String?; let localTime: String? }
struct TicketmasterClassification: Codable { let segment: TicketmasterSegment? }
struct TicketmasterSegment: Codable { let name: String? }
struct TicketmasterPriceRange: Codable { let min: Double? }

struct CityDetailView: View {
    let city: String
    let abbreviation: String
    let countryCode: String

    @StateObject private var events = CityEventsManager()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if events.isLoading {
                    ProgressView("Loading events…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if events.events.isEmpty {
                    ContentUnavailableFallback(message: events.errorMessage ?? "Nothing found.")
                } else {
                    List(events.events) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(event.title)
                                    .font(.headline)
                                Spacer()
                                if event.isFree {
                                    Text("FREE")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15))
                                        .foregroundStyle(.green)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(event.dateLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let venue = event.venue {
                                Label(venue, systemImage: "mappin.and.ellipse")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            HStack {
                                Text(event.category)
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                if let urlString = event.url, let url = URL(string: urlString) {
                                    Spacer()
                                    Link("Details", destination: url)
                                        .font(.caption2)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("What's on in \(city)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await events.load(city: city, countryCode: countryCode)
            }
        }
    }
}

struct ContentUnavailableFallback: View {
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ContentView: View {
    @State private var now = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.08), Color.gray.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 10) {
                    TimeZoneCard(
                        abbreviation: "PST",
                        city: "Los Angeles",
                        countryCode: "US",
                        latitude: 34.0522,
                        longitude: -118.2437,
                        timeZoneID: "America/Los_Angeles",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "PST",
                        city: "Orange County",
                        countryCode: "US",
                        latitude: 33.7174,
                        longitude: -117.8311,
                        timeZoneID: "America/Los_Angeles",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "EST",
                        city: "New York",
                        countryCode: "US",
                        latitude: 40.7128,
                        longitude: -74.0060,
                        timeZoneID: "America/New_York",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Tokyo",
                        countryCode: "JP",
                        latitude: 35.6762,
                        longitude: 139.6503,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Fukuoka",
                        countryCode: "JP",
                        latitude: 33.5902,
                        longitude: 130.4017,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Oita",
                        countryCode: "JP",
                        latitude: 33.2396,
                        longitude: 131.6093,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Beppu",
                        countryCode: "JP",
                        latitude: 33.2847,
                        longitude: 131.4911,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Hiroshima",
                        countryCode: "JP",
                        latitude: 34.3853,
                        longitude: 132.4553,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Sapporo",
                        countryCode: "JP",
                        latitude: 43.0618,
                        longitude: 141.3545,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Otaru",
                        countryCode: "JP",
                        latitude: 43.1888,
                        longitude: 140.9876,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )
                    
                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Kyoto",
                        countryCode: "JP",
                        latitude: 35.0116,
                        longitude: 135.7681,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Osaka",
                        countryCode: "JP",
                        latitude: 34.6937,
                        longitude: 135.5023,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )
                    
                }
                .padding()
            }
        }
        .onReceive(timer) { now = $0 }
    }
}

struct TimeZoneCard: View {
    let abbreviation: String
    let city: String
    let countryCode: String
    let latitude: Double
    let longitude: Double
    let timeZoneID: String
    let now: Date

    @StateObject private var weather = WeatherManager()
    @State private var showingDetail = false

    private var timeZone: TimeZone { TimeZone(identifier: timeZoneID)! }
    private var hour: Int { Calendar.current.dateComponents(in: timeZone, from: now).hour ?? 12 }
    private var isDay: Bool { hour >= 6 && hour < 18 }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: weather.icon)
                        .font(.system(size: 34))
                        .foregroundStyle(isDay ? .yellow : .blue)

                    Text(weather.temperature)
                        .font(.title3.bold())

                    Text(weather.condition)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(abbreviation)
                            .font(.title2.bold())

                        Text(city)
                            .foregroundStyle(.secondary)
                    }

                    Text(dayLabel())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text(timeString())
                    .font(.system(size: 36, weight: .light))
                    .monospacedDigit()

                HStack {
                    Label(isBusinessHours ? "Business Hours" : "After Hours", systemImage: "briefcase.fill")
                        .font(.caption2)
                        .foregroundStyle(isBusinessHours ? .green : .secondary)

                    Text(utcOffset())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(dateString())
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(isDay ? Color.yellow.opacity(0.12) : Color.indigo.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.primary.opacity(0.08))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            showingDetail = true
        }
        .task {
            await weather.load(latitude: latitude, longitude: longitude)
        }
        .sheet(isPresented: $showingDetail) {
            CityDetailView(city: city, abbreviation: abbreviation, countryCode: countryCode)
        }
    }

    private var isBusinessHours: Bool { hour >= 9 && hour < 17 }

    func timeString() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: now)
    }

    func dateString() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: now)
    }

    func utcOffset() -> String {
        let offset = timeZone.secondsFromGMT(for: now) / 3600
        return offset >= 0 ? "UTC +\(offset)" : "UTC \(offset)"
    }

    func dayLabel() -> String {
        let localDay = Calendar.current.startOfDay(for: now)
        let remoteDate = now.addingTimeInterval(TimeInterval(timeZone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)))
        let remoteDay = Calendar.current.startOfDay(for: remoteDate)
        let difference = Calendar.current.dateComponents([.day], from: localDay, to: remoteDay).day ?? 0

        switch difference {
        case -1:
            return "Yesterday"
        case 1:
            return "Tomorrow"
        default:
            return "Today"
        }
    }
}

#Preview {
    ContentView()
}
