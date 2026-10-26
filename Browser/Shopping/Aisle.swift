import Foundation

/// Where a shopping item is found, in the order a shop is walked: fresh food
/// first, then the shelves, then the house. Croatian or English, singular or
/// not, with a brand or without: "mlijeko", "2 mlijeka", "milk", "Dukat
/// mlijeko 2,8%" are all Dairy.
nonisolated enum Aisle: String, CaseIterable, Codable, Identifiable, Sendable {
    case produce, bakery, meat, dairy, frozen, pantry, breakfast, sweets, drinks, household, personal, baby, pets, medicine, other

    var id: String { rawValue }

    /// In the shopping list's language (Settings).
    var title: String { title(in: ListLanguage.current) }

    func title(in language: ListLanguage.Resolved) -> String {
        switch (self, language) {
        case (.produce, .english): "Fruit and vegetables"
        case (.produce, .croatian): "Voće i povrće"
        case (.bakery, .english): "Bread and bakery"
        case (.bakery, .croatian): "Kruh i pekara"
        case (.meat, .english): "Meat and fish"
        case (.meat, .croatian): "Meso i riba"
        case (.dairy, .english): "Dairy and eggs"
        case (.dairy, .croatian): "Mliječni proizvodi i jaja"
        case (.frozen, .english): "Frozen"
        case (.frozen, .croatian): "Smrznuto"
        case (.pantry, .english): "Pantry"
        case (.pantry, .croatian): "Namirnice"
        case (.breakfast, .english): "Coffee, tea and breakfast"
        case (.breakfast, .croatian): "Kava, čaj i doručak"
        case (.sweets, .english): "Sweets and snacks"
        case (.sweets, .croatian): "Slatkiši i grickalice"
        case (.drinks, .english): "Drinks"
        case (.drinks, .croatian): "Pića"
        case (.household, .english): "Household"
        case (.household, .croatian): "Kućanstvo"
        case (.personal, .english): "Personal care"
        case (.personal, .croatian): "Osobna njega"
        case (.baby, .english): "Baby"
        case (.baby, .croatian): "Za bebe"
        case (.pets, .english): "Pets"
        case (.pets, .croatian): "Kućni ljubimci"
        case (.medicine, .english): "Medicines and health"
        case (.medicine, .croatian): "Lijekovi i zdravlje"
        case (.other, .english): "Other"
        case (.other, .croatian): "Ostalo"
        }
    }

    // MARK: Telling

    /// The aisle an item belongs in, from its words; `.other` when none say.
    static func of(_ item: String) -> Aisle {
        best(in: item)?.aisle ?? .other
    }

    /// How an item is known, whatever way it was written: lower case, no
    /// accents, no amounts or sizes. "2x Mlijeko 1L" and "mlijeko" are one.
    static func key(_ item: String) -> String {
        words(item).joined(separator: " ")
    }

    static func words(_ item: String) -> [String] {
        let folded = item.lowercased()
            .replacingOccurrences(of: "đ", with: "d")
            .folding(options: [.diacriticInsensitive], locale: nil)
        return folded
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            // Amounts and sizes: "2", "500g", "1l", "x2", "kom".
            .filter { word in
                !word.allSatisfy(\.isNumber) && !Self.units.contains(word)
                    && !(word.first?.isNumber == true && Self.units.contains(String(word.drop(while: \.isNumber))))
            }
    }

    private static let units: Set<String> = ["g", "gr", "kg", "dag", "dkg", "ml", "dl", "cl", "l", "lt", "kom", "x", "pak",
                                             "pck", "pcs", "oz", "lb", "lbs", "kos"]

    /// The strongest word the item has, and what it says.
    private static func best(in item: String) -> (aisle: Aisle, weight: Int)? {
        let words = words(item)
        guard !words.isEmpty else { return nil }
        let text = " " + words.joined(separator: " ") + " "
        var found: (aisle: Aisle, weight: Int, length: Int)?
        func consider(_ aisle: Aisle, _ weight: Int, _ length: Int) {
            if found.map({ (weight, length) > ($0.weight, $0.length) }) ?? true { found = (aisle, weight, length) }
        }
        for entry in phrases where text.contains(" " + entry.text + " ") || text.contains(" " + entry.text) && entry.prefix {
            consider(entry.aisle, entry.weight + 1, entry.text.count)
        }
        for word in words {
            if let entry = whole[word] { consider(entry.aisle, entry.weight, word.count) }
            // The longest stem the word starts with.
            for length in stride(from: min(word.count, 12), through: 3, by: -1) {
                if let entry = stems[String(word.prefix(length))] {
                    consider(entry.aisle, entry.weight, length)
                    break
                }
            }
        }
        return found.map { ($0.aisle, $0.weight) }
    }

    // MARK: Words

    private struct Entry {
        let text: String
        let aisle: Aisle
        /// 1: a flavour or an ingredient ("jagoda" in a yogurt); 2: what the
        /// thing is ("jogurt"); 3: settles it whatever else is said ("smrznuto").
        let weight: Int
        let prefix: Bool
    }

    /// Whole words ("sir"), stems ("mlijek*" for mlijeko, mlijeka, mlijekom),
    /// a weight mark ("~" a flavour, "!" decisive), phrases with spaces.
    private static let table: [Aisle: String] = [
        .produce: """
            voce* povrc* jabuk* kruska* krusk* banan* naranc* mandarin* limun* limet* grejp* grozd* jagod*~ malin*~ \
            borovnic*~ kupin*~ tresnj*~ visnj*~ marelic*~ breskv* nektarin* sljiv*~ smokv* dinj* lubenic* ananas*~ kivi* mango*~ \
            avokad* nar sipak* rajcic* rajc* paradajz* krastav* paprik*~ tikvic* patlidzan* luk luka* luku* crveni\\ luk mladi\\ luk \
            cesnjak* cesnj* mrkv* krumpir* krompir* batat* slatki\\ krumpir cikl* celer* persin* persun* blitv* spinat* kelj* \
            kupus* kupusa* brokul* karfiol* cvjetac* salat* rukol* rucol* matovilac* radic* endivij* poriluk* porilu* \
            sampinjon* gljiv* vrganj* bukovac* sparog* kukuruz\\ klip mahun* grasak\\ svjezi rotkvic* hren* djumbir* dumbir* \
            bosiljak*~ kopar*~ mint*~ metvic*~ vlasac*~ kokos*~ datul*~ povrce\\ za\\ juhu! \
            fruit* vegetable* veg apple* pear* banana* orange* mandarine* clementine* lemon* lime* grapefruit* grape* \
            strawberr*~ raspberr*~ blueberr*~ blackberr*~ cherr*~ peach* nectarine* plum*~ fig* melon* watermelon* pineapple*~ \
            avocado* tomato* tomatoes cucumber* pepper*~ zucchini* courgette* aubergine* eggplant* onion* garlic* carrot* \
            potato* potatoes beet* celery parsley* chard spinach kale cabbage* broccoli cauliflower lettuce rocket arugula \
            leek* mushroom* asparagus radish* ginger* herbs basil*~ dill*~ coriander*~ cilantro*~ scallion* shallot* \
            berries*~ sweet\\ potato spring\\ onion
            """,
        .bakery: """
            kore kora\\ za\\ pitu kruh* kruha* kruhom pecivo* peciva kifl* kiflic* baget* bageta* zemlick* lepinj* pogac* burek* \
            krafn* kroasan* croissant* tost tosta tostni\\ kruh pita pite pitu strudl* savijac* pereci* perec* \
            krusne\\ mrvice* mrvice tortilj* tortil* wrap* lavas* somun* ciabatt* focacc* \
            bread* loaf* roll rolls bun buns bagel* baguette* toast pastr* muffin* doughnut* donut* pretzel* pita\\ bread \
            sourdough* rye\\ bread breadcrumbs
            """,
        .meat: """
            meso* mesa* mesom piletin* pilec* pilic* pile* pilet* puretin* pure* puric* junetin* juneci* teletin* svinjetin* \
            svinjsk* juneci janjetin* janje* govedin* govedi* mljeveno* mljevenog* odrezak* odresk* kotlet* file* filet* \
            prsa* batak* bataci* krilca* krila* zabatak* rebarc* vrat* but* rolad* cevap* cevapc* pljeskavic* kobasic* \
            hrenovk* safalad* virsl* slanin* panceta* pancet* sunk* salam* kulen* cajn* mortadel* pecenic* pasteta* \
            pastete* argeta* cvarc* riba* ribe* ribu* losos* tun* tuna*~ oslic* bakalar* srdel* skus* orad* brancin* \
            pastrv* lignj* hobotnic* skamp* kozic* dagnj* kamenic* pecenic* cevap* prsut* \
            meat* chicken* turkey* beef* veal* pork* lamb* mince* minced steak* chop* chops fillet* breast* thigh* \
            drumstick* wing* wings ribs sausage* hot\\ dog* bacon* ham hams salami* prosciutto* pate* pâté fish salmon* \
            tuna\\ steak cod* hake* sardine* mackerel* trout* squid* octopus* shrimp* prawn* mussel* oyster*
            """,
        .dairy: """
            mlijek* mlijecn* jogurt* kefir* acidofil* vrhnj* slatko\\ vrhnje kiselo\\ vrhnje sir sira siru sirom sirevi \
            sireva sirni sirn* skut* zrnat* svjezi\\ sir maslac* margarin* puter* jaj* jaje mozzarel* mozarel* gouda* edamer* \
            ementaler* parmezan* grana* ricott* mascarpon* feta* cheddar* trapist* cottage* namaz*~ puding* \
            mozzar* skyr* slag* sirni\\ namaz tofu* halloumi* burrata* \
            pudding* dukatel* dukatos* actimel* danone* activia* z\\ bregov* zbregov* dukat* vindij* meggle* \
            milk* yogurt* yoghurt* kefir cream sour\\ cream whipping\\ cream cheese* butter* margarine eggs egg \
            parmesan* cottage\\ cheese cream\\ cheese custard*
            """,
        .frozen: """
            smrznut*! zamrznut*! sladoled*! ledo!  pommes*! pomfrit*! krumpirici*! kroket*! pizz* \
            frozen*! ice\\ cream! fries! fish\\ fingers! fish\\ sticks! riblji\\ stapic*!
            """,
        .pantry: """
            brasn* secer* sol soli solju papar* papra* zacin* vegeta* origano* cimet* paprika\\ mljevena kurkum* curry* kari* \
            ulj* ulja* maslinov* ocat* octa* tjesten* spaget* spaghetti* penne* fusill* makaron* njok* lazanj* lasagn* \
            tortelin* tortellin* ravioli* mlinc* rezanc* riza* rize* rizu* rizoto* kus\\ kus* kuskus* bulgur* kvinoj* quinoa* \
            palent* griz* zob*~ grah* leca* slanutak* soja* konzerv* tunjevin*! kukuruz\\ konzerva umak* umaka* pelat* \
            koncentrat* pasirana\\ rajcica kecap* ketchup* majonez* senf* gorusic* hren\\ umak kvas* kvasac* prasak* \
            vanilin* puding\\ prasak cokoladni\\ prah kakao* sezam* lan* lana* chia* suncokret*~ orasi* orah* lesnjak* \
            badem* kikiriki*~ grozdice* brusnic*~ juha* juhe* temeljac* bujon* kocka\\ za\\ juhu kokosovo\\ mlijeko! \
            grasak* grah* kukuruz* tortel* orasc* orasast* ljesnja* sjemenk* zelatin* dekstroz* skrob* gustin* mljevena\\ paprika! \
            kiseli\\ krastav*! kisele\\ paprike! ajvar* pelat* masline* maslin*~ humus* hummus* pesto* \
            flour* sugar* salt pepper\\ ground spice* oregano cinnamon* oil olive\\ oil vinegar* pasta* noodle* rice \
            couscous* oats*~ beans* lentil* chickpea* canned* tin tinned sauce* passata* ketchup mayo* mayonnaise* \
            mustard* yeast* baking\\ powder baking\\ soda vanilla*~ cocoa* sesame* seeds* nuts walnut* almond* hazelnut* \
            peanut*~ raisin* soup* stock* broth* coconut\\ milk!
            """,
        .breakfast: """
            kav* kava kave kavu espresso* nescafe* franck* barcaff* cappuccino* caj* caja caju cajevi kakao\\ napitak \
            pahuljic* muesli* musli* zitarice* cornflakes* corn\\ flakes granol* med meda medom dzem* pekmez* marmelad* \
            nutell* lino\\ lada linolad* kasa kase kasu kamilic* \
            coffee* tea teas teabag* cereal* granola* honey jam* marmalade* porridge* oatmeal*
            """,
        .sweets: """
            cokolad*~ cok*~ bombon* keks* biskvit* napolitank* vafl* kolac* kolaci* tort*~ cips* chips*~ grickalic* \
            stapic* slani\\ stapici kokic* krekeri* kreker* smoki* bajadera* milka* kinder* snick* twix* \
            doritos* chio* pringles* lays* ferrero* raffaello* toblerone* haribo* \
            bueno* dorina* kras* domacica* jaffa* petit* kroki* lizalic* zvak* zvakac* gumen* \
            chocolate*~ candy* candies sweets biscuit* cookie* cracker* crisps* snack* popcorn* pretzels* gum gummy* \
            wafer* cake*~ brownie* sweet*~
            """,
        .drinks: """
            voda* vode* vodu mineral* gazirana* negazirana* jamnic* jana* studen* sok* sokovi* soka* nektar* cedevit* \
            coca* cola* pepsi* fanta* sprite* schweppes* ledeni\\ caj ice\\ tea pivo* piva* pive ozujsko* karlovack* \
            heineken* vino* vina* vinom prosek* pjenusac* rakij* liker* gin* vodk* whisk* rum* energetsk* red\\ bull* \
            bambi*~ smoothie* napitak* kombuch* tequil* cockt* radensk* mivel* sirup* alk gaz gazirano \
            water* juice* soda* lemonade* beer* wine* cider* spirits* vodka* whiskey* whisky* champagne* prosecco* \
            energy\\ drink* tonic* drink*
            """,
        .household: """
            posud*! posude! odstranjiv*! mrlj*! kamenc*! osvjez*! glade*! airwick*! ambi\\ pur! vanish*! cillit*! \
            somat*! finish*! calgon*! silan*! za\\ obucu! laminat*! dezinf*! \
            jar! det! deterdz*! sude! za\\ sude! za\\ staklo! wc! sanitar*! kapsule\\ za! papir* deterdzent*! omeksiv*! prasak\\ za\\ rublje prasak\\ za\\ pranje ariel* persil* faks* lenor* sredstv* cistac* \
            cisto* domestos*! ajax*! cif*! fairy*! frosch*! bref*! tablete\\ za\\ perilicu! sjajilo*! sol\\ za\\ perilicu! spuzv* krp* \
            vrec* vreca* folij* papirnat* ubrus* salvet* toaletn* wc\\ papir zewa* violeta* alu\\ folija pecni\\ papir \
            papir\\ za\\ pecenje baterij* zarulj* sibic* svijec* osvjezivac* izbjeljivac* varikin* \
            detergent* washing\\ up! washing\\ powder fabric\\ softener softener* cleaner* cleaning* bleach* dish\\ soap dishwasher* \
            sponge* cloth* bin\\ bags trash\\ bags rubbish\\ bags bags foil* cling\\ film baking\\ paper paper\\ towel* \
            toilet\\ paper toilet\\ roll* napkin* tissues battery* batteries bulb* matches candle* air\\ freshener
            """,
        .personal: """
            sampon*! regenerator*! balzam\\ za\\ kosu! gel\\ za\\ tusiranje! gel\\ za\\ tus! kupka*! sapun*! dezodor*! deozodor*! \
            deo! zubn*! pasta\\ za\\ zube! cetkic* konac\\ za\\ zube! vodica\\ za\\ usta! brijac*! britvic*! brijanj*! \
            pjena\\ za\\ brijanje! krem*~ krema\\ za! kreme\\ za! losion*! uloz*! tampon*! higijensk*! vat* stapici\\ za\\ usi! maramic* \
            nivea*! dove*! colgate*! elmex*! signal*! gillette*! always*! syoss*! garnier*! tosama*! gliss*! taft*! \
            wilkinson*! durex*! old\\ spice! lak\\ za\\ kosu! lak\\ za\\ nokte! boja\\ za\\ kosu! gel\\ za\\ kosu! maska\\ za\\ kosu! \
            ulje\\ za\\ kosu! ulje\\ za\\ tijelo! mlijeko\\ za\\ tijelo! mlijeko\\ za\\ suncanje! za\\ suncanje! \
            toaletna\\ voda! parfem*! ruz*! maskar*! prezervativ*! kondom*! lubrikant*! head\\ shoulders! pantene*! \
            axe! balzam\\ za\\ usne! puder*! \
            shampoo*! conditioner*! shower\\ gel! body\\ wash! soap*! deodorant*! toothpaste*! toothbrush*! floss*! \
            mouthwash*! razor*! shaving*! lotion*! moisturi*! sunscreen*! pads tampon*! cotton* plaster* wipes body\\ lotion!
            """,
        .medicine: """
            lijek*! lijekovi! sirup\\ za\\ kasalj! sirup\\ protiv! kapi\\ za! sprej\\ za\\ nos! vitamin*! multivitamin*! \
            dodatak\\ prehrani! magnezij*! probiotik*! cink! omega\\ 3! aspirin*! brufen*! lupocet*! paracetamol*! ibuprofen*! \
            nurofen*! voltaren*! neofen*! plivadon*! caffetin*! andol*! strepsils*! septolete*! fervex*! coldrex*! \
            flaster*! hansaplast*! zavoj*! toplomjer*! test\\ za\\ trudnocu! dezinfekcij*! antibiotik*! tablete\\ za\\ glavobolju! \
            tablete\\ protiv! kreme\\ za\\ rane! mast\\ za! \
            medicine*! medication*! painkiller*! cough\\ syrup! nasal\\ spray! vitamins! supplement*! plasters! bandage*! \
            thermometer*! antiseptic*! pregnancy\\ test! eye\\ drops! throat\\ lozenges! allergy\\ tablets!
            """,
        .baby: """
            pelen*! pampers*! dojencad* djecja\\ hrana bebi* beb* adapt* vlazne\\ maramice \
            diaper* nappies nappy baby* formula* baby\\ food baby\\ wipes
            """,
        .pets: """
            za\\ pse! za\\ psa! za\\ mace! za\\ macke! za\\ macku! macka! macke! pse! psa! pseca*! macj*! posip*! \
            pijesak\\ za\\ mace! whiskas*! pedigree*! felix*! friskies*! gourmet*! dentastix*! vitakraft*! za\\ ribe! \
            za\\ hrcke! za\\ kunice! za\\ ptice! \
            dog\\ food! cat\\ food! cat\\ litter! pet\\ food! kibble! dog\\ treats! for\\ dogs! for\\ cats!
            """,
    ]

    private static let parsed: [Entry] = table.flatMap { aisle, list in
        // "\ " joins a phrase's words; everything else is separated by spaces.
        list.replacingOccurrences(of: "\\ ", with: "\u{1}")
            .split(whereSeparator: \.isWhitespace)
            .map { raw -> Entry in
                var text = raw.replacingOccurrences(of: "\u{1}", with: " ")
                var weight = 2
                if text.hasSuffix("!") { weight = 3; text.removeLast() }
                if text.hasSuffix("~") { weight = 1; text.removeLast() }
                let prefix = text.hasSuffix("*")
                if prefix { text.removeLast() }
                if aisle == .produce, weight == 2 { weight = 1 }
                return Entry(text: text, aisle: aisle, weight: weight, prefix: prefix)
            }
    }
    private static let phrases = parsed.filter { $0.text.contains(" ") }
    private static let whole: [String: Entry] = Dictionary(parsed.filter { !$0.text.contains(" ") && !$0.prefix }.map { ($0.text, $0) },
                                                           uniquingKeysWith: { a, b in a.weight >= b.weight ? a : b })
    private static let stems: [String: Entry] = Dictionary(parsed.filter { !$0.text.contains(" ") && $0.prefix }.map { ($0.text, $0) },
                                                           uniquingKeysWith: { a, b in a.weight >= b.weight ? a : b })
}

/// The language the shopping list speaks (Settings → Today and to-dos):
/// its aisles and its own words. Automatic follows the iPhone's language.
nonisolated enum ListLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic, english, croatian

    static let key = "shopping.language"

    enum Resolved { case english, croatian }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .english: "English"
        case .croatian: "Hrvatski"
        }
    }

    static var chosen: ListLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(ListLanguage.init) ?? .automatic
    }

    static var current: Resolved {
        switch chosen {
        case .english: .english
        case .croatian: .croatian
        case .automatic: Locale.preferredLanguages.first?.hasPrefix("hr") == true ? .croatian : .english
        }
    }

    /// The words for the list's language: English, then Croatian.
    static func say(_ english: String, _ croatian: String) -> String {
        current == .croatian ? croatian : english
    }
}

/// Which shop a thing is bought in: the supermarket, the drugstore (dm,
/// Bipa) or the pharmacy (ljekarna). Each has its own list.
nonisolated enum Shop: String, CaseIterable, Identifiable, Sendable {
    case grocery, drugstore, pharmacy

    var id: String { rawValue }

    static let key = "shopping.shop"

    var title: String {
        switch self {
        case .grocery: ListLanguage.say("Groceries", "Trgovina")
        case .drugstore: ListLanguage.say("Drugstore", "Drogerija")
        case .pharmacy: ListLanguage.say("Pharmacy", "Ljekarna")
        }
    }

    /// Where a thing in this aisle is usually bought.
    static func of(_ aisle: Aisle) -> Shop {
        switch aisle {
        case .personal, .baby: .drugstore
        case .medicine: .pharmacy
        default: .grocery
        }
    }
}
