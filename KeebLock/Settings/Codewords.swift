import Foundation

/// Curated geology terms used as unlock codewords.
/// All entries are 5–10 ASCII letters, no diacritics, easy to type, mildly educational.
enum Codewords {
    static let all: [String] = [
        // Volcanoes (proper names — same in English)
        "vesuvius", "stromboli", "krakatoa", "kilauea", "pinatubo", "cotopaxi",
        "tambora", "hekla", "merapi", "surtsey", "ruapehu", "bromo",
        "erebus", "fuego", "rainier", "lassen", "katmai", "santorini",
        "novarupta", "tongariro", "redoubt", "izalco",
        // Rocks
        "granite", "basalt", "gneiss", "marble", "slate", "limestone",
        "sandstone", "quartzite", "dolomite", "obsidian", "pumice", "travertine",
        "andesite", "diorite", "gabbro", "diabase", "rhyolite", "trachyte",
        "phonolite", "syenite", "anorthite",
        // Minerals
        "quartz", "pyrite", "olivine", "calcite", "mica", "topaz",
        "beryl", "augite", "spinel", "apatite", "fluorite", "hematite",
        "magnetite", "limonite", "galena", "sphalerite", "malachite", "azurite",
        "corundum", "garnet", "albite", "microcline", "lazurite", "marcasite",
        "chalcedony", "rutile", "zircon", "ilmenite",
        // Phenomena
        "hotspring", "geyser", "lahar", "tephra", "magma", "eruption",
        "crater", "vent", "pluton", "laccolith", "tsunami", "fumarole",
        "solfatara", "sinkhole", "escarpment", "fissure",
        // Mountain ranges
        "andes", "alps", "atlas", "himalaya", "caucasus", "carpathians",
        "apennines", "pamir", "tienshan", "karakoram", "sierra", "vosges",
        "eifel", "taunus", "sudetes", "kunlun",
    ]

    /// Words usable as codewords — `all` minus any that lack bundled
    /// Wikipedia/Wikimedia data. Falls back to `all` if the manifest didn't
    /// load (so the launcher is never empty even in degraded states).
    static var available: [String] {
        let unavailable = CodewordKnowledgeBase.unavailableWords
        let filtered = all.filter { !unavailable.contains($0) }
        return filtered.isEmpty ? all : filtered
    }

    static func random() -> String {
        available.randomElement() ?? "granite"
    }

    static func suggestions(count: Int = 6) -> [String] {
        Array(available.shuffled().prefix(count))
    }
}
