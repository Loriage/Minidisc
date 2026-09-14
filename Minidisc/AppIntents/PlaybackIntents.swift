import AppIntents

struct PlayMinidiscMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Play a song, album, artist or playlist from your Minidisc library.")
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "Music") var music: MinidiscMusicEntity
    @Parameter(title: "Shuffle", default: false) var shuffle: Bool
    @Dependency private var runtime: MinidiscRuntime

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$music)") { \.$shuffle }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let service = MusicIntentService(container: try await runtime.container())
        try await service.play(id: music.id, shuffle: shuffle)
        return .result()
    }
}

struct PlayMinidiscMoodIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a Mood"
    static let description = IntentDescription("Play an existing Mood playlist from your active server.")
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "Mood") var mood: Mood
    @Dependency private var runtime: MinidiscRuntime
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$mood)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        let service = MusicIntentService(container: try await runtime.container())
        try await service.play(mood: mood)
        return .result()
    }
}

struct MinidiscSmartShuffleIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Smart Shuffle"
    static var supportedModes: IntentModes { .background }
    @Dependency private var runtime: MinidiscRuntime

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = try await runtime.container()
        try Task.checkCancellation()
        guard container.serverState.activeServer != nil else { throw MusicIntentError.noServer }
        do { try await container.playerService.playSmartShuffle() }
        catch is CancellationError { throw CancellationError() }
        catch { throw MusicIntentError.unavailable }
        return .result()
    }
}

struct ResumeMinidiscIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Playback"
    static var supportedModes: IntentModes { .background }
    @Dependency private var runtime: MinidiscRuntime

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = try await runtime.container()
        try Task.checkCancellation()
        guard container.playerState.currentTrack != nil || container.playerState.currentRadio != nil else {
            throw MusicIntentError.nothingToResume
        }
        await container.playerService.resume()
        return .result()
    }
}

struct PauseMinidiscIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Playback"
    static var supportedModes: IntentModes { .background }
    @Dependency private var runtime: MinidiscRuntime

    func perform() async throws -> some IntentResult {
        let container = try await runtime.container()
        try Task.checkCancellation()
        await container.playerService.pause()
        return .result()
    }
}

struct NextMinidiscTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static var supportedModes: IntentModes { .background }
    @Dependency private var runtime: MinidiscRuntime

    func perform() async throws -> some IntentResult {
        let container = try await runtime.container()
        try Task.checkCancellation()
        try await container.playerService.skipToNext()
        return .result()
    }
}

struct PreviousMinidiscTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static var supportedModes: IntentModes { .background }
    @Dependency private var runtime: MinidiscRuntime

    func perform() async throws -> some IntentResult {
        let container = try await runtime.container()
        try Task.checkCancellation()
        try await container.playerService.skipToPrevious()
        return .result()
    }
}
