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
        "caldera", "geyser", "lahar", "tephra", "magma", "eruption",
        "crater", "vent", "pluton", "laccolith", "tsunami", "fumarole",
        "solfatara", "mofette", "massif", "fissure",
        // Mountain ranges
        "andes", "alps", "atlas", "himalaya", "caucasus", "carpathians",
        "apennines", "pamir", "tienshan", "karakoram", "sierra", "vosges",
        "eifel", "taunus", "sudetes", "kunlun",
    ]

    static func random() -> String {
        all.randomElement() ?? "granite"
    }

    static func suggestions(count: Int = 6) -> [String] {
        Array(all.shuffled().prefix(count))
    }
}
