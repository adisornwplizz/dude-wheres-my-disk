import Foundation

private struct BatchFailure: Error { let reason: String }
private func expect(_ condition: Bool, _ reason: String) throws {
    if !condition { throw BatchFailure(reason: reason) }
}

@main
private struct BatchEvidenceVerify {
    @MainActor static func main() throws {
        let domain = "privacy-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(AIProvider.openAI.rawValue, forKey: "ai.provider")
        let options = AIOptions(defaults: defaults)
        try expect(options.provider == .ollama, "A saved cloud provider bypassed local-only defaults")
        options.allowSingleWorktreeCloud = true
        try expect(options.provider == .openAI, "Explicit single-worktree opt-in was ignored")
        options.allowSingleWorktreeCloud = false
        try expect(AIOptions(defaults: defaults).provider == .ollama, "Disabling cloud did not survive restart")
        let usage = TokenUsage(defaults: defaults)
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let run = usage.begin("All workspaces", at: yesterday)
        let reported = TokenCounts(input: 17, output: 6, prompt: "omitted", reply: "")
        let estimated = TokenCounts(input: nil, output: 4, prompt: "abcdefgh", reply: "")
        usage.record(reported, for: run, at: yesterday)
        usage.record(estimated, for: run, at: today)
        let zero = usage.begin("All workspaces", at: today)
        let restored = TokenUsage(defaults: defaults)
        try expect(restored.runs.last?.id == zero && restored.runs.last?.total == TokenCounts(), "Git-only run counted tokens")
        try expect(restored.daily(today) == estimated && restored.daily(yesterday) == reported,
                   "Did not separate local days for a run spanning midnight")
        try expect(restored.total.input == 19 && restored.total.output == 10 && restored.total.estimated
                   && restored.runs.first?.total == restored.total, "Lost daily, run or lifetime usage after restart")
        try expect(restored.dailyHistory.map(\.value) == [estimated, reported], "Historical daily totals lost usage")
        let secret = "fixture-private-worktree"
        let categories: [CleanupCategory] = [.detached, .inUse, .cleanable, .uncertain]
        let ranked = (0..<128).map { index -> CleanupRow in
            let tree = Checkout(path: "/" + secret + "/tree-\(index)", branch: secret, head: secret, locked: false, missing: false)
            return CleanupRow(projectID: "/" + secret, tree: tree, category: categories[index % categories.count],
                              detail: secret, bytes: Int64(9_000_000 - index),
                              mergeEvidence: .matchingTree(base: secret, checkpoint: secret, outsideCommits: 5),
                              generatedItemCount: 2, nestedCount: index == 0 ? 1 : 0, parentPath: index == 1 ? secret : nil)
        }
        let review = try BatchAssessment(ranked: ranked, workspaces: 5, onDisk: 10_000_000, cleanable: nil, partial: true)
        let json = try JSONSerialization.jsonObject(with: Data(review.payload.utf8)) as? [String: Any]
        let details = json?["worktrees"] as? [[String: Any]] ?? []
        try expect(!review.payload.contains(secret), "Batch evidence leaked local data")
        try expect(review.payload.utf8.count < 32768 && details.count == 48 && json?["omittedWorktrees"] as? Int == 80, "Wrong detail budget or truncation count")
        try expect(review.items.count == 128 && review.verdictCounts == ["Keep": 32, "Can remove": 32, "Review required": 64], "Truncation affected local coverage")
        try expect(json?["partial"] as? Bool == true && json?["reclaimableEstimateBytes"] == nil &&
                   json?["processActivityAvailable"] as? Bool == false, "Unknown coverage or estimate misrepresented")
        let eligible = review.items.prefix(32)
        try expect(eligible.allSatisfy { $0.row.category == .cleanable }, "Actionable worktrees lost priority")
        try expect(details.first?["id"] as? String == eligible.first?.id, "Model IDs cannot be matched to local rows")
        try expect(Set(review.items.map(\.id)).count == ranked.count, "Duplicate anonymous IDs")
        let reversed = try BatchAssessment(ranked: ranked.reversed(), workspaces: 5, onDisk: 0, cleanable: 0, partial: false)
        let ids = Dictionary(uniqueKeysWithValues: review.items.map { ($0.row.id, $0.id) })
        try expect(reversed.items.allSatisfy { ids[$0.row.id] == $0.id }, "Changing size order changed snapshot IDs")
        let first = review.items[0]
        let second = review.items[1]
        let omitted = review.items[review.shownToModel]
        let mockReply: [String: Any] = ["summary": "3 stages checked", "byReason": ["cleanable": "Review generated items"],
                                        "byWorktree": [first.id: "Check the selected checkout path",
                                                       omitted.id: "Ungrounded override", "W9999": "Unknown ID"]]
        let raw = try JSONSerialization.data(withJSONObject: mockReply)
        let advice = try BatchSuggestions.read(String(decoding: raw, as: UTF8.self), matching: review)
        try expect(advice.summary == "3 stages checked" && advice.advice[first.row.id] == "Check the selected checkout path",
                   "Specific recommendation was lost")
        try expect(advice.advice[second.row.id] == nil && advice.advice[omitted.row.id] != "Ungrounded override",
                   "Repeated group guidance or accepted advice for an omitted row")
        var acceptedBadReply = false
        do { _ = try BatchSuggestions.read("Delete everything", matching: review); acceptedBadReply = true } catch {}
        try expect(!acceptedBadReply, "Unstructured model response became actionable advice")
        let empty = try BatchAssessment(ranked: [], workspaces: 1, onDisk: 0, cleanable: 0, partial: false)
        try expect(empty.items.isEmpty && empty.shownToModel == 0, "Empty workspace created candidate detail")
        print("Verified all-workspace verdict counts, priority, stable anonymous IDs, redaction, truncation and partial coverage.")
    }
}
