import Foundation

/// Curated geology terms used as unlock codewords.
/// All entries are 5–10 ASCII letters, no diacritics, easy to type, mildly educational.
enum Codewords {
    static let all: [String] = [
        // Volcanoes (proper names — same in English)
        "vesuvius", "stromboli", "krakatoa", "kilauea", "pinatubo", "cotopaxi",
        "tambora", "hekla", "merapi", "surtsey", "ruapehu", "bromo",
        "erebus", "fuego", "rainier", "lassen", "katmai", "santorini",
        "novarupta", "tongariro", "redoubt", "etna",
        // Rocks
        "granite", "basalt", "gneiss", "marble", "slate", "limestone",
        "sandstone", "quartzite", "dolomite", "obsidian", "pumice", "travertine",
        "andesite", "diorite", "gabbro", "diabase", "rhyolite", "trachyte",
        "phonolite", "syenite", "chert",
        // Minerals
        "quartz", "pyrite", "olivine", "calcite", "mica", "topaz",
        "beryl", "tourmaline", "spinel", "apatite", "fluorite", "hematite",
        "magnetite", "limonite", "galena", "sphalerite", "malachite", "azurite",
        "corundum", "garnet", "albite", "microcline", "lazurite", "marcasite",
        "chalcedony", "rutile", "zircon", "ilmenite",
        // Phenomena
        "hotspring", "geyser", "lahar", "tephra", "magma", "eruption",
        "crater", "vent", "pluton", "laccolith", "tsunami", "fumarole",
        "solfatara", "sinkhole", "escarpment", "fissure",
        "earthquake", "lapilli", "avalanche", "landslide", "mudflow",
        "rockfall", "subsidence", "seiche", "lavaflow", "erosion",
        // Mountain ranges
        "andes", "alps", "atlas", "himalaya", "caucasus", "carpathians",
        "apennines", "pamir", "tienshan", "karakoram", "sierra", "vosges",
        "eifel", "taunus", "sudetes", "kunlun",
    ]

    /// Words usable as codewords — `all` restricted to those that actually
    /// have a bundled knowledge entry (title/summary/facts/image). Filtering
    /// on the presence of a real entry — rather than on the manifest's
    /// `unavailable` list — guarantees we can never roll a word that would
    /// render as an empty stub in the HUD, even if `all` and the manifest
    /// drift apart in a future change. Falls back to `all` only if the
    /// manifest failed to load entirely (so the launcher is never empty in
    /// degraded states).
    static var available: [String] {
        let known = CodewordKnowledgeBase.entries
        let filtered = all.filter { known[$0] != nil }
        return filtered.isEmpty ? all : filtered
    }

    static func random() -> String {
        available.randomElement() ?? "granite"
    }

    static func suggestions(count: Int = 6) -> [String] {
        Array(available.shuffled().prefix(count))
    }
}
