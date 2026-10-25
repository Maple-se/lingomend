/// Focused descendants can be discovered without reading their text. Ambiguous
/// containers and unrelated fields never gain edit authority through role scores.
enum EditorCandidateSelection {
    static func uniqueFocusedDescendant(_ eligible: [Bool]) -> Int? {
        let indices = eligible.indices.filter { eligible[$0] }
        return indices.count == 1 ? indices[0] : nil
    }
}
