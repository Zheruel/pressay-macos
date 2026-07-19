public enum EditDistance {
    /// Two-row Levenshtein distance over any equatable elements.
    public static func between<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y
                    ? previous[j]
                    : 1 + min(previous[j], previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[b.count]
    }
}
