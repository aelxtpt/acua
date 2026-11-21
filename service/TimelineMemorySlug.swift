import Foundation

enum TimelineMemorySlug {
    static func make(from content: String) -> String {
        let heading = content.split(separator: "\n").first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
        let title = heading.map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines))
        }
        let text = (title?.isEmpty == false ? title! : "summary").lowercased()
        var result = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if result.last != "-" {
                result.append("-")
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "summary" : String(result.prefix(80))
    }
}
