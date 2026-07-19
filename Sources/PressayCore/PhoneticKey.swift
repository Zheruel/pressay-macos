import Foundation

/// Phonetic keying for mishearing matching: digraph collapse, vowel-drop after
/// the first letter, c/g→K, d→T, v→F, w/h drop, duplicate collapse.
/// "kimmy" = "kimi" = "KM"; "cloud code" = "claude code" = "KLTKT".
public enum PhoneticKey {
    public static func key(_ phrase: String) -> String {
        phrase
            .split(whereSeparator: { !$0.isLetter })
            .map { wordKey($0) }
            .joined()
    }

    /// Levenshtein distance between two already-keyed strings.
    public static func distance(_ a: String, _ b: String) -> Int {
        EditDistance.between(Array(a), Array(b))
    }

    private static let digraphs: [String: Character] = [
        "ph": "F", "th": "T", "sh": "X", "ch": "K", "ck": "K",
    ]

    private static func wordKey(_ word: Substring) -> String {
        let letters = Array(word.lowercased())
        guard let first = letters.first else { return "" }
        var output = String(first).uppercased()
        var index = 1
        while index < letters.count {
            if index + 1 < letters.count,
               let digraph = digraphs[String(letters[index...index + 1])] {
                output.append(digraph)
                index += 2
                continue
            }
            let c = letters[index]
            switch c {
            case "a", "e", "i", "o", "u", "y", "w", "h":
                break
            case "x": output.append("KS")
            case "z": output.append("S")
            case "q", "g", "c": output.append("K")
            case "d": output.append("T")
            case "v": output.append("F")
            default: output.append(Character(String(c).uppercased()))
            }
            index += 1
        }
        // Collapse consecutive duplicates ("KMM" -> "KM").
        var collapsed = ""
        for character in output where collapsed.last != character {
            collapsed.append(character)
        }
        return collapsed
    }
}
