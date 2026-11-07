import Foundation
import Combine

struct TokenCounts: Codable, Equatable {
    var input = 0
    var output = 0
    var estimated = false

    init() {}

    init(input: Int?, output: Int?, prompt: String, reply: String) {
        func count(_ reported: Int?, _ text: String) -> Int {
            if let reported, (0...1_000_000_000).contains(reported) { return reported }
            return (text.utf8.count + 3) / 4
        }
        self.input = count(input, prompt)
        self.output = count(output, reply)
        estimated = input != self.input || output != self.output
    }

    static func + (left: Self, right: Self) -> Self {
        var sum = Self()
        sum.input = left.input + right.input
        sum.output = left.output + right.output
        sum.estimated = left.estimated || right.estimated
        return sum
    }

    var label: String {
        (estimated ? "≈ " : "") + input.formatted() + " in · " + output.formatted() + " out"
    }
}

@MainActor
final class TokenUsage: ObservableObject {
    struct Run: Codable, Identifiable {
        let id: UUID
        let started: Date
        let label: String
        var days: [String: TokenCounts] = [:]
        var total: TokenCounts { days.values.reduce(TokenCounts(), +) }
    }

    static let shared = TokenUsage()
    private let defaults: UserDefaults
    private let key = "analysis.tokenUsage.v1"
    @Published private(set) var runs: [Run]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        runs = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Run].self, from: $0) } ?? []
    }

    func begin(_ label: String, at time: Date = Date()) -> UUID {
        let run = Run(id: UUID(), started: time, label: label)
        runs.append(run)
        save()
        return run.id
    }

    func record(_ tokens: TokenCounts, for id: UUID, at time: Date = Date()) {
        guard let index = runs.lastIndex(where: { $0.id == id }) else { return }
        let day = Self.day(time)
        runs[index].days[day] = (runs[index].days[day] ?? TokenCounts()) + tokens
        save()
    }

    func daily(_ date: Date) -> TokenCounts {
        let day = Self.day(date)
        return runs.compactMap { $0.days[day] }.reduce(TokenCounts(), +)
    }

    var total: TokenCounts { runs.reduce(TokenCounts()) { $0 + $1.total } }

    var dailyHistory: [(key: String, value: TokenCounts)] {
        var totals: [String: TokenCounts] = [:]
        for run in runs {
            if run.days.isEmpty, totals[Self.day(run.started)] == nil { totals[Self.day(run.started)] = TokenCounts() }
            for (day, count) in run.days { totals[day] = (totals[day] ?? TokenCounts()) + count }
        }
        return totals.sorted { $0.key > $1.key }
    }

    private static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(runs) { defaults.set(data, forKey: key) }
    }
}
