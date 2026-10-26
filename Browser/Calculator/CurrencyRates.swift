import Foundation

/// Exchange rates for about 300 currencies and the main cryptocurrencies, from
/// the free fawazahmed0 currency API (daily, no key), with the ECB's rates as a
/// fallback. Cached for 12 hours. Lookups are synchronous against the cache; a
/// stale or missing cache triggers one background refresh, never a wait while typing.
@Observable
final class CurrencyRates {
    static let shared = CurrencyRates()

    /// Codes recognised while typing, before the first download has arrived.
    static let codes: [String] = [
        "EUR", "USD", "GBP", "JPY", "CHF", "AUD", "CAD", "CNY", "HKD", "NZD", "SEK", "NOK", "DKK",
        "PLN", "CZK", "HUF", "RON", "BGN", "ISK", "TRY", "INR", "IDR", "ILS", "KRW", "MXN", "MYR",
        "PHP", "SGD", "THB", "ZAR", "BRL",
        "RSD", "BAM", "MKD", "ALL", "UAH", "RUB", "BYN", "MDL", "GEL", "AMD", "AZN", "KZT",
        "AED", "SAR", "QAR", "KWD", "BHD", "OMR", "JOD", "EGP", "MAD", "TND", "NGN", "KES", "GHS",
        "ARS", "CLP", "COP", "PEN", "UYU", "VND", "PKR", "BDT", "LKR", "NPR", "TWD",
        "BTC", "ETH",
    ]

    /// Currencies replaced by the euro, at their irrevocably fixed rates per euro.
    static let fixed: [String: Double] = [
        "HRK": 7.5345, "DEM": 1.95583, "FRF": 6.55957, "ITL": 1936.27, "ATS": 13.7603,
        "SIT": 239.64, "ESP": 166.386, "NLG": 2.20371, "BEF": 40.3399, "PTE": 200.482,
        "GRD": 340.75, "IEP": 0.787564, "FIM": 5.94573, "SKK": 30.126, "LTL": 3.4528,
        "LVL": 0.702804, "EEK": 15.6466, "CYP": 0.585274, "MTL": 0.4293,
    ]

    /// Rates against the euro, keyed by upper-case code.
    private(set) var rates: [String: Double] = [:]
    private(set) var date = ""
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var refreshing = false

    private init() {
        let defaults = UserDefaults.standard
        rates = defaults.dictionary(forKey: "fx2.rates") as? [String: Double] ?? [:]
        date = defaults.string(forKey: "fx2.date") ?? ""
        fetchedAt = defaults.object(forKey: "fx2.fetchedAt") as? Date
    }

    /// "22 Oct" from the source's "2026-10-22".
    var dateLabel: String {
        guard let day = try? Date(date, strategy: .iso8601.year().month().day()) else { return date }
        return day.formatted(.dateTime.day().month(.abbreviated))
    }

    func knows(_ code: String) -> Bool {
        code == "EUR" || Self.fixed[code] != nil || rates[code] != nil || Self.codes.contains(code)
    }

    func isFixed(_ code: String) -> Bool { Self.fixed[code] != nil }

    func convert(_ amount: Double, from: String, to: String) -> Double? {
        // Between the euro and its fixed-rate predecessors no download is needed.
        let euroOnly = [from, to].allSatisfy { $0 == "EUR" || isFixed($0) }
        if !euroOnly { refreshIfStale() }
        guard let fromRate = rate(from), let toRate = rate(to) else { return nil }
        return amount / fromRate * toRate
    }

    private func rate(_ code: String) -> Double? {
        code == "EUR" ? 1 : Self.fixed[code] ?? rates[code]
    }

    private func refreshIfStale() {
        if let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < 12 * 3600 { return }
        guard !refreshing else { return }
        refreshing = true
        Task {
            await refresh()
            refreshing = false
        }
    }

    /// Downloads fresh rates, trying each source in turn.
    func refresh() async {
        let sources = [
            "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/eur.min.json",
            "https://latest.currency-api.pages.dev/v1/currencies/eur.min.json",
            "https://api.frankfurter.dev/v1/latest?base=EUR",
        ]
        for source in sources {
            guard let url = URL(string: source),
                  let (data, response) = try? await URLSession.quick.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let table = (json["eur"] ?? json["rates"]) as? [String: Any] else { continue }
            var fresh: [String: Double] = [:]
            for (code, value) in table {
                if let number = value as? NSNumber, number.doubleValue > 0 { fresh[code.uppercased()] = number.doubleValue }
            }
            guard fresh.count > 20 else { continue }
            rates = fresh
            date = json["date"] as? String ?? ""
            fetchedAt = .now
            let defaults = UserDefaults.standard
            defaults.set(fresh, forKey: "fx2.rates")
            defaults.set(date, forKey: "fx2.date")
            defaults.set(fetchedAt, forKey: "fx2.fetchedAt")
            return
        }
    }
}
