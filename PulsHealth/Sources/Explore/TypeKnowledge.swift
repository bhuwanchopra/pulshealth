import Foundation

/// One knowledge-base article, decoded from the bundled `knowledge.json`
/// (rendered by `scripts/gen-knowledge-json.py` from `knowledge-base/`).
///
/// Only the fields the type page shows are modelled — the generator writes
/// only those — and every one is optional because it writes `null` for
/// anything a YAML file leaves out; a missing article must never take the
/// page down with it.
struct TypeKnowledge: Decodable, Sendable {
    struct TypicalRange: Decodable, Sendable {
        var min: Double?
        var max: Double?
        var unit: String?
        var notes: String?
    }

    struct CategoryValue: Decodable, Sendable {
        var value: Int?
        var name: String?
        var description: String?
    }

    var identifier: String?
    var humanReadableName: String?
    var shortDescription: String?
    var defaultUnit: String?
    var typicalRange: TypicalRange?
    var categoryValues: [CategoryValue]?

    enum CodingKeys: String, CodingKey {
        case identifier
        case humanReadableName = "human_readable_name"
        case shortDescription = "short_description"
        case defaultUnit = "default_unit"
        case typicalRange = "typical_range"
        case categoryValues = "category_values"
    }

    /// The label the knowledge base gives a category type's raw value, when
    /// the article lists its values: the enum name spelled out.
    func categoryLabel(for rawValue: Int) -> String? {
        categoryValues?.first { $0.value == rawValue }?.displayName
    }

    /// The enum name as words: `asleepCore` → "Asleep core", `asleepREM` →
    /// "Asleep REM", `notPresent` → "Not present". The names are the
    /// `HKCategoryValue…` cases minus their prefix, so this is the only
    /// transformation they need.
    static func humanize(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            if character.isUppercase, !current.isEmpty {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                // A boundary before a capital that follows a lowercase letter
                // ("asleep|Core"), or that starts a word after an acronym
                // ("REM|Sleep") — never inside the acronym itself.
                if previous.isLowercase || previous.isNumber || (next?.isLowercase ?? false) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        let joined = words.joined(separator: " ")
        guard let first = joined.first else { return name }
        return first.uppercased() + joined.dropFirst()
    }
}

extension TypeKnowledge.CategoryValue {
    /// `name` as words, or the raw value when the article has no name.
    var displayName: String {
        if let name, !name.isEmpty { return TypeKnowledge.humanize(name) }
        return value.map { "Value \($0)" } ?? "Unnamed value"
    }
}

extension TypeKnowledge {
    // MARK: - Lookup

    /// The article for a catalog identifier, or nil when the knowledge base
    /// has none.
    static func article(for identifier: String) -> TypeKnowledge? {
        articles[identifier]
    }

    /// Kick off the one-time decode away from the main actor so the first
    /// type page does not pay for it.
    static func preload() {
        Task.detached(priority: .utility) { _ = articles }
    }

    /// Decoded once; ~150 KB of JSON, so the first access is the slow one and
    /// `preload` moves it off the screen's path.
    private static let articles: [String: TypeKnowledge] = {
        guard let url = Bundle.main.url(forResource: "knowledge", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: TypeKnowledge].self, from: data)
        else { return [:] }
        return decoded
    }()
}
