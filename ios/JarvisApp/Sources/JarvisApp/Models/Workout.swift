import Foundation

/// One exercise as planned in `workout_plan.plan_json.exercises[]`.
struct ExercisePlan: Codable, Equatable, Identifiable {
    let exerciseSlug: String
    let targetSets: Int
    let targetReps: String        // e.g. "8-10"
    let targetRir: Int
    let restSec: Int
    var notes: String?

    var id: String { exerciseSlug }

    enum CodingKeys: String, CodingKey {
        case exerciseSlug = "exercise_slug"
        case targetSets = "target_sets"
        case targetReps = "target_reps"
        case targetRir = "target_rir"
        case restSec = "rest_sec"
        case notes
    }
}

/// Top-level plan handed to iOS at workout start.
struct WorkoutPlan: Codable, Equatable {
    let workoutId: String
    let dayName: String
    let week: Int
    let intensityLabel: String
    let exercises: [ExercisePlan]
    let imageManifest: [ImageManifestEntry]

    struct ImageManifestEntry: Codable, Equatable, Hashable {
        let slug: String
        let sha256: String
    }

    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case dayName = "day_name"
        case week
        case intensityLabel = "intensity_label"
        case exercises
        case imageManifest = "image_manifest"
    }
}

/// One completed set the user logged.
struct LoggedSet: Codable, Equatable {
    let reps: Int
    let weight: Double
    let repsInReserve: Int
    let ts: Date

    enum CodingKeys: String, CodingKey {
        case reps, weight
        case repsInReserve = "reps_in_reserve"
        case ts
    }
}

/// All logged sets for one exercise within a workout.
struct LoggedExercise: Codable, Equatable {
    let exerciseSlug: String
    var sets: [LoggedSet]
    var comment: String?

    enum CodingKeys: String, CodingKey {
        case exerciseSlug = "exercise_slug"
        case sets, comment
    }
}

/// Final session payload sent in workout_complete and persisted by Payne.
struct WorkoutSession: Codable, Equatable {
    let workoutId: String
    let date: String              // "YYYY-MM-DD"
    let dayName: String
    let week: Int
    let startedAt: Date
    var finishedAt: Date?
    var exercises: [LoggedExercise]
    var perceivedOverallRir: Int?
    var healthSignalAtStart: String?

    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case date
        case dayName = "day_name"
        case week
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case exercises
        case perceivedOverallRir = "perceived_overall_rir"
        case healthSignalAtStart = "health_signal_at_start"
    }
}
