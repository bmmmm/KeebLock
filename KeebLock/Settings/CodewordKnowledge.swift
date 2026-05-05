import Foundation

struct CodewordKnowledge {
    let word: String
    let summary: String         // ~100 chars: one-line description
    let facts: [String]         // ~10 facts, each ~100 chars
    let wikipediaSlug: String   // English Wikipedia article slug
    let iconSymbol: String      // SF Symbol name

    var wikipediaURL: URL {
        URL(string: "https://en.wikipedia.org/wiki/\(wikipediaSlug)")!
    }
}

enum CodewordKnowledgeBase {
    static func entry(for word: String) -> CodewordKnowledge {
        let key = word.lowercased()
        return Self.entries[key] ?? Self.fallback(for: key)
    }

    private static func fallback(for word: String) -> CodewordKnowledge {
        let slug = word.prefix(1).uppercased() + word.dropFirst()
        return CodewordKnowledge(
            word: word,
            summary: "Geology term — see Wikipedia for full background.",
            facts: [],
            wikipediaSlug: slug,
            iconSymbol: "questionmark.circle"
        )
    }

    // ~12 hand-curated entries with SF Symbol icons. Other codewords fall back
    // to a generic Wikipedia link with a question-mark glyph.
    static let entries: [String: CodewordKnowledge] = [
        "vesuvius": .init(
            word: "vesuvius",
            summary: "Active stratovolcano on the Bay of Naples; buried Pompeii in 79 AD.",
            facts: [
                "The 79 AD eruption preserved Pompeii under several metres of ash.",
                "Last erupted in 1944 — currently dormant but actively monitored.",
                "About 600,000 people live inside its red zone.",
                "Pliny the Younger's account of 79 AD coined the term Plinian eruption.",
                "The 1841 observatory on its slopes was the world's first volcano station.",
                "Stratovolcano with Mount Somma forming an outer caldera rim.",
                "Summit elevation 1,281 m above sea level.",
                "Eruptions are typically explosive and rich in pyroclastic flows.",
                "Part of the Campanian volcanic arc on Italy's western coast.",
                "The neighboring Phlegraean Fields supervolcano is also restless.",
            ],
            wikipediaSlug: "Mount_Vesuvius",
            iconSymbol: "flame.fill"
        ),
        "krakatoa": .init(
            word: "krakatoa",
            summary: "Indonesian island volcano whose 1883 eruption was heard 5,000 km away.",
            facts: [
                "The 1883 eruption killed an estimated 36,000 people, mostly via tsunami.",
                "Sound from the eruption was heard in Australia and Mauritius.",
                "Atmospheric ash caused vivid red sunsets worldwide for over a year.",
                "Global temperatures dropped by about 1.2 °C the following year.",
                "Anak Krakatau (Child of Krakatoa) emerged from the caldera in 1927.",
                "It collapsed during a 2018 eruption, triggering another deadly tsunami.",
                "Sits on the Sunda Strait between Java and Sumatra.",
                "The 1883 blast is estimated at 200 megatons of TNT equivalent.",
                "Pyroclastic flows raced across the sea, killing far from the island.",
                "Edvard Munch's The Scream sky may depict Krakatoa's afterglow.",
            ],
            wikipediaSlug: "Krakatoa",
            iconSymbol: "flame.fill"
        ),
        "kilauea": .init(
            word: "kilauea",
            summary: "Hawaiian shield volcano — one of the most active on Earth.",
            facts: [
                "Has been erupting almost continuously between 1983 and 2018.",
                "Forms part of the Big Island of Hawaii alongside Mauna Loa.",
                "Eruptions are effusive — slow-flowing basaltic lava, rarely explosive.",
                "Sacred to Pele, the Hawaiian goddess of fire and volcanoes.",
                "Halemaʻumaʻu crater hosts a long-lived lava lake.",
                "2018 eruption destroyed over 700 homes in lower Puna.",
                "Lava tubes from Kilauea reach lengths of dozens of kilometres.",
                "Summit elevation just 1,247 m, but rises 9 km from the seafloor.",
                "Powered by the Hawaiian hotspot beneath the Pacific Plate.",
                "Hawaii Volcanoes National Park surrounds and protects the volcano.",
            ],
            wikipediaSlug: "Kīlauea",
            iconSymbol: "flame.fill"
        ),
        "granite": .init(
            word: "granite",
            summary: "Coarse-grained intrusive igneous rock — backbone of continental crust.",
            facts: [
                "Forms from slow cooling of magma deep underground.",
                "Composed mainly of quartz, feldspar and mica.",
                "Hardness 6–7 on the Mohs scale, very durable.",
                "Common in mountain cores like the Sierra Nevada and Alps.",
                "Used for countertops, monuments and building cladding.",
                "Density around 2.65–2.75 g/cm³.",
                "Crystal size depends on cooling rate — granite cools slowly.",
                "The continental crust is roughly 35–40 km of granite-rich rock.",
                "Stonehenge's bluestones are not granite — they're dolerite.",
                "Granite forms from felsic magma rich in silica (>65%).",
            ],
            wikipediaSlug: "Granite",
            iconSymbol: "cube.fill"
        ),
        "basalt": .init(
            word: "basalt",
            summary: "Fine-grained extrusive volcanic rock — the floor of every ocean.",
            facts: [
                "Solidifies quickly from lava, giving it small crystals.",
                "Makes up most of the oceanic crust on Earth.",
                "The Giant's Causeway in Ireland is famous columnar basalt.",
                "Mafic composition: rich in iron, magnesium and calcium.",
                "Density 2.8–3.0 g/cm³, denser than granite.",
                "Forms from rapid cooling — at mid-ocean ridges or hotspots.",
                "Lunar maria are vast basalt plains visible to the naked eye.",
                "Hexagonal columns form when cooling lava contracts uniformly.",
                "Hawaii's shield volcanoes erupt mostly basaltic lava.",
                "Basalt fibre is being explored as a green concrete reinforcement.",
            ],
            wikipediaSlug: "Basalt",
            iconSymbol: "cube.fill"
        ),
        "obsidian": .init(
            word: "obsidian",
            summary: "Naturally occurring volcanic glass — formed from rapidly cooled lava.",
            facts: [
                "Cools so fast it has no crystal structure — it's a glass.",
                "Razor-sharp fractures: prehistoric tools and surgical scalpels.",
                "Typically black, but can be brown, green or rainbow.",
                "Felsic composition, similar to rhyolite but glassy.",
                "Conchoidal fracture leaves curved, shell-like surfaces.",
                "Native peoples traded obsidian over thousands of kilometres.",
                "Modern obsidian scalpels can produce thinner cuts than steel.",
                "Mahogany obsidian gets its colour from hematite inclusions.",
                "Obsidian Hydration Dating is used by archaeologists.",
                "Found at lava domes — Mono Craters, Lipari, Glass Buttes.",
            ],
            wikipediaSlug: "Obsidian",
            iconSymbol: "diamond.fill"
        ),
        "quartz": .init(
            word: "quartz",
            summary: "Crystalline silicon dioxide — the second most abundant mineral on Earth.",
            facts: [
                "Hardness 7 on the Mohs scale — used as the scale's reference.",
                "Composed of SiO₂ — silicon and oxygen, the most common elements.",
                "Piezoelectric: generates voltage when compressed (used in watches).",
                "Forms hexagonal prismatic crystals in many colors.",
                "Amethyst (purple), citrine (yellow), smoky (grey) are quartz varieties.",
                "Fused quartz has extremely low thermal expansion.",
                "Quartz sand is the main raw material for window glass.",
                "Sand on most beaches is largely quartz grains.",
                "Quartz crystal oscillators stabilize nearly all electronics.",
                "Rock crystal is the optically clear, colourless variety.",
            ],
            wikipediaSlug: "Quartz",
            iconSymbol: "diamond.fill"
        ),
        "pyrite": .init(
            word: "pyrite",
            summary: "Iron sulfide mineral nicknamed Fool's Gold for its metallic shine.",
            facts: [
                "Chemical formula FeS₂ — iron and sulphur.",
                "Brassy yellow colour fooled prospectors during gold rushes.",
                "Forms perfect cubic and pyritohedron crystals.",
                "Hardness 6–6.5, much harder than real gold (2.5–3).",
                "Once burned to make sulfuric acid for industry.",
                "Found in coal seams — pyrite weathering causes acid drainage.",
                "Striking pyrite against steel produces sparks — origin of the name.",
                "Also called marcasite when it forms orthorhombic crystals.",
                "Used in early radios as a detector for crystal sets.",
                "Prized by mineral collectors for its perfect crystal habit.",
            ],
            wikipediaSlug: "Pyrite",
            iconSymbol: "circle.hexagonpath.fill"
        ),
        "caldera": .init(
            word: "caldera",
            summary: "Large volcanic crater formed by collapse after a major eruption.",
            facts: [
                "Forms when a magma chamber empties and the roof collapses.",
                "Yellowstone caldera is one of the largest on Earth, 55×72 km.",
                "Crater Lake in Oregon fills a 7,700-year-old caldera.",
                "Santorini's caldera was formed by the Minoan eruption.",
                "Calderas can be tens of kilometres across — much bigger than craters.",
                "Resurgent calderas have a central uplifted block.",
                "Long Valley and Toba are notable supervolcano calderas.",
                "Many calderas are filled by lakes after their eruption.",
                "Spanish word for cauldron — descriptive of the shape.",
                "Some submarine calderas form vast undersea basins.",
            ],
            wikipediaSlug: "Caldera",
            iconSymbol: "circle.dashed"
        ),
        "tsunami": .init(
            word: "tsunami",
            summary: "Series of long ocean waves caused by sudden displacement of water.",
            facts: [
                "Triggered mostly by undersea earthquakes; also by landslides or volcanoes.",
                "Travel at jet speed across the open ocean — up to 800 km/h.",
                "Wavelengths reach hundreds of kilometres — long, low, fast.",
                "Drawback: water recedes dramatically before the first wave arrives.",
                "2004 Indian Ocean tsunami killed over 230,000 people.",
                "2011 Tōhoku tsunami caused the Fukushima nuclear accident.",
                "Japanese for harbour wave — they hit shores hardest.",
                "Tsunami warning systems use deep-ocean DART buoys.",
                "Krakatoa 1883 generated waves exceeding 30 metres.",
                "Megatsunamis from giant landslides can exceed 500 m runup.",
            ],
            wikipediaSlug: "Tsunami",
            iconSymbol: "water.waves"
        ),
        "andes": .init(
            word: "andes",
            summary: "Longest continental mountain range on Earth — 7,000 km along South America.",
            facts: [
                "Spans 7 countries: Venezuela, Colombia, Ecuador, Peru, Bolivia, Chile, Argentina.",
                "Aconcagua is its highest peak at 6,961 m.",
                "Formed by subduction of the Nazca Plate beneath South America.",
                "Hosts dozens of active volcanoes including Cotopaxi and Chimborazo.",
                "Inca Empire built road networks through the Andean highlands.",
                "Source of the Amazon, the world's largest river by discharge.",
                "Lake Titicaca, the highest navigable lake, sits at 3,812 m.",
                "Macchu Picchu sits at 2,430 m on an Andean ridge.",
                "Climate ranges from tropical to glaciated within short distances.",
                "Holds about 99% of the world's tropical glaciers.",
            ],
            wikipediaSlug: "Andes",
            iconSymbol: "mountain.2.fill"
        ),
        "alps": .init(
            word: "alps",
            summary: "European mountain range arcing 1,200 km from France to Slovenia.",
            facts: [
                "Mont Blanc is the highest peak at 4,809 m.",
                "Formed by the African plate colliding with Eurasia 65 million years ago.",
                "Pass through France, Italy, Switzerland, Germany, Austria, Slovenia.",
                "Source of the Rhine, Rhone, Po and Danube rivers.",
                "Hannibal famously crossed the Alps with elephants in 218 BC.",
                "Glaciers cover roughly 2,000 km² — shrinking due to climate change.",
                "Hosts millions of skiers each winter season.",
                "The Matterhorn (4,478 m) was first climbed in 1865.",
                "Alpine ibex were nearly extinct in 1850 — recovered to ~50,000 today.",
                "Ötzi the Iceman, a 5,300-year-old mummy, was found in the Alps in 1991.",
            ],
            wikipediaSlug: "Alps",
            iconSymbol: "mountain.2.fill"
        ),
        "himalaya": .init(
            word: "himalaya",
            summary: "Mountain range housing Earth's highest peaks — Sanskrit for abode of snow.",
            facts: [
                "Includes 9 of the 14 highest peaks on Earth.",
                "Mount Everest tops out at 8,849 m and is still rising.",
                "Formed by India colliding with Asia about 50 million years ago.",
                "Source of the Indus, Ganges and Brahmaputra rivers.",
                "Spans India, Nepal, Bhutan, China and Pakistan.",
                "Home to over 50 million people.",
                "K2 is the second-highest peak — but climbed less than Everest.",
                "Glaciers feed water to nearly 2 billion people downstream.",
                "Plate convergence still pushes the range up by ~5 mm per year.",
                "Hindu, Buddhist and Bon religions all hold the range as sacred.",
            ],
            wikipediaSlug: "Himalayas",
            iconSymbol: "mountain.2.fill"
        ),
    ]
}
