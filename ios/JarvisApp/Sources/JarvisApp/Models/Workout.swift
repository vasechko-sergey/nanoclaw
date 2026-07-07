import Foundation

/// One exercise as planned in `workout_plan.plan_json.exercises[]`.
///
/// Keys are pinned to Payne's canonical plan_json vocab: `slug` /
/// `reps_in_reserve` / `rest_seconds`. A cardio warmup may carry
/// `target_sets: null` and `target_reps: ""`; default any missing/null numeric
/// so the whole plan still decodes — otherwise one warmup row sinks the entire
/// card. Encode is canon too, so the B2 persist→reload round-trip is stable.
struct ExercisePlan: Codable, Equatable, Identifiable {
    let exerciseSlug: String
    let targetSets: Int
    let targetReps: String        // e.g. "8-10"
    let targetRir: Int
    let restSec: Int
    var notes: String?
    /// Russian display name from plan_json (`name_ru`). Optional — warmups /
    /// older plans may omit it; `displayName` falls back to the slug.
    var nameRu: String?
    /// Some exercises are timed (cardio/warmup) rather than set×rep — seconds.
    var durationSec: Int?
    /// Payne's recommended working weight (kg) for this exercise. Optional —
    /// warmups omit it. Drives the weight-wheel default + the recs panel.
    var weightKgTarget: Double?

    var id: String { exerciseSlug }

    /// Timed exercise (treadmill, warmup) — show a duration card, not set logging.
    var isDuration: Bool { targetSets <= 0 && (durationSec ?? 0) > 0 }

    /// Russian name when present; else a capitalized, de-hyphenated slug
    /// (so the UI never shows raw transliteration like "zhim shtangi lezha").
    var displayName: String {
        if let n = nameRu, !n.isEmpty { return n }
        let pretty = exerciseSlug.replacingOccurrences(of: "-", with: " ")
        return pretty.prefix(1).uppercased() + pretty.dropFirst()
    }

    init(exerciseSlug: String, targetSets: Int, targetReps: String, targetRir: Int, restSec: Int, notes: String? = nil, nameRu: String? = nil, durationSec: Int? = nil, weightKgTarget: Double? = nil) {
        self.exerciseSlug = exerciseSlug
        self.targetSets = targetSets
        self.targetReps = targetReps
        self.targetRir = targetRir
        self.restSec = restSec
        self.notes = notes
        self.nameRu = nameRu
        self.durationSec = durationSec
        self.weightKgTarget = weightKgTarget
    }

    enum CodingKeys: String, CodingKey {
        case exerciseSlug = "slug"
        case targetSets = "target_sets"
        case targetReps = "target_reps"
        case targetRir = "reps_in_reserve"
        case restSec = "rest_seconds"
        case notes
        case nameRu = "name_ru"
        case durationSec = "duration_seconds"
        case weightKgTarget = "weight_kg_target"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exerciseSlug = (try? c.decode(String.self, forKey: .exerciseSlug)) ?? ""
        targetSets = (try? c.decode(Int.self, forKey: .targetSets)) ?? 0   // null warmup → 0
        targetReps = (try? c.decode(String.self, forKey: .targetReps)) ?? ""
        targetRir = (try? c.decode(Int.self, forKey: .targetRir)) ?? 0     // null warmup → 0
        restSec = (try? c.decode(Int.self, forKey: .restSec)) ?? 0
        notes = try? c.decode(String.self, forKey: .notes)
        nameRu = try? c.decode(String.self, forKey: .nameRu)
        durationSec = try? c.decode(Int.self, forKey: .durationSec)
        weightKgTarget = try? c.decode(Double.self, forKey: .weightKgTarget)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exerciseSlug, forKey: .exerciseSlug)
        try c.encode(targetSets, forKey: .targetSets)
        try c.encode(targetReps, forKey: .targetReps)
        try c.encode(targetRir, forKey: .targetRir)
        try c.encode(restSec, forKey: .restSec)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(nameRu, forKey: .nameRu)
        try c.encodeIfPresent(durationSec, forKey: .durationSec)
        try c.encodeIfPresent(weightKgTarget, forKey: .weightKgTarget)
    }
}

/// Top-level plan handed to iOS at workout start. Keys pinned to Payne's
/// canonical plan_json vocab — the intensity field is `week_label`.
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
        case intensityLabel = "week_label"
        case exercises
        case imageManifest = "image_manifest"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workoutId = (try? c.decode(String.self, forKey: .workoutId)) ?? ""
        dayName = (try? c.decode(String.self, forKey: .dayName)) ?? ""
        week = (try? c.decode(Int.self, forKey: .week)) ?? 0
        intensityLabel = (try? c.decode(String.self, forKey: .intensityLabel)) ?? ""
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
    var deviation: WorkoutRunnerLogic.SetDeviation?
    var coachHint: String?

    enum CodingKeys: String, CodingKey {
        case reps, weight
        case repsInReserve = "reps_in_reserve"
        case ts
        case deviation
        case coachHint = "coach_hint"
    }

    init(reps: Int, weight: Double, repsInReserve: Int, ts: Date,
         deviation: WorkoutRunnerLogic.SetDeviation? = nil, coachHint: String? = nil) {
        self.reps = reps; self.weight = weight; self.repsInReserve = repsInReserve; self.ts = ts
        self.deviation = deviation; self.coachHint = coachHint
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
    /// Subjective 1–5 rating of the whole session (1 = tough … 5 = easy),
    /// replacing the redundant overall-RIR. Sent to Payne in workout_complete.
    var sessionFeeling: Int? = nil
    /// Human label for `sessionFeeling` so Payne reads the scale without guessing.
    var sessionFeelingLabel: String? = nil

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
        case sessionFeeling = "session_feeling"
        case sessionFeelingLabel = "session_feeling_label"
    }
}
