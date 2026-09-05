import XCTest

/// Uses only Scripts/Testing/ux-fixture-server.py on a disposable simulator.
/// Capture externally with simctl when a UX_STEP marker is emitted.
@MainActor
final class MinidiscUXVerificationTests: XCTestCase {
    private let app = XCUIApplication()
    private let firstTitle = "Matin tranquille"
    private let secondTitle = "Une très longue promenade au bord de la mer pour vérifier la lisibilité"

    func testLocalFixtureOnboarding() async throws {
        try await launchFixtureApp()
    }

    private func launchFixtureApp() async throws {
        try await requireLocalFixture()
        app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        app.launchEnvironment["no_proxy"] = "localhost,127.0.0.1"
        app.launchEnvironment["NO_PROXY"] = "localhost,127.0.0.1"
        app.launch()
        captureHierarchy("onboarding-before")
        if app.buttons["Commencer"].exists {
            try tap(app.buttons["Commencer"], named: "server-form")
            try enter("http://127.0.0.1:18992", into: app.textFields["https://music.example.com"])
            try enter("test", into: app.textFields["Nom d'utilisateur"])
            try enter("fixture-only", into: app.secureTextFields["Mot de passe"])
            try tap(app.buttons["Se connecter et enregistrer"], named: "connect")
        }
        // The system password sheet can cover the completion button. Dismiss it first.
        if app.buttons["Plus tard"].waitForExistence(timeout: 2) {
            try tap(app.buttons["Plus tard"], named: "dismiss-password-save")
        }
        if app.buttons["Commencer à écouter"].waitForExistence(timeout: 2) {
            try tap(app.buttons["Commencer à écouter"], named: "welcome-complete")
        }
        try require(app.tabBars.buttons["Accueil"], timeout: 10)
        if !app.tabBars.buttons["Accueil"].isSelected { try tapTab("Accueil") }
        // Only fixture-owned content is touched by subsequent steps.
        try require(app.staticTexts["Escapade temporaire"].firstMatch, timeout: 10)
        captureHierarchy("home-fixture-confirmed")
    }

    func testFixtureDownloadAndPlayback() async throws {
        try await launchFixtureApp()
        try await setFixtureState(["slow_stream": false, "removed": false, "fail_stream": false])
        try tap(app.staticTexts["Escapade temporaire"].firstMatch, named: "playlist")
        try require(app.staticTexts["Matin tranquille"].firstMatch, timeout: 10)
        if app.buttons["Retirer le téléchargement"].exists {
            try tap(app.buttons["Retirer le téléchargement"], named: "remove-fixture-download")
            try tap(app.alerts.buttons["Retirer"], named: "confirm-remove-fixture-download")
        }
        try playPlaylistFromBeginning()
        try require(app.buttons["Pause"].firstMatch, timeout: 8)
        XCTAssertEqual(try miniPlayerTitle().label, firstTitle)
        try tap(app.buttons["Pause"].firstMatch, named: "pause")
        XCTAssertFalse(app.buttons["Pause"].exists)
        try tap(app.buttons["Passer au suivant"], named: "next-paused")
        // Next is a new explicit playback command and starts the next track.
        try require(app.buttons["Pause"].firstMatch, timeout: 5)
        XCTAssertEqual(try miniPlayerTitle().label, secondTitle)
        XCTAssertFalse(app.staticTexts["Reconnexion…"].exists)
        captureHierarchy("next-starts-track-without-reconnection")
        try tap(app.buttons["Pause"].firstMatch, named: "pause-before-download")
        try await setFixtureState(["slow_stream": true])
        try tap(app.buttons["Télécharger la playlist"], named: "download-started")
        try tapTab("Bibliothèque")
        try require(app.navigationBars["Bibliothèque"], timeout: 4)
        try tap(app.buttons["Téléchargements"], named: "transfers")
        try require(app.progressIndicators["Progression du téléchargement"].firstMatch, timeout: 8)
        captureHierarchy("download-byte-progress-confirmed")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(app.buttons["Annuler le téléchargement"].firstMatch.waitForNonExistence(timeout: 25))
        captureHierarchy("download-completed")
        // The downloaded file must keep playing even when the fixture rejects streams.
        try await setFixtureState(["slow_stream": false, "fail_stream": true])
        try tapTab("Accueil")
        try require(app.staticTexts["Matin tranquille"].firstMatch, timeout: 5)
        try require(app.buttons["Retirer le téléchargement"], timeout: 5)
        try playPlaylistFromBeginning()
        try require(app.buttons["Pause"].firstMatch, timeout: 5)
        captureHierarchy("downloaded-playback-confirmed")
        try await Task.sleep(for: .seconds(2))
        let miniTitle = try miniPlayerTitle()
        captureHierarchy("before-full-player")
        miniTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try require(app.buttons["File d'attente"], timeout: 5)
        let position = app.descendants(matching: .any).matching(identifier: "Position de lecture").firstMatch
        try require(position)
        let before = try playbackSeconds(position)
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(try playbackSeconds(position), before, "The local audio playhead must advance.")
        captureHierarchy("downloaded-playhead-advances")
        try tap(app.buttons["Pause"].firstMatch, named: "full-player-pause")
        let paused = try playbackSeconds(position)
        try await Task.sleep(for: .seconds(2))
        XCTAssertLessThanOrEqual(abs(try playbackSeconds(position) - paused), 1)
        XCTAssertFalse(app.buttons["Pause"].exists)
        try tap(app.buttons["File d'attente"], named: "queue")
        try require(app.staticTexts[secondTitle].firstMatch, timeout: 5)
        XCTAssertFalse(app.staticTexts["À suivre"].exists)
        XCTAssertFalse(app.staticTexts["Up Next"].exists)
        XCTAssertFalse(app.staticTexts["Horizons de test"].exists)
        captureHierarchy("full-player-confirmed")
        try await Task.sleep(for: .seconds(3))
        try await setFixtureState(["fail_stream": false])
    }

    func testFixtureQueuePresentation() async throws {
        try await launchFixtureApp()
        try await setFixtureState(["slow_stream": false, "removed": false, "fail_stream": false])
        try tap(app.staticTexts["Escapade temporaire"].firstMatch, named: "playlist")
        try require(app.staticTexts[firstTitle].firstMatch)
        try playPlaylistFromBeginning()
        try require(app.buttons["Pause"].firstMatch)
        XCTAssertEqual(try miniPlayerTitle().label, firstTitle)
        let miniTitle = try miniPlayerTitle()
        captureHierarchy("before-full-player")
        miniTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try tap(app.buttons["File d'attente"], named: "queue")
        try require(app.staticTexts[secondTitle].firstMatch)
        XCTAssertFalse(app.staticTexts["Horizons de test"].exists)
        XCTAssertFalse(app.staticTexts["À suivre"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "up next")).firstMatch.exists)
        captureHierarchy("queue-without-heading-or-footer")
        try await Task.sleep(for: .seconds(3))
    }

    func testOnboardingAccessibilityXXXL() async throws {
        try await requireLocalFixture()
        app.launchArguments = [
            "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        guard app.buttons["Commencer"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Reinstall on the disposable simulator before checking welcome text at AX XXXL.")
        }
        captureHierarchy("onboarding-xxxl-top")
        try await Task.sleep(for: .seconds(2))
        let scroll = app.scrollViews.firstMatch
        try require(scroll)
        scroll.swipeUp()
        captureHierarchy("onboarding-xxxl-scrolled")
        XCTAssertTrue(app.buttons["Commencer"].isHittable)
        try await Task.sleep(for: .seconds(3))
    }

    private func playPlaylistFromBeginning() throws {
        // Both the playlist header and a restored mini-player expose "Lecture".
        // The header is the wide button; the mini-player only resumes its current item.
        let headerPlay = try XCTUnwrap(app.buttons.matching(identifier: "Lecture").allElementsBoundByIndex.first {
            $0.frame.width > 100 && $0.isHittable
        })
        captureHierarchy("before-play-playlist")
        headerPlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        captureHierarchy("play-playlist")
    }

    private func miniPlayerTitle() throws -> XCUIElement {
        try XCTUnwrap(app.staticTexts.allElementsBoundByIndex.filter {
            [firstTitle, secondTitle].contains($0.label)
        }.max { $0.frame.midY < $1.frame.midY })
    }

    private func playbackSeconds(_ element: XCUIElement) throws -> Int {
        let value = try XCTUnwrap(element.value as? String)
        let components = value.split(separator: ":").compactMap { Int($0) }
        guard components.count == 2 else {
            throw NSError(domain: "MinidiscUXVerification", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected playback position: \(value)"])
        }
        return components[0] * 60 + components[1]
    }

    private func tapTab(_ label: String) throws {
        let element = app.tabBars.buttons[label]
        try require(element)
        captureHierarchy("before-tab-\(label)")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        captureHierarchy("tab-\(label)")
    }

    private func setFixtureState(_ state: [String: Bool]) async throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18992/__state"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.httpBody = try JSONSerialization.data(withJSONObject: state)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Minidisc-UX-Fixture"), "1")
    }

    private func requireLocalFixture() async throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Minidisc UX Verification" else {
            throw XCTSkip("Run only on the disposable simulator named Minidisc UX Verification.")
        }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18992/__state"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
            ]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  response.value(forHTTPHeaderField: "X-Minidisc-UX-Fixture") == "1" else {
                throw XCTSkip("Start Scripts/Testing/ux-fixture-server.py before this scenario.")
            }
        } catch {
            throw XCTSkip("The disposable UX fixture is not running on this simulator host.")
        }
    }

    private func require(_ element: XCUIElement, timeout: TimeInterval = 5) throws {
        guard element.waitForExistence(timeout: timeout) else {
            captureHierarchy("missing-element")
            throw NSError(domain: "MinidiscUXVerification", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing UI element: \(element.description)"])
        }
    }

    private func enter(_ text: String, into element: XCUIElement) throws {
        try require(element)
        captureHierarchy("before-enter-field")
        element.tap()
        element.typeText(text)
        captureHierarchy("after-enter-field")
    }

    private func tap(_ element: XCUIElement, named name: String) throws {
        try require(element)
        captureHierarchy("before-\(name)")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        captureHierarchy(name)
    }

    private func captureHierarchy(_ name: String) {
        let description = app.debugDescription
        print("UX_STEP: \(name)")
        let hierarchy = XCTAttachment(string: description)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
