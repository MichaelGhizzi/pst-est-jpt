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

        guard let url = URL(
            string:
            "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code&temperature_unit=fahrenheit"
        ) else { return }

        do {

            let (data, _) = try await URLSession.shared.data(from: url)

            let weather = try JSONDecoder().decode(
                WeatherResponse.self,
                from: data
            )

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
            return "The events API returned an error (status \(code))."
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

    // Ticketmaster covers: US, CA, IE, GB, AU, NZ, MX, AT, BE, DE, DK, ES, FI, NL, NO, PL, SE, FR
    // Get a free key at https://developer.ticketmaster.com
    // (register -> default app is created instantly -> copy the Consumer Key)
    private let ticketmasterKey = "VZGLABmlOrPw2s8RwDH4U6d0FA79LsfE" // e.g. "AbCdEfGhIjKlMnOpQrStUvWxYz"

    // PredictHQ has real Japan coverage (festivals, concerts, public holidays).
    // Get a token at https://www.predicthq.com/apis (free trial, paid for full access)
    private let predictHQToken = "" // e.g. "YOUR_PREDICTHQ_ACCESS_TOKEN"

    private static let ticketmasterCountries: Set<String> = [
        "US", "CA", "IE", "GB", "AU", "NZ", "MX",
        "AT", "BE", "DE", "DK", "ES", "FI", "NL", "NO", "PL", "SE", "FR",
    ]

    /// countryCode should be the ISO country code for the city, e.g. "US" or "JP"
    func load(city: String, countryCode: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if CityEventsManager.ticketmasterCountries.contains(countryCode) {
                events = try await loadFromTicketmaster(city: city, countryCode: countryCode)
            } else if countryCode == "JP" {
                events = try await loadFromPredictHQ(city: city)
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

    // MARK: Ticketmaster (US, CA, UK, etc.)

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
            URLQueryItem(name: "size", value: "20"),
        ]

        let url = components.url!
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw EventsError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(TicketmasterResponse.self, from: data)

        return (decoded.embedded?.events ?? []).map { event in
            CityEvent(
                id: event.id,
                title: event.name,
                category: event.classifications?.first?.segment?.name ?? "Event",
                dateLabel: CityEventsManager.formatTicketmasterDate(
                    date: event.dates?.start?.localDate,
                    time: event.dates?.start?.localTime
                ),
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

    // MARK: PredictHQ (Japan and other non-Ticketmaster markets)

    private func loadFromPredictHQ(city: String) async throws -> [CityEvent] {
        guard !predictHQToken.isEmpty else {
            throw EventsError.missingAPIKey("PredictHQ")
        }

        var components = URLComponents(string: "https://api.predicthq.com/v1/events/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: city),
            URLQueryItem(name: "country", value: "JP"),
            URLQueryItem(name: "category", value: "festivals,community,performing-arts,concerts"),
            URLQueryItem(name: "sort", value: "start"),
            URLQueryItem(name: "limit", value: "20"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(predictHQToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw EventsError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(PredictHQResponse.self, from: data)

        return decoded.results.map { result in
            CityEvent(
                id: result.id,
                title: result.title,
                category: result.category.capitalized,
                dateLabel: CityEventsManager.formatPredictHQDate(result.start),
                venue: result.geo?.address?.locality,
                // PredictHQ doesn't expose ticket price; treat as unknown rather than assuming paid or free.
                isFree: false,
                url: nil
            )
        }
    }

    private static func formatPredictHQDate(_ iso: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let parsed = isoFormatter.date(from: iso) ?? {
            isoFormatter.formatOptions = [.withInternetDateTime]
            return isoFormatter.date(from: iso)
        }()

        guard let date = parsed else { return iso }

        let display = DateFormatter()
        display.dateFormat = "EEE, MMM d · h:mm a"
        return display.string(from: date)
    }
}

// MARK: - Ticketmaster Discovery API response models

struct TicketmasterResponse: Codable {
    let embedded: TicketmasterEmbeddedEvents?

    enum CodingKeys: String, CodingKey {
        case embedded = "_embedded"
    }
}

struct TicketmasterEmbeddedEvents: Codable {
    let events: [TicketmasterEvent]?
}

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

struct TicketmasterEmbeddedVenues: Codable {
    let venues: [TicketmasterVenue]?
}

struct TicketmasterVenue: Codable {
    let name: String?
}

struct TicketmasterDates: Codable {
    let start: TicketmasterStart?
}

struct TicketmasterStart: Codable {
    let localDate: String?
    let localTime: String?
}

struct TicketmasterClassification: Codable {
    let segment: TicketmasterSegment?
}

struct TicketmasterSegment: Codable {
    let name: String?
}

struct TicketmasterPriceRange: Codable {
    let min: Double?
}

// MARK: - PredictHQ API response models

struct PredictHQResponse: Codable {
    let results: [PredictHQEvent]
}

struct PredictHQEvent: Codable {
    let id: String
    let title: String
    let category: String
    let start: String
    let geo: PredictHQGeo?
}

struct PredictHQGeo: Codable {
    let address: PredictHQAddress?
}

struct PredictHQAddress: Codable {
    let locality: String?
}

// MARK: - City Detail Sheet

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

// Small fallback view so this compiles cleanly on iOS versions
// without ContentUnavailableView (iOS 17+).
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

// MARK: - Main Content

struct ContentView: View {

    @State private var now = Date()

    let timer = Timer.publish(
        every: 1,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {

        ZStack {
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.08),
                    Color.gray.opacity(0.10)
                ],
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
                        city: "Sapporo",
                        countryCode: "JP",
                        latitude: 43.0618,
                        longitude: 141.3545,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Fukuoka",
                        countryCode: "JP",
                        latitude: 33.5904,
                        longitude: 130.4017,
                        timeZoneID: "Asia/Tokyo",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Oita",
                        countryCode: "JP",
                        latitude: 33.2382,
                        longitude: 131.6126,
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

                    Spacer()
                }
                .padding()
            }
        }
        .onReceive(timer) { value in
            now = value
        }
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

    private var timeZone: TimeZone {
        TimeZone(identifier: timeZoneID)!
    }

    private var hour: Int {
        Calendar.current.dateComponents(
            in: timeZone,
            from: now
        ).hour ?? 12
    }

    private var isDay: Bool {
        hour >= 6 && hour < 18
    }

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

                    HStack {
                        Text(dayLabel())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {

                Text(timeString())
                    .font(.system(size: 36, weight: .light))
                    .monospacedDigit()

                HStack {
                    Label(
                        isBusinessHours ? "Business Hours" : "After Hours",
                        systemImage: "briefcase.fill"
                    )
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
                .fill(
                    isDay ?
                    Color.yellow.opacity(0.12) :
                    Color.indigo.opacity(0.12)
                )
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
            await weather.load(
                latitude: latitude,
                longitude: longitude
            )
        }
        .sheet(isPresented: $showingDetail) {
            CityDetailView(city: city, abbreviation: abbreviation, countryCode: countryCode)
        }
    }

    private var isBusinessHours: Bool {
        hour >= 9 && hour < 17
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

        if offset >= 0 {
            return "UTC +\(offset)"
        } else {
            return "UTC \(offset)"
        }
    }

    func dayLabel() -> String {

        let localDay = Calendar.current.startOfDay(for: now)

        let remoteDate = now.addingTimeInterval(
            TimeInterval(
                timeZone.secondsFromGMT(for: now)
                - TimeZone.current.secondsFromGMT(for: now)
            )
        )

        let remoteDay = Calendar.current.startOfDay(for: remoteDate)

        let difference = Calendar.current.dateComponents(
            [.day],
            from: localDay,
            to: remoteDay
        ).day ?? 0

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
