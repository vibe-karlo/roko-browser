// Checks Shopping's aisles: what people type, the October receipts, and
// optionally a shop's whole price list.
//   cp Scripts/test_aisles.swift /tmp/main.swift && swiftc -O Browser/Shopping/Aisle.swift /tmp/main.swift -o /tmp/aisles && /tmp/aisles [prices.csv]
import Foundation

func check(_ name: String, _ cases: [(String, Aisle)]) {
    var wrong: [String] = []
    for (item, expected) in cases where Aisle.of(item) != expected {
        wrong.append("\(item) → \(Aisle.of(item).rawValue) (want \(expected.rawValue))")
    }
    print("\(name): \(cases.count - wrong.count)/\(cases.count) right")
    wrong.forEach { print("   ✗ " + $0) }
}

// What people type.
let typed: [(String, Aisle)] = [
    ("mlijeko", .dairy), ("2 mlijeka", .dairy), ("milk", .dairy), ("jaja", .dairy), ("eggs", .dairy), ("sir", .dairy),
    ("cheese", .dairy), ("jogurt", .dairy), ("vrhnje za kuhanje", .dairy), ("kiselo vrhnje", .dairy), ("maslac", .dairy),
    ("butter", .dairy), ("svježi sir", .dairy), ("mozzarella", .dairy), ("parmezan", .dairy), ("kefir", .dairy),
    ("kruh", .bakery), ("bread", .bakery), ("pecivo", .bakery), ("kifle", .bakery), ("tortilje", .bakery), ("burek", .bakery),
    ("croissant", .bakery), ("bagels", .bakery),
    ("banane", .produce), ("bananas", .produce), ("jabuke", .produce), ("apples", .produce), ("rajčice", .produce),
    ("tomatoes", .produce), ("krumpir", .produce), ("potatoes", .produce), ("luk", .produce), ("onions", .produce),
    ("češnjak", .produce), ("garlic", .produce), ("mrkva", .produce), ("tikvice", .produce), ("paprika", .produce),
    ("salata", .produce), ("špinat", .produce), ("limun", .produce), ("lemons", .produce), ("borovnice", .produce),
    ("avokado", .produce), ("gljive", .produce), ("šampinjoni", .produce), ("brokula", .produce), ("krastavci", .produce),
    ("piletina", .meat), ("pileća prsa", .meat), ("chicken breast", .meat), ("mljeveno meso", .meat), ("minced beef", .meat),
    ("šunka", .meat), ("ham", .meat), ("salama", .meat), ("losos", .meat), ("salmon", .meat), ("hrenovke", .meat),
    ("kobasice", .meat), ("sausages", .meat), ("pureći file", .meat), ("bacon", .meat), ("slanina", .meat), ("tuna steak", .meat),
    ("sladoled", .frozen), ("ice cream", .frozen), ("smrznuti grašak", .frozen), ("frozen peas", .frozen), ("pommes", .frozen),
    ("riblji štapići", .frozen), ("fish fingers", .frozen),
    ("brašno", .pantry), ("flour", .pantry), ("šećer", .pantry), ("sugar", .pantry), ("sol", .pantry), ("salt", .pantry),
    ("ulje", .pantry), ("maslinovo ulje", .pantry), ("olive oil", .pantry), ("tjestenina", .pantry), ("špageti", .pantry),
    ("pasta", .pantry), ("riža", .pantry), ("rice", .pantry), ("kvasac", .pantry), ("yeast", .pantry), ("ketchup", .pantry),
    ("majoneza", .pantry), ("senf", .pantry), ("tunjevina", .pantry), ("grah", .pantry), ("kokosovo mlijeko", .pantry),
    ("coconut milk", .pantry), ("vegeta", .pantry), ("papar", .pantry), ("ocat", .pantry), ("passata", .pantry),
    ("kava", .breakfast), ("coffee", .breakfast), ("čaj", .breakfast), ("tea", .breakfast), ("med", .breakfast),
    ("honey", .breakfast), ("pahuljice", .breakfast), ("muesli", .breakfast), ("cereal", .breakfast), ("džem", .breakfast),
    ("nutella", .breakfast),
    ("čokolada", .sweets), ("chocolate", .sweets), ("keksi", .sweets), ("biscuits", .sweets), ("čips", .sweets),
    ("crisps", .sweets), ("kokice", .sweets), ("popcorn", .sweets), ("smoki", .sweets), ("bomboni", .sweets),
    ("voda", .drinks), ("water", .drinks), ("mineralna", .drinks), ("sok od naranče", .drinks), ("orange juice", .drinks),
    ("pivo", .drinks), ("beer", .drinks), ("vino", .drinks), ("wine", .drinks), ("coca cola", .drinks), ("cedevita", .drinks),
    ("ledeni čaj", .drinks), ("ice tea", .drinks), ("jamnica", .drinks),
    ("deterdžent", .household), ("detergent", .household), ("omekšivač", .household), ("toaletni papir", .household),
    ("toilet paper", .household), ("papirnati ručnici", .household), ("paper towels", .household), ("vrećice za smeće", .household),
    ("bin bags", .household), ("spužve", .household), ("tablete za perilicu", .household), ("jar", .household),
    ("aluminijska folija", .household), ("baterije", .household), ("batteries", .household), ("salvete", .household),
    ("šampon", .personal), ("shampoo", .personal), ("pasta za zube", .personal), ("toothpaste", .personal), ("sapun", .personal),
    ("soap", .personal), ("dezodorans", .personal), ("deodorant", .personal), ("četkica za zube", .personal),
    ("gel za tuširanje", .personal), ("uložci", .personal), ("britvice", .personal), ("razors", .personal),
    ("pelene", .baby), ("diapers", .baby), ("vlažne maramice", .baby), ("baby food", .baby),
    ("hrana za pse", .pets), ("dog food", .pets), ("hrana za mačke", .pets), ("cat litter", .pets), ("posip za mačke", .pets),
]
check("Typed", typed)

// The receipts, by hand.
let receipts: [(String, Aisle)] = [
    ("Tena brašno pš. 1 kg", .pantry), ("Brašno tip 00", .pantry), ("Di-go suhi kvasac35g", .pantry),
    ("Z bregov maslac 250g", .dairy), ("Actimel jag. 4x100g", .dairy), ("Dukat vrhnje za kuh", .dairy), ("Žito Jaja 10/1", .dairy),
    ("Zbregov sir 500 g", .dairy), ("K.Sir Ricotta 250g", .dairy), ("Dukatela pov.150 g", .dairy), ("Kolios Jogurt 500 g", .dairy),
    ("KLC.Mozzar.mini 125g", .dairy), ("KGold.Grana pad.200g", .dairy), ("Presid.Gouda 400 g", .dairy), ("Pileći file", .meat),
    ("Pileća prsa bk", .meat), ("Ledo Losos filet", .frozen), ("Kfav.Pommes 500g", .frozen), ("PP Pileća prsa u ov.", .meat),
    ("Craft Klip.šunk.sir", .meat), ("NMNP.Kruh zlat.300g", .bakery), ("Studena 0,25 l", .drinks), ("Coca Cola12x150ml", .drinks),
    ("STR.Rucola 100g", .produce), ("Kresto Sezam 200g", .pantry), ("Kresto Lan 150g", .pantry), ("Šamp.rez. 200g", .produce),
    ("Batat", .produce), ("Mrkva koš 500g", .produce), ("Povrće za juhu", .produce), ("Krumpir rfz", .produce),
    ("Luk crveni", .produce), ("Tikvica", .produce), ("Špinat 500 g", .produce), ("Jabuka Idared", .produce), ("Banane", .produce),
    ("Naranča", .produce), ("Borovnica 125g", .produce), ("Barilla spaghetti", .pantry), ("Barilla fusilli", .pantry),
    ("Bayernland Gouda", .dairy), ("Chio Kokice 3x80g", .sweets), ("Danone Actim 4x100g", .dairy), ("Deon Deterdžent 2,7L", .household),
    ("Doritos Nacho 90g", .sweets), ("Dukat kis.vrhnje200g", .dairy), ("Dukat tek jog 180g", .dairy), ("Elmex zub.pasta 75ml", .personal),
    ("Finish sjajilo 800ml", .household), ("Grance.keksi230g", .sweets), ("Grožđe bijelo", .produce), ("Jabuka Fuji", .produce),
    ("K.papir za peč. 20 m", .household), ("KFav.Muesli 500g", .breakfast), ("Kinder Bueno 172 g", .sweets), ("Kivi", .produce),
    ("Kotanyi papar 36g", .pantry), ("Krastavac", .produce), ("Kruh s krumpirom", .bakery), ("Kruška Williams", .produce),
    ("Legenda kefir 200 g", .dairy), ("Limun", .produce), ("Majoneza tuba 165g", .pantry), ("Malina košarica", .produce),
    ("Milka Čokolada 90g", .sweets), ("Njemački kruh", .bakery), ("Oatly Napitak 1L", .drinks), ("Paprika mix", .produce),
    ("Patlidžan", .produce), ("Pecivo pšen.sir", .bakery), ("Pely Vreće 60L 10/1", .household), ("Petit keksi 480 g", .sweets),
    ("PIK Šunka u ovitku", .meat), ("Podravka grašak 260g", .pantry), ("Podravka kukuruz150g", .pantry), ("Poriluk", .produce),
    ("Pureći odr. od filea", .meat), ("Rajč.cherry 250g", .produce), ("Salata Iceberg", .produce), ("Šparoga", .produce),
    ("Tosama Štapići 300/1", .personal), ("Vegeta Natur 300 g", .pantry), ("Vic krekeri 150 g", .sweets),
    ("Violeta ručnici 2/1", .household), ("Vreća za smeće 35L", .household), ("Zewa D.del.care32/1", .household),
    ("Zv.suncokret ulje 1l", .pantry), ("Zvijezda Ketchup500g", .pantry), ("Češnjak dom 200g", .produce),
    ("Žitoproi.Tortel.450g", .pantry), ("Kfav.Mlinci 500 g", .pantry), ("Barilla Kore500g", .bakery), ("LF Wrap 245g", .bakery),
    ("Zlatna kiflica", .bakery), ("Argeta paš.kokošja", .meat), ("Pik Pur. dim. šunka", .meat), ("Varaždinec sir", .dairy),
    ("Dimek dimljeni sir", .dairy), ("Zbregov mlijeko", .dairy), ("Snick.mulitp 6/1", .sweets), ("Kinder čok. 100 g", .sweets),
]
check("Receipts", receipts)

// The store's whole range, where its own groups say enough: a price list as
// Croatian shops publish them (tab-separated, the group in column 15).
guard CommandLine.arguments.count > 1, let csv = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else { exit(0) }
var byGroup: [String: [Aisle: Int]] = [:]
var samples: [String: [String]] = [:]
for line in csv.split(separator: "\n").dropFirst() {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count > 14 else { continue }
    let name = String(fields[0]), group = String(fields[14])
    let aisle = Aisle.of(name)
    byGroup[group, default: [:]][aisle, default: 0] += 1
    let wrong: Bool = switch group {
    case "KOZMETIKA": aisle != .personal && aisle != .baby
    case "SREDSTVA ZA ČIŠĆENJE", "PROIZVODI ZA KUĆANSTVO": aisle != .household
    case "PIĆE": aisle != .drinks
    case "HRANA": [.household, .personal, .drinks, .other].contains(aisle)
    default: false
    }
    if wrong { samples[group + " → " + aisle.rawValue, default: []].append(name) }
}
for (group, counts) in byGroup.sorted(by: { $0.key < $1.key }) {
    let total = counts.values.reduce(0, +)
    print("\(group) (\(total)): " + counts.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \($0.value * 100 / total)%" }.joined(separator: ", "))
}
for (key, names) in samples.sorted(by: { $0.value.count > $1.value.count }).prefix(14) {
    print("  \(key) \(names.count): " + names.shuffled().prefix(8).joined(separator: " | "))
}
