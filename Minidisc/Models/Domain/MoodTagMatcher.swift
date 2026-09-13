import Foundation

nonisolated struct SongTagFeatures: Sendable, Equatable {
    let moods: [String]
    let genres: [String]
    let bpm: Int?

    init(moods: [String] = [], genres: [String] = [], bpm: Int? = nil) {
        self.moods = moods
        self.genres = genres
        self.bpm = bpm
    }
}

/// Tag-based fallback when AudioMuse is unavailable. Weights MOOD above BPM above genre.
nonisolated enum MoodTagMatcher {

    static let moodTagWeight = 3.0
    static let bpmWeight = 2.0
    static let genreWeight = 1.0

    /// Words looked for inside a track's MOOD tags. Substring matching, lowercased, because these
    /// tags are free text and arrive as "Calm", "calm/relaxed", "Relaxing" in equal measure.
    static func moodKeywords(_ mood: Mood) -> [String] {
        switch mood {
        case .night:     return ["calm", "ambient", "dreamy", "mellow", "sleep", "quiet", "soft", "atmospheric", "nocturnal"]
        case .energetic: return ["energetic", "happy", "upbeat", "party", "driving", "bright", "euphoric"]
        case .workout:   return ["aggressive", "energetic", "intense", "powerful", "driving", "angry"]
        case .chill:     return ["chill", "relax", "mellow", "laid", "smooth", "lazy", "warm"]
        case .focus:     return ["instrumental", "calm", "ambient", "minimal", "meditative", "hypnotic"]
        }
    }

    /// Genres queried on the server and matched against. Also substring-matched, so "Hip-Hop/Rap"
    /// catches "hip hop" and "Post-Rock" catches "rock" — deliberate, since genre is the loose
    /// signal anyway.
    static func genres(_ mood: Mood) -> [String] {
        switch mood {
        case .night:     return ["ambient", "downtempo", "chillout", "classical", "jazz"]
        case .energetic: return ["dance", "pop", "rock", "electronic", "punk"]
        case .workout:   return ["hip hop", "techno", "metal", "drum and bass", "house"]
        case .chill:     return ["lo-fi", "soul", "r&b", "reggae", "chillout"]
        case .focus:     return ["ambient", "classical", "instrumental", "soundtrack", "minimal"]
        }
    }

    /// No BPM filter for Focus: both slow pieces and fast, steady tracks can qualify.
    static func bpmRange(_ mood: Mood) -> ClosedRange<Int>? {
        switch mood {
        case .night:     return 40...100
        case .energetic: return 118...200
        case .workout:   return 128...200
        case .chill:     return 70...110
        case .focus:     return nil
        }
    }

    /// Normalizes punctuation and removes the whole token "and", so Hip-Hop/Rap and
    /// Hip Hop agree without changing words such as Sandwich.
    static func normalise(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0 != "and" }
            .joined()
    }

    private static func matches(_ tags: [String], anyOf keywords: [String]) -> Bool {
        let normalisedTags = tags.map(normalise)
        let normalisedKeywords = keywords.map(normalise)
        return normalisedTags.contains { tag in normalisedKeywords.contains { !$0.isEmpty && tag.contains($0) } }
    }

    /// nil means no usable tags; zero means tags were present but none matched.
    static func score(_ features: SongTagFeatures, for mood: Mood) -> Double? {
        var total = 0.0
        var sawSignal = false

        if !features.moods.isEmpty {
            sawSignal = true
            if matches(features.moods, anyOf: moodKeywords(mood)) { total += moodTagWeight }
        }

        if !features.genres.isEmpty {
            sawSignal = true
            if matches(features.genres, anyOf: genres(mood)) { total += genreWeight }
        }

        if let bpm = features.bpm, bpm > 0, let range = bpmRange(mood) {
            sawSignal = true
            if range.contains(bpm) { total += bpmWeight }
        }

        guard sawSignal else { return nil }
        return total
    }

    /// Drops zero scores and breaks ties by ID for stable results.
    static func rank(_ candidates: [(id: String, features: SongTagFeatures)], for mood: Mood, limit: Int) -> [String] {
        candidates
            .compactMap { candidate -> (String, Double)? in
                guard let score = score(candidate.features, for: mood), score > 0 else { return nil }
                return (candidate.id, score)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(limit)
            .map(\.0)
    }
}
