#if DEBUG
import Foundation

/// `-topProbe`: Today's top-story pick, run on a fixed day of headlines (the
/// 27 October front page that put two event listings on top), printed three
/// times since the on-device model isn't deterministic.
enum TopStoriesProbe {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-topProbe") }

    /// index.hr publishes far more than the others, so its stories are the newest.
    private static let day: [(String, String)] = [
        ("index.hr", "Vučić srušen na izborima, studenti pobijedili. Stižu reakcije, Rusi nisu sretni"),
        ("index.hr", "Horoskop za utorak: Ovnovi, danas oprezno s novcem"),
        ("index.hr", "Kviz: Koliko dobro poznajete hrvatske otoke?"),
        ("index.hr", "Studenti proglasili pobjedu. Vučić priznao poraz"),
        ("index.hr", "Pogledajte kako je izgledala noć izbora u Beogradu"),
        ("index.hr", "Plenković o izborima u Srbiji: Hrvatska će pomoći tranziciji"),
        ("index.hr", "Influencerica pokazala novi dom, fanovi oduševljeni"),
        ("index.hr", "Vlada najavila nove mjere za cijene energenata"),
        ("index.hr", "Potres jačine 4,1 zatresao Zagreb, nema većih šteta"),
        ("index.hr", "Dinamo slavio u Varaždinu, Hajduk remizirao"),
        ("index.hr", "Benzin od utorka jeftiniji za četiri centa"),
        ("index.hr", "Ovo su najljepše haljine s crvenog tepiha"),
        ("index.hr", "Trener Osijeka: Htio sam zaplakati nakon utakmice"),
        ("index.hr", "Policija uhitila osumnjičenog za pljačku banke u Splitu"),
        ("index.hr", "EU odobrila Hrvatskoj 400 milijuna eura za obnovu"),
        ("index.hr", "Zabavni video: pas naučio otvarati hladnjak"),
        ("theverge.com", "iFixit&#8217;s look inside the iPhone Duo may explain those broken screens and hinges"),
        ("theverge.com", "Scott Walker’s The Drift will get under your skin"),
        ("theverge.com", "The best deals on headphones this week"),
        ("theverge.com", "EU fines Apple over App Store rules"),
        ("sib.net.hr", "Konkatedrala sv. Petra i Pavla: Holywin – Noć svetih"),
        ("sib.net.hr", "Club Oxygene: Zombie Halloween"),
        ("sib.net.hr", "Kino Urania: filmski program za vikend"),
        ("sib.net.hr", "Osječka bolnica dobila novi CT uređaj"),
        ("sib.net.hr", "HNK Osijek: Premijera predstave Gospoda Glembajevi u petak"),
        ("sib.net.hr", "Grad Osijek gradi novi most preko Drave"),
    ]

    static func run() async {
        let now = Date.now
        let stories = day.enumerated().map { index, item in
            NewsStory(title: PageHeadlines.decode(item.1),
                      link: URL(string: "https://\(item.0)/\(index)")!, host: item.0,
                      published: now.addingTimeInterval(-Double(index) * 1200), summary: nil)
        }
        for round in 1...3 {
            let started = Date.now
            let top = await TodayNews.top(stories)
            print("TOP \(round) \(Int(Date.now.timeIntervalSince(started) * 1000))ms: " + top.map { "\($0.title) (\($0.host))" }.joined(separator: " | "))
        }
    }
}
#endif
