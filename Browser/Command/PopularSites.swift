import Foundation

/// Well-known sites to suggest while typing an address, before you have any
/// history: the world's most visited, and Croatia's. Picked by hand rather than
/// taken from a ranking list, since those are full of ad and CDN domains.
/// A few hundred prefix checks per keystroke: microseconds.
enum PopularSites {
    struct Site {
        let host: String
        let name: String
    }

    /// Sites whose address or name starts with what was typed, most popular
    /// first, Croatian ones ahead when the phone is set to Croatia.
    static func matching(_ needle: String, limit: Int = 3) -> [Site] {
        var found: [Site] = []
        for site in ordered where site.matches(needle) {
            found.append(site)
            if found.count == limit { break }
        }
        return found
    }

    /// Every host, for matching a spoken name that's close but not exact.
    static var allHosts: [String] { ordered.map(\.host) }

    private static let ordered: [Site] = Locale.current.region?.identifier == "HR" ? croatia + world : world + croatia

    private static func sites(_ list: [(String, String)]) -> [Site] {
        list.map { Site(host: $0.0, name: $0.1) }
    }

    private static let world = sites([
        ("google.com", "Google"), ("youtube.com", "YouTube"), ("facebook.com", "Facebook"),
        ("instagram.com", "Instagram"), ("wikipedia.org", "Wikipedia"), ("chatgpt.com", "ChatGPT"),
        ("reddit.com", "Reddit"), ("x.com", "X"), ("whatsapp.com", "WhatsApp"), ("web.whatsapp.com", "WhatsApp Web"),
        ("amazon.com", "Amazon"), ("yahoo.com", "Yahoo"), ("tiktok.com", "TikTok"), ("linkedin.com", "LinkedIn"),
        ("netflix.com", "Netflix"), ("bing.com", "Bing"), ("outlook.live.com", "Outlook"), ("microsoft.com", "Microsoft"),
        ("office.com", "Microsoft 365"), ("mail.google.com", "Gmail"), ("drive.google.com", "Google Drive"),
        ("docs.google.com", "Google Docs"), ("maps.google.com", "Google Maps"), ("translate.google.com", "Google Translate"),
        ("news.google.com", "Google News"), ("gemini.google.com", "Gemini"), ("claude.ai", "Claude"),
        ("perplexity.ai", "Perplexity"), ("openai.com", "OpenAI"), ("anthropic.com", "Anthropic"),
        ("duckduckgo.com", "DuckDuckGo"), ("pinterest.com", "Pinterest"), ("twitch.tv", "Twitch"),
        ("threads.com", "Threads"), ("telegram.org", "Telegram"), ("web.telegram.org", "Telegram Web"),
        ("discord.com", "Discord"), ("spotify.com", "Spotify"), ("open.spotify.com", "Spotify Web Player"),
        ("apple.com", "Apple"), ("icloud.com", "iCloud"), ("github.com", "GitHub"), ("stackoverflow.com", "Stack Overflow"),
        ("ebay.com", "eBay"), ("aliexpress.com", "AliExpress"), ("temu.com", "Temu"), ("shein.com", "Shein"),
        ("etsy.com", "Etsy"), ("walmart.com", "Walmart"), ("ikea.com", "IKEA"), ("zara.com", "Zara"), ("nike.com", "Nike"),
        ("paypal.com", "PayPal"), ("booking.com", "Booking.com"), ("airbnb.com", "Airbnb"), ("tripadvisor.com", "Tripadvisor"),
        ("skyscanner.net", "Skyscanner"), ("ryanair.com", "Ryanair"), ("uber.com", "Uber"), ("canva.com", "Canva"),
        ("figma.com", "Figma"), ("notion.so", "Notion"), ("dropbox.com", "Dropbox"), ("zoom.us", "Zoom"),
        ("deepl.com", "DeepL"), ("imdb.com", "IMDb"), ("disneyplus.com", "Disney+"), ("max.com", "Max"),
        ("primevideo.com", "Prime Video"), ("fandom.com", "Fandom"), ("quora.com", "Quora"), ("medium.com", "Medium"),
        ("bbc.com", "BBC"), ("cnn.com", "CNN"), ("nytimes.com", "The New York Times"), ("theguardian.com", "The Guardian"),
        ("reuters.com", "Reuters"), ("bloomberg.com", "Bloomberg"), ("forbes.com", "Forbes"), ("theverge.com", "The Verge"),
        ("wired.com", "Wired"), ("techcrunch.com", "TechCrunch"), ("espn.com", "ESPN"), ("weather.com", "The Weather Channel"),
        ("accuweather.com", "AccuWeather"), ("store.steampowered.com", "Steam"), ("epicgames.com", "Epic Games"),
        ("roblox.com", "Roblox"), ("samsung.com", "Samsung"), ("adobe.com", "Adobe"), ("wordpress.com", "WordPress"),
        ("shopify.com", "Shopify"), ("tumblr.com", "Tumblr"), ("flixbus.com", "FlixBus"), ("hm.com", "H&M"),
    ])

    private static let croatia = sites([
        ("index.hr", "Index.hr"), ("jutarnji.hr", "Jutarnji list"), ("24sata.hr", "24sata"), ("vecernji.hr", "Večernji list"),
        ("net.hr", "Net.hr"), ("dnevnik.hr", "Dnevnik.hr"), ("tportal.hr", "tportal"), ("rtl.hr", "RTL"),
        ("hrt.hr", "HRT"), ("n1info.hr", "N1"), ("telegram.hr", "Telegram.hr"), ("slobodnadalmacija.hr", "Slobodna Dalmacija"),
        ("novilist.hr", "Novi list"), ("glas-slavonije.hr", "Glas Slavonije"), ("sib.hr", "SiB"), ("direktno.hr", "Direktno"),
        ("nacional.hr", "Nacional"), ("poslovni.hr", "Poslovni dnevnik"), ("lidermedia.hr", "Lider"), ("bug.hr", "Bug"),
        ("gol.dnevnik.hr", "Gol.hr"), ("sportske.jutarnji.hr", "Sportske novosti"), ("germanijak.hr", "Germanijak"),
        ("njuskalo.hr", "Njuškalo"), ("oglasnik.hr", "Oglasnik"), ("index.hr/oglasi", "Index Oglasi"),
        ("gov.hr", "gov.hr"), ("porezna-uprava.gov.hr", "Porezna uprava"), ("hzzo.hr", "HZZO"), ("fina.hr", "FINA"),
        ("hak.hr", "HAK"), ("posta.hr", "Hrvatska pošta"), ("hep.hr", "HEP"), ("skole.hr", "CARNET Škole"),
        ("ocjene.skole.hr", "e-Dnevnik"), ("hzpp.hr", "HŽPP"), ("jadrolinija.hr", "Jadrolinija"),
        ("croatiaairlines.com", "Croatia Airlines"), ("akz.hr", "Autobusni kolodvor Zagreb"),
        ("zaba.hr", "Zagrebačka banka"), ("pbz.hr", "PBZ"), ("erstebank.hr", "Erste"), ("otpbanka.hr", "OTP banka"),
        ("rba.hr", "Raiffeisen"), ("addiko.hr", "Addiko"), ("hrvatskitelekom.hr", "Hrvatski Telekom"), ("a1.hr", "A1"),
        ("telemach.hr", "Telemach"), ("links.hr", "Links"), ("instar-informatika.hr", "Instar"), ("hgspot.hr", "HGSpot"),
        ("ekupi.hr", "eKupi"), ("emmezeta.hr", "Emmezeta"), ("pevex.hr", "Pevex"), ("bauhaus.hr", "Bauhaus"),
        ("konzum.hr", "Konzum"), ("lidl.hr", "Lidl"), ("kaufland.hr", "Kaufland"), ("spar.hr", "Spar"),
        ("decathlon.hr", "Decathlon"), ("sancta-domenica.hr", "Sancta Domenica"), ("play.rtl.hr", "RTL Play"),
        ("hrti.hrt.hr", "HRTi"), ("lutrija.hr", "Hrvatska Lutrija"), ("supersport.hr", "SuperSport"), ("psk.hr", "PSK"),
        ("dhmz.htnet.hr", "DHMZ vrijeme"), ("hina.hr", "HINA"),
    ])
}

private extension PopularSites.Site {
    func matches(_ needle: String) -> Bool {
        if host.hasPrefix(needle) { return true }
        // "www.index" or a name: "vecernji", "njuskalo", "google maps".
        if needle.hasPrefix("www."), host.hasPrefix(needle.dropFirst(4)) { return true }
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.hasPrefix(needle)
    }
}
