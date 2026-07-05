import SwiftUI
import Combine

// MARK: - Shared weather-code mapping

enum WeatherCodeMapper {
    static func iconAndCondition(for code: Int) -> (icon: String, condition: String) {
        switch code {
        case 0:
            return ("sun.max.fill", "Clear")
        case 1, 2, 3:
            return ("cloud.sun.fill", "Partly Cloudy")
        case 45, 48:
            return ("cloud.fog.fill", "Fog")
        case 51...67:
            return ("cloud.rain.fill", "Rain")
        case 71...77:
            return ("snowflake", "Snow")
        case 80...82:
            return ("cloud.heavyrain.fill", "Showers")
        case 95...99:
            return ("cloud.bolt.rain.fill", "Storm")
        default:
            return ("cloud.fill", "Cloudy")
        }
    }
}

// MARK: - Weather (current conditions)

struct WeatherResponse: Codable {
    let current: CurrentWeather
    let daily: SunTimes?
}

struct CurrentWeather: Codable {
    let temperature_2m: Double
    let weather_code: Int
}

struct SunTimes: Codable {
    let sunrise: [String]
    let sunset: [String]
}

@MainActor
class WeatherManager: ObservableObject {
    @Published var temperature = "--°"
    @Published var condition = "Loading..."
    @Published var icon = "cloud.fill"
    @Published var sunrise = "--:--"
    @Published var sunset = "--:--"

    func load(latitude: Double, longitude: Double) async {
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code&daily=sunrise,sunset&temperature_unit=fahrenheit&timezone=auto") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let weather = try JSONDecoder().decode(WeatherResponse.self, from: data)
            temperature = "\(Int(weather.current.temperature_2m.rounded()))°"

            let mapped = WeatherCodeMapper.iconAndCondition(for: weather.current.weather_code)
            condition = mapped.condition
            icon = mapped.icon

            if let firstSunrise = weather.daily?.sunrise.first {
                sunrise = Self.formatSunTime(firstSunrise)
            }
            if let firstSunset = weather.daily?.sunset.first {
                sunset = Self.formatSunTime(firstSunset)
            }
        } catch {
            temperature = "--°"
            condition = "Unavailable"
            icon = "exclamationmark.triangle"
            sunrise = "--:--"
            sunset = "--:--"
        }
    }

    /// Open-Meteo returns naive local time strings like "2026-07-05T05:48" when
    /// timezone=auto is set, so both parsing and formatting are pinned to UTC
    /// here to preserve the wall-clock value instead of shifting it to the
    /// device's own time zone.
    private static func formatSunTime(_ isoString: String) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        inputFormatter.timeZone = TimeZone(identifier: "UTC")

        guard let parsed = inputFormatter.date(from: isoString) else { return "--:--" }

        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "h:mm a"
        outputFormatter.timeZone = TimeZone(identifier: "UTC")
        return outputFormatter.string(from: parsed)
    }
}

// MARK: - 5-Day Forecast

struct ForecastResponse: Codable {
    let daily: DailyWeather
}

struct DailyWeather: Codable {
    let time: [String]
    let weather_code: [Int]
    let temperature_2m_max: [Double]
    let temperature_2m_min: [Double]
}

struct ForecastDay: Identifiable {
    let id: String
    let dayLabel: String
    let icon: String
    let condition: String
    let high: Int
    let low: Int
}

@MainActor
class ForecastManager: ObservableObject {
    @Published var days: [ForecastDay] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load(latitude: Double, longitude: Double) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&daily=weather_code,temperature_2m_max,temperature_2m_min&temperature_unit=fahrenheit&forecast_days=7&timezone=auto") else {
            errorMessage = "Couldn't build forecast request."
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                errorMessage = "Forecast unavailable right now."
                return
            }

            let decoded = try JSONDecoder().decode(ForecastResponse.self, from: data)
            days = Self.buildDays(from: decoded.daily)

            if days.isEmpty {
                errorMessage = "No forecast data available."
            }
        } catch {
            errorMessage = "Couldn't load forecast: \(error.localizedDescription)"
            days = []
        }
    }

    private static func buildDays(from daily: DailyWeather) -> [ForecastDay] {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"

        let labelFormatter = DateFormatter()
        labelFormatter.dateFormat = "EEE"

        let count = min(daily.time.count, daily.weather_code.count, daily.temperature_2m_max.count, daily.temperature_2m_min.count)

        return (0..<count).map { index in
            let dateString = daily.time[index]
            let label: String
            if let parsed = inputFormatter.date(from: dateString) {
                label = index == 0 ? "Today" : labelFormatter.string(from: parsed)
            } else {
                label = dateString
            }

            let mapped = WeatherCodeMapper.iconAndCondition(for: daily.weather_code[index])

            return ForecastDay(
                id: dateString,
                dayLabel: label,
                icon: mapped.icon,
                condition: mapped.condition,
                high: Int(daily.temperature_2m_max[index].rounded()),
                low: Int(daily.temperature_2m_min[index].rounded())
            )
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

// MARK: - Forecast Strip

struct ForecastDayCard: View {
    let day: ForecastDay

    var body: some View {
        VStack(spacing: 8) {
            Text(day.dayLabel)
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Image(systemName: day.icon)
                .font(.system(size: 22))
                .symbolRenderingMode(.multicolor)
                .frame(height: 26)

            Text("\(day.high)°")
                .font(.subheadline.bold())

            Text("\(day.low)°")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 64)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

struct ForecastStripView: View {
    @ObservedObject var forecast: ForecastManager

    var body: some View {
        Group {
            if forecast.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(height: 90)
            } else if forecast.days.isEmpty {
                Text(forecast.errorMessage ?? "Forecast unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(forecast.days) { day in
                            ForecastDayCard(day: day)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

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
    let latitude: Double
    let longitude: Double

    @StateObject private var forecast = ForecastManager()
    @StateObject private var events = CityEventsManager()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("7-Day Forecast") {
                    ForecastStripView(forecast: forecast)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }

                Section("What's Happening in \(city)") {
                    if events.isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Loading events…")
                            Spacer()
                        }
                    } else if events.events.isEmpty {
                        Text(events.errorMessage ?? "Nothing found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(events.events) { event in
                            EventRow(event: event)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(city)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                async let forecastLoad: () = forecast.load(latitude: latitude, longitude: longitude)
                async let eventsLoad: () = events.load(city: city, countryCode: countryCode)
                _ = await (forecastLoad, eventsLoad)
            }
        }
    }
}

// MARK: - City Model & Persistent Store

struct City: Identifiable, Codable, Equatable {
    var id: UUID
    var city: String
    var countryCode: String
    var latitude: Double
    var longitude: Double
    var timeZoneID: String

    init(id: UUID = UUID(), city: String, countryCode: String, latitude: Double, longitude: Double, timeZoneID: String) {
        self.id = id
        self.city = city
        self.countryCode = countryCode
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneID = timeZoneID
    }
}

@MainActor
class CityStore: ObservableObject {
    @Published var cities: [City] {
        didSet { save() }
    }

    private let storageKey = "worldClock.savedCities.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([City].self, from: data) {
            cities = decoded
        } else {
            cities = Self.defaultCities
        }
    }

    func addCity(_ city: City) {
        cities.append(city)
    }

    func removeCities(at offsets: IndexSet) {
        cities.remove(atOffsets: offsets)
    }

    func moveCities(from source: IndexSet, to destination: Int) {
        cities.move(fromOffsets: source, toOffset: destination)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cities) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static let defaultCities: [City] = [
        City(city: "Los Angeles", countryCode: "US", latitude: 34.0522, longitude: -118.2437, timeZoneID: "America/Los_Angeles"),
        City(city: "Orange County", countryCode: "US", latitude: 33.7174, longitude: -117.8311, timeZoneID: "America/Los_Angeles"),
        City(city: "New York", countryCode: "US", latitude: 40.7128, longitude: -74.0060, timeZoneID: "America/New_York"),
        City(city: "Tokyo", countryCode: "JP", latitude: 35.6762, longitude: 139.6503, timeZoneID: "Asia/Tokyo"),
        City(city: "Kyoto", countryCode: "JP", latitude: 35.0116, longitude: 135.7681, timeZoneID: "Asia/Tokyo"),
        City(city: "Osaka", countryCode: "JP", latitude: 34.6937, longitude: 135.5023, timeZoneID: "Asia/Tokyo"),
        City(city: "Fukuoka", countryCode: "JP", latitude: 33.5902, longitude: 130.4017, timeZoneID: "Asia/Tokyo"),
        City(city: "Oita", countryCode: "JP", latitude: 33.2396, longitude: 131.6093, timeZoneID: "Asia/Tokyo"),
        City(city: "Beppu", countryCode: "JP", latitude: 33.2847, longitude: 131.4911, timeZoneID: "Asia/Tokyo"),
        City(city: "Hiroshima", countryCode: "JP", latitude: 34.3853, longitude: 132.4553, timeZoneID: "Asia/Tokyo"),
        City(city: "Sapporo", countryCode: "JP", latitude: 43.0618, longitude: 141.3545, timeZoneID: "Asia/Tokyo"),
        City(city: "Otaru", countryCode: "JP", latitude: 43.1888, longitude: 140.9876, timeZoneID: "Asia/Tokyo")
    ]
}

// MARK: - City Search (Add City)

struct GeocodingResponse: Codable {
    let results: [GeocodingResult]?
}

struct GeocodingResult: Codable, Identifiable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country_code: String?
    let admin1: String?
    let timezone: String?

    var displayName: String {
        if let admin1, !admin1.isEmpty, admin1 != name {
            return "\(name), \(admin1)"
        }
        return name
    }
}

@MainActor
class CitySearchService: ObservableObject {
    @Published var results: [GeocodingResult] = []
    @Published var isSearching = false
    @Published var errorMessage: String?

    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        guard var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search") else { return }
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ]

        guard let url = components.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(GeocodingResponse.self, from: data)

            guard trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

            results = decoded.results ?? []
            if results.isEmpty {
                errorMessage = "No cities found for \"\(trimmed)\"."
            }
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            results = []
        }
    }
}

struct AddCityView: View {
    @ObservedObject var store: CityStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var search = CitySearchService()
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if search.isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let message = search.errorMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                } else if query.isEmpty {
                    Text("Search for a city to add it to your list.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(search.results) { result in
                        Button {
                            addCity(from: result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.displayName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                Text(result.country_code ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search for a city")
            .onChange(of: query) { newValue in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    await search.search(query: newValue)
                }
            }
            .navigationTitle("Add City")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func addCity(from result: GeocodingResult) {
        let newCity = City(
            city: result.name,
            countryCode: result.country_code ?? "US",
            latitude: result.latitude,
            longitude: result.longitude,
            timeZoneID: result.timezone ?? TimeZone.current.identifier
        )
        store.addCity(newCity)
        dismiss()
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var store = CityStore()
    @State private var now = Date()
    @State private var showingAddCity = false
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.cities) { city in
                    TimeZoneCard(city: city, now: now)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                }
                .onMove { source, destination in
                    store.moveCities(from: source, to: destination)
                }
                .onDelete { offsets in
                    store.removeCities(at: offsets)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [Color.blue.opacity(0.08), Color.white.opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("World Clock")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddCity = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddCity) {
                AddCityView(store: store)
            }
        }
        .onReceive(timer) { now = $0 }
    }
}

// MARK: - Time Zone Card

struct TimeZoneCard: View {
    let city: City
    let now: Date

    @StateObject private var weather = WeatherManager()
    @State private var showingDetail = false

    private var timeZone: TimeZone { TimeZone(identifier: city.timeZoneID) ?? .current }
    private var hour: Int { Calendar.current.dateComponents(in: timeZone, from: now).hour ?? 12 }
    private var isDay: Bool { hour >= 6 && hour < 18 }
    private var abbreviation: String { timeZone.abbreviation(for: now) ?? utcOffset() }

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
                            .font(.subheadline.bold())

                        Text(city.city)
                            .foregroundStyle(.secondary)
                    }

                    Text(dayLabel())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "sunrise.fill")
                            .foregroundStyle(.yellow)
                        Text(weather.sunrise)
                            .foregroundStyle(.yellow)
                    }
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                    HStack(spacing: 3) {
                        Image(systemName: "sunset.fill")
                            .foregroundStyle(.blue)
                        Text(weather.sunset)
                            .foregroundStyle(.blue)
                    }
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text(timeString())
                    .font(.system(size: 36, weight: .light))
                    .monospacedDigit()

                VStack(alignment: .trailing, spacing: 2) {
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
        .task(id: city.id) {
            await weather.load(latitude: city.latitude, longitude: city.longitude)
        }
        .sheet(isPresented: $showingDetail) {
            CityDetailView(
                city: city.city,
                abbreviation: abbreviation,
                countryCode: city.countryCode,
                latitude: city.latitude,
                longitude: city.longitude
            )
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
