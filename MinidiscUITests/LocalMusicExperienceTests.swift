import XCTest

/// Run on a dedicated simulator without a configured server.
@MainActor
final class LocalMusicExperienceTests: XCTestCase {
    func testLocalOnboardingLibrarySearchAndSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let localChoice = app.buttons["onboarding.localFiles"]
        if localChoice.waitForExistence(timeout: 5) {
            capture(app, name: "Local-onboarding-choice")
            localChoice.tap()
            let add = app.buttons["localMusic.addFolder"]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            capture(app, name: "Local-onboarding-folders")
            add.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 30))
            cancel.tap()
            let open = app.buttons["onboarding.openLocalLibrary"]
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            open.tap()
        }

        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        XCTAssertTrue(app.tabBars.buttons["Discover"].exists)
        app.tabBars.buttons["Library"].tap()
        capture(app, name: "Local-library")
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Search your library"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for character in "Missing" { search.typeText(String(character)) }
        XCTAssertEqual(search.value as? String, "Missing")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 5))
        capture(app, name: "Local-search-empty")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.localFiles"].exists)
        app.tabBars.buttons["Home"].tap()
        app.buttons["Settings"].tap()
        let sources = app.buttons["settings.localMusic"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.connectServer"].exists)
        capture(app, name: "Local-settings-sources")
        app.buttons["Application"].tap()
        XCTAssertFalse(app.switches["offline-mode-toggle"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings.connectServer"].tap()
        XCTAssertTrue(app.textFields["https://music.example.com"].waitForExistence(timeout: 5))
        capture(app, name: "Local-connect-server-later")
    }

    /// Requires the synthetic Minidisc Test Music folder in the simulator's Files provider.
    func testImportMusicFolderAndPlayWithoutAServer() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if app.buttons["onboarding.localFiles"].waitForExistence(timeout: 5) {
            app.buttons["onboarding.localFiles"].tap()
            XCTAssertTrue(app.buttons["onboarding.openLocalLibrary"].waitForExistence(timeout: 5))
            app.buttons["onboarding.openLocalLibrary"].tap()
        }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.localMusic"].waitForExistence(timeout: 5))
        app.buttons["settings.localMusic"].tap()
        XCTAssertTrue(app.buttons["localMusic.addFolder"].waitForExistence(timeout: 5))
        app.buttons["localMusic.addFolder"].tap()
        XCTAssertTrue(app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].waitForExistence(timeout: 30))
        let folder = app.staticTexts["Minidisc Test Music"].firstMatch
        if !folder.exists {
            if app.buttons["Browse"].exists { app.buttons["Browse"].tap() }
            let onDevice = app.staticTexts["On My iPhone"].firstMatch
            XCTAssertTrue(onDevice.waitForExistence(timeout: 10))
            onDevice.tap()
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        capture(app, name: "Local-folder-picker")
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.navigationBars["Music Folders"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Close"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Songs"].waitForExistence(timeout: 15))
        capture(app, name: "Shared-library-with-local-music")
        app.buttons["Songs"].tap()
        XCTAssertTrue(app.staticTexts["Local First"].waitForExistence(timeout: 10))
        app.buttons["library.songs.shuffle"].tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["player.mini.title"].firstMatch.tap()
        let position = app.descendants(matching: .any).matching(identifier: "Playback position").firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        let before = position.value as? String
        try await Task.sleep(for: .seconds(2))
        XCTAssertNotEqual(position.value as? String, before, "Local audio must advance, not only display Pause.")
        capture(app, name: "Local-music-playing")
        app.buttons["player.moreOptions"].tap()
        XCTAssertTrue(app.buttons["player.goToAlbum"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add to Playlist..."].exists)
        app.buttons["player.goToAlbum"].tap()
        XCTAssertTrue(app.staticTexts["Unknown Album"].firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "Local-player-album")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Unknown Album"].firstMatch.waitForExistence(timeout: 10))
        capture(app, name: "Shared-home-with-local-music")
        let discover = app.tabBars.buttons["Discover"]
        discover.tap()
        // A minimized system tab bar may consume the first tap to expand.
        if !discover.isSelected { discover.tap() }
        let shuffle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Smart Shuffle")).firstMatch
        XCTAssertTrue(shuffle.waitForExistence(timeout: 10))
        shuffle.tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 10))
        capture(app, name: "Shared-discover-with-local-music")
        app.tabBars.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for character in "Local First" { search.typeText(String(character)) }
        XCTAssertTrue(app.staticTexts["Local First"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["search.scope.songs"].exists)
        capture(app, name: "Shared-search-with-local-music")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
