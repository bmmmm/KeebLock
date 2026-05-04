import Foundation

/// Curated geology terms for use as unlock codewords.
/// All entries are 5-9 ASCII letters, no umlauts, easy to type, mildly educational.
enum Codewords {
    static let all: [String] = [
        // Volcanoes
        "vesuv", "stromboli", "krakatau", "kilauea", "pinatubo", "cotopaxi",
        "tambora", "hekla", "merapi", "surtsey", "ruapehu", "bromo",
        "erebus", "fuego", "rainier", "lassen", "katmai", "santorin",
        "novarupta", "tongariro", "redoubt", "izalco",
        // Rocks
        "granit", "basalt", "gneis", "marmor", "schiefer", "kalkstein",
        "sandstein", "quarzit", "dolomit", "obsidian", "pumice", "travertin",
        "andesit", "diorit", "gabbro", "diabas", "rhyolith", "trachyt",
        "phonolith", "syenit", "anorthit",
        // Minerals
        "quarz", "pyrit", "olivin", "calcit", "glimmer", "topas",
        "beryll", "augit", "spinell", "apatit", "fluorit", "hematit",
        "magnetit", "limonit", "galenit", "sphalerit", "malachit", "azurit",
        "korund", "granat", "albit", "mikroklin", "lasurit", "markasit",
        "chalcedon", "rutil", "zirkon", "ilmenit",
        // Phenomena
        "caldera", "geysir", "lahar", "tephra", "magma", "eruption",
        "krater", "schlot", "pluton", "lakkolith", "tsunami", "fumarole",
        "solfatar", "mofette", "massiv", "spalte",
        // Mountains
        "anden", "alpen", "atlas", "himalaya", "kaukasus", "karpaten",
        "apennin", "pamir", "tienschan", "karakorum", "sierra", "vosges",
        "eifel", "taunus", "sudeten", "kunlun",
    ]

    static func random() -> String {
        all.randomElement() ?? "granit"
    }

    static func suggestions(count: Int = 6) -> [String] {
        Array(all.shuffled().prefix(count))
    }
}
