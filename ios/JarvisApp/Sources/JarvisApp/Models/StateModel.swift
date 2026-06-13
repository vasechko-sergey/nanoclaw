import Foundation

struct StateModel: Codable, Equatable {
    struct Levels: Codable, Equatable {
        var energy: Int?; var stress: Int?; var recovery: Int?; var readiness: Int?
        var recovery7d: [Int]?; var updated: String?
    }
    struct AgentRow: Codable, Equatable, Identifiable {
        var key: String; var title: String; var icon: String
        var summary: String?; var detail: String?; var updated: String?
        var id: String { key }
    }
    var levels: Levels
    var agents: [AgentRow]
}
