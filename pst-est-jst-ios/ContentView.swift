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
            case 0:
                condition = "Clear"
                icon = "sun.max.fill"
            case 1, 2, 3:
                condition = "Partly Cloudy"
                icon = "cloud.sun.fill"
            case 45, 48:
                condition = "Fog"
                icon = "cloud.fog.fill"
            case 51...67:
                condition = "Rain"
                icon = "cloud.rain.fill"
            case 71...77:
                condition = "Snow"
                icon = "snowflake"
            case 80...82:
                condition = "Showers"
                icon = "cloud.heavyrain.fill"
            case 95...99:
                condition = "Storm"
                icon = "cloud.bolt.rain.fill"
            default:
                condition = "Cloudy"
                icon = "cloud.fill"
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
        } else if cityLower.contains("fukuoka") {
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
                CityEvent(id: "beppu-2", title: "Oita Events – Beppu Area", category: "Official Tourism", dateLabel: "Beppu area events", venue: "Visit Oita", isFree: true, url: "https://oita-tourism.com/en/events/index_1_2_13.html")
            ]
        } else if cityLower.contains("hiroshima") {
            return [
                CityEvent(id: "hiroshima-1", title: "Hiroshima Events", category: "Official Tourism", dateLabel: "Current prefecture events", venue: "Dive Hiroshima", isFree: true, url: "https://dive-hiroshima.com/en/events/"),
                CityEvent(id: "hiroshima-2", title: "Hiroshima Travel Guide", category: "Official Tourism", dateLabel: "Plan your trip", venue: "Dive Hiroshima", isFree: true, url: "https://dive-hiroshima.com/en/")
            ]
        } else if cityLower.contains("sapporo") {
            return [
                CityEvent(id: "sapporo-1", title: "Sapporo Event List", category: "Official Tourism", dateLabel: "Current events", venue: "Welcome to Sapporo", isFree: true, url: "https://www.sapporo.travel/en/event/event-list/?cgnr[]="),
                CityEvent(id: "sapporo-2", title: "Hokkaido Events", category: "Official Tourism", dateLabel: "Prefecture-wide events", venue: "HOKKAIDO LOVE!", isFree: true, url: "https://www.visit-hokkaido.jp/en/event/index.html")
            ]
        } else if cityLower.contains("otaru") {
            return [
                CityEvent(id: "otaru-1", title: "Otaru Events", category: "Official Tourism", dateLabel: "Current events", venue: "Visit Otaru", isFree: true, url: "https://www.visit-otaru-en.info/events"),
                CityEvent(id: "otaru-2", title: "Otaru Events & Stories", category: "Official Tourism", dateLabel: "Local recommendations", venue: "Otaru tourism", isFree: true, url: "https://www.visit-otaru-en.info/")
            ]
        } else {
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

    enum CodingKeys: String, CodingKey {
        case id, name, url, dates, classifications, priceRanges
        case embedded = "_embedded"
    }
}

struct TicketmasterEmbeddedVenues: Codable { let venues: [TicketmasterVenue]? }
struct TicketmasterVenue: Codable { let name: String? }
struct TicketmasterDates: Codable { let start: TicketmasterStart? }
struct TicketmasterStart: Codable { let localDate: String?; let localTime: String? }
struct TicketmasterClassification: Codable { let segment: TicketmasterSegment? }
struct TicketmasterSegment: Codable { let name: String? }
struct TicketmasterPriceRange: Codable { let min: Double? }

// MARK: - Event Row

struct EventRow: View {
    let event: CityEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(event.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

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

            HStack(spacing: 10) {
                Text(event.category)
                    .font(.caption2)
                    .foregroundStyle(.blue)

                if let urlString = event.url, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Label("Open details", systemImage: "arrow.up.right.square")
                            .font(.caption2)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail View

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
                        EventRow(event: event)
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

// MARK: - Main View

struct ContentView: View {
    @State private var now = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.08), Color.white.opacity(0.10)],
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
                }
                .padding()
            }
        }
        .onReceive(timer) { now = $0 }
    }
}

// MARK: - Time Zone Card

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
                    weatherIcon
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

    private var weatherIcon: some View {
        Group {
            switch weather.icon {
            case "sun.max.fill":
                Image(systemName: weather.icon)
                    .font(.system(size: 34))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.yellow)

            case "cloud.sun.fill":
                Image(systemName: weather.icon)
                    .font(.system(size: 34))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .yellow)

            case "cloud.fog.fill", "cloud.fill":
                Image(systemName: weather.icon)
                    .font(.system(size: 34))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)

            case "cloud.rain.fill", "cloud.heavyrain.fill", "cloud.bolt.rain.fill":
                Image(systemName: weather.icon)
                    .font(.system(size: 34))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .blue)

            case "snowflake":
                Image(systemName: weather.icon)
                    .font(.system(size: 34))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)

            case "exclamationmark.triangle":
                Image(systemName: weather.icon)
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)

            default:
                Image(systemName: weather.icon)
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            }
        }
    }

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
