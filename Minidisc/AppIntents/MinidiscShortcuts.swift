import AppIntents

struct MinidiscShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayMinidiscMusicIntent(), phrases: [
            "Play \(\.$music) in \(.applicationName)",
            "Play music in \(.applicationName)"
        ], shortTitle: "Play Music", systemImageName: "play.fill")
        AppShortcut(intent: PlayMinidiscMoodIntent(), phrases: [
            "Play \(\.$mood) mood in \(.applicationName)",
            "Play a mood in \(.applicationName)"
        ], shortTitle: "Play a Mood", systemImageName: "moon.stars")
        AppShortcut(intent: MinidiscSmartShuffleIntent(), phrases: [
            "Smart Shuffle in \(.applicationName)"
        ], shortTitle: "Smart Shuffle", systemImageName: "shuffle")
        AppShortcut(intent: ResumeMinidiscIntent(), phrases: [
            "Resume playback in \(.applicationName)"
        ], shortTitle: "Resume Playback", systemImageName: "play.circle")
        AppShortcut(intent: PauseMinidiscIntent(), phrases: [
            "Pause playback in \(.applicationName)"
        ], shortTitle: "Pause Playback", systemImageName: "pause.circle")
        AppShortcut(intent: NextMinidiscTrackIntent(), phrases: [
            "Next track in \(.applicationName)"
        ], shortTitle: "Next Track", systemImageName: "forward.end")
        AppShortcut(intent: PreviousMinidiscTrackIntent(), phrases: [
            "Previous track in \(.applicationName)"
        ], shortTitle: "Previous Track", systemImageName: "backward.end")
    }
}
