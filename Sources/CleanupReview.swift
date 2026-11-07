import Foundation

extension CleanupCategory {
    var isReviewCandidate: Bool { self != .cleanable && self != .inUse }
}

struct CleanupRow: Identifiable {
    struct ID: Hashable {
        let repo: String
        let path: String
    }

    let projectID: String
    let tree: Checkout
    let category: CleanupCategory
    let detail: String?
    let bytes: Int64?
    let mergeEvidence: MergeEvidence
    let generatedItemCount: Int?
    let nestedCount: Int
    let parentPath: String?
    var id: ID { ID(repo: projectID, path: tree.path) }
}

struct CleanupGroup: Identifiable {
    let category: CleanupCategory
    let rows: [CleanupRow]
    let bytes: Int64?
    var id: CleanupCategory { category }
}

struct CheckoutNesting {
    private(set) var parents: [String: String] = [:]
    private(set) var nestedCounts: [String: Int] = [:]

    init(projects: [Project]) {
        let paths = Set(projects.flatMap { $0.trees.map(\.path) })
        for path in paths {
            var ancestor = (path as NSString).deletingLastPathComponent
            while ancestor.hasPrefix("/") && ancestor != "/" {
                if paths.contains(ancestor) {
                    if parents[path] == nil { parents[path] = ancestor }
                    nestedCounts[ancestor, default: 0] += 1
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
    }
}

struct CleanupReview {
    let rows: [CleanupRow]
    let groups: [CleanupGroup]

    init(projects: [Project], nesting: CheckoutNesting, disk: WorkspaceStorage.Measurement) {
        rows = projects.flatMap { project in
            project.trees.map { tree in
                let inspection = project.inspections[tree.id]
                return CleanupRow(projectID: project.id, tree: tree, category: inspection?.category ?? .uncertain,
                                  detail: inspection?.reason, bytes: inspection?.bytes,
                                  mergeEvidence: inspection?.mergeEvidence ?? .unchecked, generatedItemCount: inspection?.generatedFolders.count,
                                  nestedCount: nesting.nestedCounts[tree.path] ?? 0, parentPath: nesting.parents[tree.path])
            }
        }.sorted {
            if $0.bytes != $1.bytes { return ($0.bytes ?? -1) > ($1.bytes ?? -1) }
            if $0.tree.path != $1.tree.path { return $0.tree.path < $1.tree.path }
            return $0.projectID < $1.projectID
        }

        groups = Dictionary(grouping: rows, by: \.category).map { category, members in
            let bytes = members.allSatisfy { $0.bytes != nil } ? disk.allocated(paths: members.map { $0.tree.path }) : nil
            return CleanupGroup(category: category, rows: members, bytes: bytes)
        }.sorted {
            if $0.bytes != $1.bytes { return ($0.bytes ?? -1) > ($1.bytes ?? -1) }
            return $0.category.rawValue < $1.category.rawValue
        }
    }
}
