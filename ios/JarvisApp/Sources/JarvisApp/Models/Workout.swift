import Foundation

/// One exercise as planned in `workout_plan.plan_json.exercises[]`.
///
/// Lenient decoding: Payne's plan_json uses `slug` / `reps_in_reserve` /
/// `rest_seconds`, and a cardio warmup may carry `target_sets: null` and
/// `target_reps: ""`. Accept those (and the canonical `exercise_slug` /
/// `target_rir` / `rest_sec`) and default any missing/null numeric so the whole
/// plan still decodes — otherwise one warmup row sinks the entire card. Encode
/// stays canonical (so the B2 persist→reload round-trip is stable).
struct ExercisePlan: Codable, Equatable, Identifiable {
    let exerciseSlug: String
    let targetSets: Int
    let targetReps: String        // e.g. "8-10"
    let targetRir: Int
    let restSec: Int
    var notes: String?

    var id: String { exerciseSlug }

    init(exerciseSlug: String, targetSets: Int, targetReps: String, targetRir: Int, restSec: Int, notes: String? = nil) {
        self.exerciseSlug = exerciseSlug
        self.targetSets = targetSets
        self.targetReps = targetReps
        self.targetRir = targetRir
        self.restSec = restSec
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case exerciseSlug = "exercise_slug"
        case slug                       // plan_json alias for exercise_slug
        case targetSets = "target_sets"
        case targetReps = "target_reps"
        case targetRir = "target_rir"
        case repsInReserve = "reps_in_reserve"  // plan_json alias for target_rir
        case restSec = "rest_sec"
        case restSeconds = "rest_seconds"        // plan_json alias for rest_sec
        case notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exerciseSlug = (try? c.decode(String.self, forKey: .exerciseSlug))
            ?? (try? c.decode(String.self, forKey: .slug)) ?? ""
        targetSets = (try? c.decode(Int.self, forKey: .targetSets)) ?? 0
        targetReps = (try? c.decode(String.self, forKey: .targetReps)) ?? ""
        targetRir = (try? c.decode(Int.self, forKey: .targetRir))
            ?? (try? c.decode(Int.self, forKey: .repsInReserve)) ?? 0
        restSec = (try? c.decode(Int.self, forKey: .restSec))
            ?? (try? c.decode(Int.self, forKey: .restSeconds)) ?? 0
        notes = try? c.decode(String.self, forKey: .notes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exerciseSlug, forKey: .exerciseSlug)
        try c.encode(targetSets, forKey: .targetSets)
        try c.encode(targetReps, forKey: .targetReps)
        try c.encode(targetRir, forKey: .targetRir)
        try c.encode(restSec, forKey: .restSec)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}

/// Top-level plan handed to iOS at workout start. Lenient decode like
/// `ExercisePlan` — Payne's plan_json names the intensity `week_label`.
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

    init(workoutId: String, dayName: String, week: Int, intensityLabel: String,
         exercises: [ExercisePlan], imageManifest: [ImageManifestEntry]) {
        self.workoutId = workoutId
        self.dayName = dayName
        self.week = week
        self.intensityLabel = intensityLabel
        self.exercises = exercises
        self.imageManifest = imageManifest
    }

    enum CodingKeys: String, CodingKey {
        case workoutId = "workout_id"
        case dayName = "day_name"
        case week
        case intensityLabel = "intensity_label"
        case weekLabel = "week_label"   // plan_json alias for intensity_label
        case exercises
        case imageManifest = "image_manifest"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workoutId = (try? c.decode(String.self, forKey: .workoutId)) ?? ""
        dayName = (try? c.decode(String.self, forKey: .dayName)) ?? ""
        week = (try? c.decode(Int.self, forKey: .week)) ?? 0
        intensityLabel = (try? c.decode(String.self, forKey: .intensityLabel))
            ?? (try? c.decode(String.self, forKey: .weekLabel)) ?? ""
        exercises = (try? c.decode([ExercisePlan].self, forKey: .exercises)) ?? []
        imageManifest = (try? c.decode([ImageManifestEntry].self, forKey: .imageManifest)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workoutId, forKey: .workoutId)
        try c.encode(dayName, forKey: .dayName)
        try c.encode(week, forKey: .week)
        try c.encode(intensityLabel, forKey: .intensityLabel)
        try c.encode(exercises, forKey: .exercises)
        try c.encode(imageManifest, forKey: .imageManifest)
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
