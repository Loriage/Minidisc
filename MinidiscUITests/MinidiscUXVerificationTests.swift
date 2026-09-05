import XCTest

/// Uses only Scripts/Testing/ux-fixture-server.py on a disposable simulator.
/// Capture externally with simctl when a UX_STEP marker is emitted.
@MainActor
final class MinidiscUXVerificationTests: XCTestCase {
    private let app = XCUIApplication()
    private let firstTitle = "Matin tranquille"
    private let secondTitle = "Une très longue promenade au bord de la mer pour vérifier la lisibilité"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLocalFixtureOnboarding() async throws {
        try await launchFixtureApp()
    }

    private func launchFixtureApp(searchCatalog: Bool = false, queueCatalog: Bool = false, homeCatalog: Bool = false, contentSize: String? = nil) async throws {
        try await requireLocalFixture()
        try await setFixtureState([
            "search_catalog": searchCatalog, "queue_catalog": queueCatalog, "home_catalog": homeCatalog,
            "reset_playlists": true, "removed": false,
            "fail_stream": false, "slow_stream": false
        ])
        app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launchEnvironment["no_proxy"] = "localhost,127.0.0.1"
        app.launchEnvironment["NO_PROXY"] = "localhost,127.0.0.1"
        app.launch()
        captureHierarchy("onboarding-before")
        if app.buttons["Commencer"].exists {
            try tap(app.buttons["Commencer"], named: "server-form")
            try enter("http://127.0.0.1:18992", into: app.textFields["https://music.example.com"])
            try enter("test", into: app.textFields["Nom d'utilisateur"])
            try enter("fixture-only", into: app.secureTextFields["Mot de passe"])
            let connect = app.buttons["Se connecter et enregistrer"]
            try require(connect)
            if app.keyboards.firstMatch.exists {
                // Coordinate taps must not hit a keyboard covering the form button.
                let form = app.collectionViews.containing(.button, identifier: "Se connecter et enregistrer").firstMatch
                try require(form)
                captureHierarchy("before-connect-form-scroll")
                let top = app.navigationBars["Ajouter un serveur"].frame.maxY
                let bottom = min(form.frame.maxY, app.keyboards.firstMatch.frame.minY - 44)
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: form.frame.midX, dy: bottom - 24))
                let end = origin.withOffset(CGVector(dx: form.frame.midX, dy: top + 40))
                start.press(forDuration: 0.05, thenDragTo: end)
                captureHierarchy("connect-form-scrolled")
            }
            guard connect.isHittable,
                  !app.keyboards.firstMatch.exists || connect.frame.maxY < app.keyboards.firstMatch.frame.minY else {
                throw NSError(domain: "MinidiscUXVerification", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Connect button is still covered after scrolling the form."])
            }
            try tap(connect, named: "connect")
        }
        if app.buttons["Commencer à écouter"].waitForExistence(timeout: 3) {
            // The system password sheet arrives with the completion transition.
            // Check after that transition so the button is not tapped through it.
            if app.buttons["Plus tard"].waitForExistence(timeout: 2) {
                try tap(app.buttons["Plus tard"], named: "dismiss-password-save")
            }
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

    func testFixtureQueueRemovalUndo() async throws {
        let expected = try await openEditableFixtureQueue()
        for id in expected { try require(searchElement(id)) }
        XCTAssertEqual(orderedQueueIdentifiers(), expected)
        let position = searchElement("Position de lecture")
        try require(position)
        let before = try playbackSeconds(position)
        captureHierarchy("queue-edit-original-order")
        try await Task.sleep(for: .seconds(2))

        let removed = queueCell(expected[1])
        captureHierarchy("queue-edit-before-swipe")
        removed.swipeLeft()
        try tap(app.buttons["Retirer de la file d'attente"], named: "queue-edit-remove")
        XCTAssertFalse(removed.exists)
        XCTAssertEqual(orderedQueueIdentifiers(), [expected[0], expected[2]])
        XCTAssertTrue(app.buttons["Pause"].firstMatch.exists)
        captureHierarchy("queue-edit-removed")

        // The toast's whole 44-point-or-larger button is the Undo action.
        let undo = try XCTUnwrap(app.buttons.matching(identifier: "toast.undoQueue").allElementsBoundByIndex.last { $0.isHittable })
        try tap(undo, named: "queue-edit-undo")
        try require(searchElement(expected[1]))
        XCTAssertEqual(orderedQueueIdentifiers(), expected, "Undo must restore the exact position between its neighbours.")
        XCTAssertTrue(app.staticTexts.matching(identifier: firstTitle).allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertTrue(app.buttons["Pause"].firstMatch.exists)
        XCTAssertGreaterThan(try playbackSeconds(position), before, "Editing future tracks must keep the current audio advancing.")
        captureHierarchy("queue-edit-restored-order-and-playback")
        try await Task.sleep(for: .seconds(2))
        try tap(app.buttons["Pause"].firstMatch, named: "queue-undo-finished")
    }

    func testFixtureQueueReorderAndSave() async throws {
        let expected = try await openEditableFixtureQueue()
        let sourceHandle = queueCell(expected[2]).images["Réorganiser"]
        let targetHandle = queueCell(expected[1]).images["Réorganiser"]
        try require(sourceHandle)
        try require(targetHandle)
        captureHierarchy("queue-edit-before-native-reorder")
        sourceHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: targetHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        captureHierarchy("queue-edit-after-native-reorder")
        let reordered = [expected[0], expected[2], expected[1]]
        guard orderedQueueIdentifiers() == reordered else {
            throw NSError(domain: "MinidiscUXVerification", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Native drag did not produce the expected queue order."])
        }
        XCTAssertTrue(app.buttons["Pause"].firstMatch.exists)
        captureHierarchy("queue-edit-native-reorder-confirmed")
        try await Task.sleep(for: .seconds(2))
        try tap(app.buttons["Pause"].firstMatch, named: "queue-edit-finished")

        let menu = try XCTUnwrap(app.buttons.matching(identifier: "Plus d'options").allElementsBoundByIndex.first {
            $0.frame.width >= 44 && $0.isHittable
        })
        try tap(menu, named: "queue-save-menu")
        try tap(app.buttons["queue.savePlaylist"], named: "queue-save-direct-name-form")
        let name = app.textFields["playlist.new.name"]
        try enter("File UX", into: name)
        XCTAssertEqual(name.value as? String, "File UX")
        captureHierarchy("queue-save-four-tracks-confirmed")
        try await Task.sleep(for: .seconds(2))
        try tap(app.buttons["playlist.new.save"], named: "queue-save-playlist")
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))
        let mutations = try await fixtureMutations()
        let creation = try XCTUnwrap(mutations.first { $0.endpoint == "createPlaylist" })
        let addition = try XCTUnwrap(mutations.last { $0.endpoint == "updatePlaylist" })
        XCTAssertEqual(creation.name, "File UX")
        XCTAssertEqual(addition.playlistId, creation.playlistId)
        XCTAssertEqual(addition.songIds, ["ux-song-1", "ux-song-2", "ux-search-song-exact", "ux-search-song-prefix"])
        captureHierarchy("queue-save-playlist-order-persisted")
        try await Task.sleep(for: .seconds(2))
    }

    private func openEditableFixtureQueue() async throws -> [String] {
        try await launchFixtureApp(queueCatalog: true)
        try tap(app.staticTexts["Escapade temporaire"].firstMatch, named: "queue-edit-playlist")
        try require(app.staticTexts["Aurore au piano"].firstMatch)
        try playPlaylistFromBeginning()
        try require(app.buttons["Pause"].firstMatch)
        XCTAssertEqual(try miniPlayerTitle().label, firstTitle)
        let miniTitle = try miniPlayerTitle()
        captureHierarchy("queue-edit-before-full-player")
        miniTitle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try tap(app.buttons["File d'attente"], named: "queue-edit-open")

        let expected = ["queue.track.ux-song-2.0", "queue.track.ux-search-song-prefix.0", "queue.track.ux-search-song-exact.0"]
        for id in expected { try require(searchElement(id)) }
        XCTAssertEqual(orderedQueueIdentifiers(), expected)
        return expected
    }

    private func queueCell(_ identifier: String) -> XCUIElement {
        app.cells.containing(.any, identifier: identifier).firstMatch
    }

    private func orderedQueueIdentifiers() -> [String] {
        let texts = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue.track."))
            .allElementsBoundByIndex
        var seen = Set<String>()
        let rows = texts.compactMap { row -> (String, CGFloat)? in
            let identifier = row.identifier
            return seen.insert(identifier).inserted ? (identifier, row.frame.minY) : nil
        }
        return rows.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    func testFixtureSearchRankingAndFilters() async throws {
        try await launchFixtureApp(searchCatalog: true)
        try tapTab("Recherche")
        try submitSearch("aurore")

        // The fixture returns the prefix song first; the exact song must win the top slot.
        let exactSong = "song:ux-search-song-exact"
        let prefixSong = "song:ux-search-song-prefix"
        try assertTopSearchResult(id: exactSong, title: "Aurore")
        XCTAssertFalse(searchElement("search.result.\(exactSong)").exists,
                       "The top result must not be duplicated in its ordinary section.")
        captureHierarchy("search-top-exact-song")
        try await Task.sleep(for: .seconds(2))

        let expected: [(scope: String, ids: Set<String>)] = [
            ("songs", [exactSong, prefixSong]),
            ("albums", ["album:ux-search-album"]),
            ("artists", ["artist:ux-search-artist"]),
            ("playlists", ["playlist:ux-search-playlist"])
        ]
        for item in expected {
            try selectSearchScope(item.scope)
            for id in item.ids { try require(searchElement("search.result.\(id)")) }
            XCTAssertEqual(searchResultIdentifiers(prefix: "search.result."),
                           Set(item.ids.map { "search.result.\($0)" }),
                           "Each filter must expose exactly its fixture records, without another result type.")
            XCTAssertTrue(searchResultIdentifiers(prefix: "search.topResult.").isEmpty)
            captureHierarchy("search-filter-\(item.scope)")
            try await Task.sleep(for: .seconds(2))
        }
        try selectSearchScope("all")
        try assertTopSearchResult(id: exactSong, title: "Aurore")
        captureHierarchy("search-all-restored")
        try await Task.sleep(for: .seconds(2))
    }

    func testFixtureSearchPlaylistNavigation() async throws {
        try await launchFixtureApp(searchCatalog: true)
        try tapTab("Recherche")
        try submitSearch("Aurore du dimanche")
        let playlistID = "playlist:ux-search-playlist"
        try assertTopSearchResult(id: playlistID, title: "Aurore du dimanche")
        captureHierarchy("search-top-exact-playlist")
        try await Task.sleep(for: .seconds(2))
        try tap(searchElement("search.topResult.\(playlistID)"), named: "search-open-playlist")
        // The destination must contain this playlist's two songs and its own actions.
        try require(app.buttons["Télécharger la playlist"])
        try require(app.staticTexts["Aurore du dimanche"].firstMatch)
        try require(app.staticTexts["Aurore au piano"].firstMatch)
        try require(app.staticTexts["Aurore"].firstMatch)
        captureHierarchy("search-playlist-destination-confirmed")
        try await Task.sleep(for: .seconds(2))
        try tap(app.buttons["Retour"].firstMatch, named: "search-back-from-playlist")
        try assertTopSearchResult(id: playlistID, title: "Aurore du dimanche")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Aurore du dimanche")
        captureHierarchy("search-query-preserved-after-navigation")
        try await Task.sleep(for: .seconds(2))
    }

    func testFixtureGroupedAdditionToExistingPlaylist() async throws {
        try await launchFixtureApp(searchCatalog: true)
        try openAuroreSelection()
        try submitSearch("Escapade")
        let destination = app.buttons["playlist.destination.ux-playlist"]
        try require(destination)
        XCTAssertFalse(app.buttons["playlist.destination.ux-search-playlist"].exists)
        captureHierarchy("playlist-destination-search-confirmed")
        try await Task.sleep(for: .seconds(2))
        try tap(destination, named: "playlist-add-selection-existing")
        XCTAssertTrue(destination.waitForNonExistence(timeout: 8))
        let mutations = try await fixtureMutations()
        let addition = try XCTUnwrap(mutations.last { $0.endpoint == "updatePlaylist" })
        XCTAssertEqual(addition.playlistId, "ux-playlist")
        XCTAssertEqual(addition.songIds, ["ux-song-1", "ux-song-2", "ux-search-song-exact", "ux-search-song-prefix"],
                       "The two selected songs must be appended once, in displayed search order.")
        captureHierarchy("playlist-grouped-addition-persisted")
        try await Task.sleep(for: .seconds(2))
    }

    func testFixtureGroupedAdditionToNewPlaylist() async throws {
        try await launchFixtureApp(searchCatalog: true)
        try openAuroreSelection()
        try tap(app.buttons["playlist.destination.new"], named: "playlist-new-form")
        let name = app.textFields["playlist.new.name"]
        try enter("Aurore UX", into: name)
        XCTAssertEqual(name.value as? String, "Aurore UX")
        captureHierarchy("playlist-new-selection-confirmed")
        try await Task.sleep(for: .seconds(2))
        try tap(app.buttons["playlist.new.save"], named: "playlist-new-save")
        XCTAssertTrue(name.waitForNonExistence(timeout: 8))
        let mutations = try await fixtureMutations()
        let creation = try XCTUnwrap(mutations.first { $0.endpoint == "createPlaylist" })
        let addition = try XCTUnwrap(mutations.last { $0.endpoint == "updatePlaylist" })
        XCTAssertEqual(creation.name, "Aurore UX")
        XCTAssertEqual(addition.playlistId, creation.playlistId)
        XCTAssertEqual(addition.songIds, ["ux-search-song-exact", "ux-search-song-prefix"])
        let result = searchElement("search.result.playlist:\(creation.playlistId)")
        try require(result, timeout: 8)
        XCTAssertTrue(result.label.contains("Aurore UX") || result.staticTexts["Aurore UX"].exists)
        captureHierarchy("playlist-new-grouped-addition-persisted")
        try await Task.sleep(for: .seconds(2))
    }

    private func openAuroreSelection() throws {
        try tapTab("Recherche")
        try submitSearch("aurore")
        try assertTopSearchResult(id: "song:ux-search-song-exact", title: "Aurore")
        try tap(app.buttons["search.selectSongs"], named: "playlist-song-selection")
        let exact = app.buttons["songs.selection.ux-search-song-exact"]
        let prefix = app.buttons["songs.selection.ux-search-song-prefix"]
        // Select in reverse order; committing must still follow the displayed collection order.
        XCTAssertTrue(app.buttons["Tout sélectionner"].exists)
        try tap(prefix, named: "playlist-select-prefix")
        try tap(exact, named: "playlist-select-exact")
        XCTAssertTrue(prefix.isSelected)
        XCTAssertTrue(exact.isSelected)
        XCTAssertTrue(app.buttons["Tout désélectionner"].exists)
        XCTAssertTrue(app.buttons["songs.selection.add"].isEnabled)
        captureHierarchy("playlist-two-songs-selected")
        try tap(app.buttons["songs.selection.add"], named: "playlist-destinations")
        try require(app.buttons["playlist.destination.new"])
    }

    func testFixturePersonalHome() async throws {
        try await launchFixtureApp(homeCatalog: true)
        let favoriteSongs = searchElement("home.favoriteSongs")
        try scrollHomeTo(favoriteSongs, named: "home-favorite-songs")
        let favorite = app.buttons.matching(identifier: "home.favoriteSongs").allElementsBoundByIndex.first {
            $0.label == "Aurore, Aurore Ensemble" && $0.isHittable
        }
        try tap(try XCTUnwrap(favorite), named: "home-play-favorite")
        let resume = app.buttons["home.resume.playPause"]
        try require(resume)
        try scrollHomeTo(resume, named: "home-resume-card")
        XCTAssertEqual(resume.label, "Pause")
        try tap(resume, named: "home-resume-pause")
        XCTAssertEqual(resume.label, "Reprendre")
        try tap(resume, named: "home-resume-start")
        XCTAssertEqual(resume.label, "Pause")
        try tap(app.buttons["home.resume.open"], named: "home-open-current-player")
        let position = searchElement("Position de lecture")
        try require(position)
        let before = try playbackSeconds(position)
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(try playbackSeconds(position), before)
        try tap(app.buttons["Pause"].firstMatch, named: "home-player-paused")
        try tap(app.buttons["Fermer le lecteur"], named: "home-return-from-player")
        captureHierarchy("home-resume-functional")
        try await Task.sleep(for: .seconds(2))

        let sections = [
            ("home.favoriteAlbums", "Horizons de test"),
            ("home.recentlyPlayed", "Aurore — Sessions"),
            ("home.heavyRotation", "Écoute familière 01"),
            ("home.rediscover", "Écoute familière 13"),
            ("home.relevantAdditions", "Aurore — Sessions"),
            ("home.recentlyAdded", "Rives")
        ]
        for (identifier, title) in sections {
            let shelf = app.scrollViews.matching(identifier: identifier).firstMatch
            try require(shelf)
            let record = shelf.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
            try require(record)
            try scrollHomeTo(record, named: identifier)
            captureHierarchy(identifier + "-confirmed")
            try await Task.sleep(for: .seconds(2))
        }
        let recentShelf = app.scrollViews.matching(identifier: "home.recentlyAdded").firstMatch
        try tap(recentShelf.buttons["Rives, Ensemble des rives"], named: "home-open-new-album")
        try require(app.staticTexts["Rivière"].firstMatch)
        try require(app.staticTexts["Reflets"].firstMatch)
        captureHierarchy("home-new-album-navigation-confirmed")
        try await Task.sleep(for: .seconds(2))
    }

    func testFixtureHomeLargeText() async throws {
        try await launchFixtureApp(homeCatalog: true, contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        captureHierarchy("home-large-text-top")
        try await Task.sleep(for: .seconds(3))
        let favoriteShelf = app.scrollViews.matching(identifier: "home.favoriteAlbums").firstMatch
        try scrollHomeTo(favoriteShelf.buttons["Horizons de test, Atelier Minidisc"], named: "home-large-album-card")
        captureHierarchy("home-large-text-album-card")
        try await Task.sleep(for: .seconds(3))
        try scrollHomeTo(searchElement("home.relevantAdditions"), named: "home-large-relevant-additions")
        captureHierarchy("home-large-text-relevant-additions")
        try await Task.sleep(for: .seconds(3))
        // Launch arguments are per run: also inspect the compact player at ordinary text size.
        try await launchFixtureApp(homeCatalog: true)
        try scrollHomeTo(searchElement("home.relevantAdditions"), named: "home-normal-relevant-additions")
        captureHierarchy("home-normal-player-and-relevant-additions")
        try await Task.sleep(for: .seconds(3))
    }

    private func scrollHomeTo(_ element: XCUIElement, named name: String) throws {
        try require(element)
        let scroll = app.scrollViews.firstMatch
        try require(scroll)
        for _ in 0..<6 {
            let frame = element.frame
            if frame.minY >= 120 && frame.maxY <= app.frame.maxY - 110 && element.isHittable { return }
            captureHierarchy("before-scroll-" + name)
            if frame.midY > app.frame.midY { scroll.swipeUp() } else { scroll.swipeDown() }
            captureHierarchy("after-scroll-" + name)
        }
        guard element.frame.intersects(app.frame), element.isHittable else {
            throw NSError(domain: "MinidiscUXVerification", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Home element is not visible after bounded scrolling: \(name)"])
        }
    }

    private struct FixtureMutation: Decodable {
        let endpoint: String
        let playlistId: String
        let songIds: [String]?
        let name: String?
    }

    private func fixtureMutations() async throws -> [FixtureMutation] {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18992/__mutations"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Minidisc-UX-Fixture"), "1")
        return try JSONDecoder().decode([FixtureMutation].self, from: data)
    }

    private func searchElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func searchResultIdentifiers(prefix: String) -> Set<String> {
        Set(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex.map(\.identifier))
    }

    private func assertTopSearchResult(id: String, title: String) throws {
        let identifier = "search.topResult.\(id)"
        let result = searchElement(identifier)
        try require(result, timeout: 8)
        XCTAssertEqual(searchResultIdentifiers(prefix: "search.topResult."), Set([identifier]))
        let exactTitle = result.descendants(matching: .staticText).matching(identifier: title).firstMatch
        XCTAssertTrue(exactTitle.exists || result.label == title,
                      "The top row must carry the expected record's exact title, as well as its type and ID.")
    }

    private func submitSearch(_ query: String) throws {
        if !app.searchFields.firstMatch.waitForExistence(timeout: 1) {
            // Search history can restore with the navigation search drawer collapsed.
            let list = app.collectionViews.firstMatch
            try require(list)
            captureHierarchy("search-before-reveal-field")
            list.swipeDown()
            captureHierarchy("search-after-reveal-field")
        }
        try require(app.searchFields.firstMatch)
        let field = try XCTUnwrap(app.searchFields.allElementsBoundByIndex.first { $0.isHittable },
                                  "The active sheet or tab must expose a hittable search field.")
        captureHierarchy("search-before-query")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if field.buttons.firstMatch.exists {
            try tap(field.buttons.firstMatch, named: "search-clear-query")
        }
        // The iOS 27 simulator can lose synthetic keystrokes during live result updates.
        // Send bounded individual keys and verify the actual query before testing ranking.
        for character in query { field.typeText(String(character)) }
        XCTAssertEqual(field.value as? String, query, "The entered query must be exact before evaluating its results.")
        field.typeText("\n")
        captureHierarchy("search-query-submitted")
    }

    private func selectSearchScope(_ scope: String) throws {
        let button = app.buttons["search.scope.\(scope)"]
        try require(button)
        captureHierarchy("search-before-scope-\(scope)")
        if button.frame.minX < app.frame.minX || button.frame.maxX > app.frame.maxX || !button.isHittable {
            let bar = app.scrollViews.containing(.button, identifier: "search.scope.all").firstMatch
            try require(bar)
            if button.frame.midX > app.frame.midX { bar.swipeLeft() } else { bar.swipeRight() }
            captureHierarchy("search-scope-scroll-\(scope)")
        }
        try tap(button, named: "search-scope-\(scope)")
        XCTAssertTrue(button.isSelected)
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
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Minidisc-UX-Fixture"), "1")
        let appliedState = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        for (key, value) in state { XCTAssertEqual(appliedState[key], value) }
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
        guard element.exists || element.waitForExistence(timeout: timeout) else {
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
