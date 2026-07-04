import SwiftUI
import Combine

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
                        latitude: 34.0522,
                        longitude: -118.2437,
                        timeZoneID: "America/Los_Angeles",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "EST",
                        city: "New York",
                        latitude: 40.7128,
                        longitude: -74.0060,
                        timeZoneID: "America/New_York",
                        now: now
                    )

                    TimeZoneCard(
                        abbreviation: "JST",
                        city: "Tokyo",
                        latitude: 35.6762,
                        longitude: 139.6503,
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
    let latitude: Double
    let longitude: Double
    let timeZoneID: String
    let now: Date

    @StateObject private var weather = WeatherManager()

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
        .task {
            await weather.load(
                latitude: latitude,
                longitude: longitude
            )
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
