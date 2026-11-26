import CarPlay
import Observation
import OSLog

/// Owns only the car's templates and tasks. Audio remains owned by MinidiscRuntime.
@MainActor
final class CarPlayController: NSObject, CPNowPlayingTemplateObserver, CPTabBarTemplateDelegate {
    private let container: AppContainer
    private let library: CarPlayLibrary
    private let interface: CPInterfaceController
    private let home = CPListTemplate(title: String(localized: "Home"), sections: [])
    private let browse = CPListTemplate(title: String(localized: "Library"), sections: [])
    private let playlists = CPListTemplate(title: String(localized: "Playlists"), sections: [])
    private let queue = CPListTemplate(title: String(localized: "Queue"), sections: [])
    private var queueDetail: CPListTemplate?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var loads: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var loadIDs: [ObjectIdentifier: UUID] = [:]
    private var connected = false
    private var displayedContext: CarPlayContext?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Minidisc", category: "CarPlay")

    init(container: AppContainer, interface: CPInterfaceController) {
        self.container = container; self.interface = interface
        library = CarPlayLibrary(container: container)
    }

    func start() {
        connected = true
        for (template, symbol) in [(home, "house"), (browse, "music.note.house"),
                                    (playlists, "music.note.list"), (queue, "list.bullet")] {
            template.tabTitle = template.title
            template.tabImage = UIImage(systemName: symbol)
        }
        let tabs = CPTabBarTemplate(templates: [home, browse, playlists, queue])
        tabs.delegate = self
        interface.setRootTemplate(tabs, animated: false) { success, _ in
            if !success { Self.logger.error("CarPlay root template could not be installed") }
        }
        buildLibraryMenu()
        CPNowPlayingTemplate.shared.add(self)
        observePlayback()
        observeLibrary()
        refresh()
    }

    func stop() {
        connected = false
        for task in tasks.values { task.cancel() }
        for task in loads.values { task.cancel() }
        tasks.removeAll(); loads.removeAll(); loadIDs.removeAll()
        CPNowPlayingTemplate.shared.remove(self)
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = false
        CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = false
        // Do not pause or destroy the shared player when the cable is disconnected.
    }

    func refresh() {
        guard connected else { return }
        reloadLibrary()
        run { [container] in await container.localMusic.refresh() }
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        if selectedTemplate === home { load(.recent, into: home) }
        if selectedTemplate === playlists { load(.playlists, into: playlists) }
    }

    private func reloadLibrary() {
        guard connected else { return }
        if let displayedContext, displayedContext != library.context {
            for task in loads.values { task.cancel() }
            loads.removeAll()
            interface.popToRootTemplate(animated: false, completion: nil)
        }
        displayedContext = library.context
        load(.recent, into: home)
        load(.playlists, into: playlists)
    }

    private func observeLibrary() {
        guard connected else { return }
        withObservationTracking {
            _ = library.context
            _ = container.localMusic.snapshot
            _ = container.offlineLibrary.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connected else { return }
                self.reloadLibrary()
                self.observeLibrary()
            }
        }
    }

    private func observePlayback() {
        guard connected else { return }
        withObservationTracking {
            _ = container.playerState.queue
            _ = container.playerState.currentIndex
            _ = container.playerState.currentTrack
            _ = container.playerState.currentRadio
            _ = container.playerState.repeatMode
            _ = container.playerState.isShuffled
            _ = container.playerState.playbackState
            updateNowPlaying()
            renderQueue(queue)
            if let queueDetail { renderQueue(queueDetail) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePlayback() }
        }
    }

    private func buildLibraryMenu() {
        let routes: [(String, String, CarPlayRoute)] = [
            (String(localized: "Albums"), "square.stack", .albums),
            (String(localized: "Artists"), "person.2", .artists),
            (String(localized: "Songs"), "music.note", .songs),
            (String(localized: "Favorites"), "heart", .favorites)
        ]
        fill(browse, routes.map { title, symbol, route in
            item(title, symbol: symbol) { [weak self] in self?.open(route, title: title) }
        })
    }

    private func open(_ route: CarPlayRoute, title: String, context: CarPlayContext? = nil) {
        guard connected else { return }
        let expected = context ?? library.context
        guard (try? library.validate(expected)) != nil else { reloadLibrary(); return }
        let template = CPListTemplate(title: title, sections: [])
        push(template) { [weak self, weak template] success in
            guard let self, let template, self.connected, success else { return }
            guard (try? self.library.validate(expected)) != nil else { self.reloadLibrary(); return }
            self.load(route, into: template)
        }
    }

    private func load(_ route: CarPlayRoute, into template: CPListTemplate) {
        let key = ObjectIdentifier(template)
        loads[key]?.cancel()
        let loadID = UUID()
        loadIDs[key] = loadID
        template.trailingNavigationBarButtons = [CPBarButton(image: UIImage(systemName: "arrow.clockwise")!) { [weak self, weak template] _ in
            guard let self, let template else { return }
            self.load(route, into: template)
        }]
        fill(template, [message(String(localized: "Loading…"))])
        loads[key] = Task { [weak self, weak template] in
            guard let self, let template else { return }
            defer {
                if loadIDs[key] == loadID { loads[key] = nil; loadIDs[key] = nil }
            }
            do {
                let content = try await library.load(route, songLimit: CPListTemplate.maximumItemCount)
                try Task.checkCancellation()
                guard connected else { return }
                render(content, route: route, into: template)
                // Artwork never delays the list. Bound work on a mobile connection.
            } catch {
                guard connected, !UserFacingError.isCancellation(error) else { return }
                fill(template, [message(UserFacingError.from(error).displayMessage),
                                item(String(localized: "Retry"), symbol: "arrow.clockwise") { [weak self, weak template] in
                    guard let self, let template else { return }
                    self.load(route, into: template)
                }])
            }
        }
    }

    private func render(_ content: CarPlayContent, route: CarPlayRoute, into template: CPListTemplate, offset: Int = 0) {
        let limit = max(1, CPListTemplate.maximumItemCount)
        let capacity = max(1, limit - 5) // playback actions, notice and both page controls
        var rows: [CPListItem] = []
        if template === home {
            rows.append(item("Smart Shuffle", symbol: "sparkles") { [weak self] in
                guard let self else { return }
                try await self.container.playerService.playSmartShuffle()
                self.showNowPlaying()
            })
        }
        if content.showingOfflineFallback {
            rows.append(message(String(localized: "Server unavailable. Showing music on this iPhone.", table: "CarPlay")))
        }
        if !content.songs.isEmpty {
            rows.append(item(String(localized: "Play All", table: "CarPlay"), symbol: "play.fill") { [weak self] in
                try await self?.play(content, index: 0)
            })
            rows.append(item(String(localized: "Shuffle"), symbol: "shuffle") { [weak self] in
                try await self?.play(content, index: 0, shuffled: true)
            })
        }
        let count = content.collections.count + content.songs.count
        let start = min(max(0, offset), max(0, count - 1))
        if start > 0 {
            rows.append(item(String(localized: "Previous page", table: "CarPlay"), symbol: "chevron.left") { [weak self, weak template] in
                guard let self, let template else { return }
                self.render(content, route: route, into: template, offset: max(0, start - capacity))
            })
        } else if let previousPage = content.previousPage {
            rows.append(item(String(localized: "Previous page", table: "CarPlay"), symbol: "chevron.left") { [weak self, weak template] in
                guard let self, let template else { return }
                self.load(previousPage, into: template)
            })
        }
        var artwork: [(CPListItem, String)] = []
        for index in start..<min(count, start + capacity) {
            if index < content.collections.count {
                let collection = content.collections[index]
                let row = item(collection.title, detail: collection.subtitle, symbol: "square.stack") { [weak self] in
                    self?.open(collection.route, title: collection.title, context: content.context)
                }
                row.accessoryType = .disclosureIndicator
                rows.append(row)
                if let id = collection.artworkID { artwork.append((row, id)) }
            } else {
                let songIndex = index - content.collections.count
                let song = content.songs[songIndex]
                let row = item(song.title, detail: song.artist, symbol: "music.note") { [weak self] in
                    try await self?.play(content, index: songIndex)
                }
                rows.append(row)
                if let id = song.coverArtId { artwork.append((row, id)) }
            }
        }
        if start + capacity < count {
            rows.append(item(String(localized: "Next page", table: "CarPlay"), symbol: "chevron.right") { [weak self, weak template] in
                guard let self, let template else { return }
                self.render(content, route: route, into: template, offset: start + capacity)
            })
        } else if let nextPage = content.nextPage {
            rows.append(item(String(localized: "Next page", table: "CarPlay"), symbol: "chevron.right") { [weak self, weak template] in
                guard let self, let template else { return }
                self.load(nextPage, into: template)
            })
        }
        if count == 0 {
            let text = content.context.serverID == nil
                ? String(localized: "Add music or connect a server in Minidisc on your iPhone.", table: "CarPlay")
                : String(localized: "No music available here.", table: "CarPlay")
            rows.append(message(text))
        }
        fill(template, Array(rows.prefix(limit)))
        run { [weak self] in
            guard let self else { return }
            for (row, id) in artwork.prefix(24) {
                try self.library.validate(content.context)
                let cache = self.container.artworkImageCache
                let image: UIImage?
                if content.context.access.isOnline || id.hasPrefix("local:") {
                    image = await cache.load(coverArtId: id, tier: .thumb)
                } else {
                    image = await cache.loadCached(coverArtId: id, tier: .thumb)
                }
                try self.library.validate(content.context)
                guard self.connected else { return }
                if let image { row.setImage(image) }
            }
        }
    }

    private func play(_ content: CarPlayContent, index: Int, shuffled: Bool = false) async throws {
        let library = library
        try await container.playerService.play(preparingQueue: {
            try await library.preparePlayback(content, index: index, shuffled: shuffled)
        })
        guard connected, !Task.isCancelled else { return }
        showNowPlaying()
    }

    private func renderQueue(_ template: CPListTemplate) {
        let state = container.playerState
        guard state.currentRadio == nil, !state.queue.isEmpty else {
            fill(template, [message(String(localized: "No tracks in the queue.", table: "CarPlay"))])
            return
        }
        // Keep the playing item and upcoming tracks accessible even in a very large queue.
        let start = max(0, min(state.currentIndex, state.queue.count - 1))
        let end = min(state.queue.count, start + CPListTemplate.maximumItemCount)
        let rows = (start..<end).map { index in
            let track = state.queue[index]
            let selection = QueueTrackSelection(playerState: state, destinationIndex: index, destinationTrackID: track.id)
            let generation = state.queueGeneration
            let revision = state.queueRevision
            let row = item(track.title, detail: track.artist, symbol: "music.note") { [weak self] in
                guard let self else { return }
                if let selection {
                    guard try await self.container.playerService.selectQueueTrack(selection) else { return }
                } else {
                    let current = self.container.playerState
                    guard current.queueGeneration == generation, current.queueRevision == revision,
                          current.currentIndex == index, current.currentTrack?.id == track.id else { return }
                }
                self.showNowPlaying()
            }
            row.isPlaying = index == state.currentIndex && state.currentTrack?.id == track.id
            row.playingIndicatorLocation = .trailing
            return row
        }
        fill(template, rows)
    }

    private func updateNowPlaying() {
        let state = container.playerState
        let now = CPNowPlayingTemplate.shared
        now.isUpNextButtonEnabled = state.currentRadio == nil && !state.queue.isEmpty
        now.upNextTitle = String(localized: "Queue")
        now.isAlbumArtistButtonEnabled = state.currentRadio == nil &&
            (state.currentTrack?.albumId != nil || state.currentTrack?.isLocalFile == true)
        let shuffle = CPNowPlayingImageButton(image: UIImage(systemName: "shuffle")!) { [weak self] _ in
            self?.run { [weak self] in await self?.container.playerService.toggleShuffle() }
        }
        let repeatButton = CPNowPlayingImageButton(image: UIImage(systemName: state.repeatMode.systemImage)!) { [weak self] _ in
            self?.run { [weak self] in
                guard let self else { return }
                await self.container.playerService.setRepeatMode(self.container.playerState.repeatMode.next)
            }
        }
        shuffle.isEnabled = now.isUpNextButtonEnabled
        repeatButton.isEnabled = now.isUpNextButtonEnabled
        shuffle.isSelected = state.isShuffled
        repeatButton.isSelected = state.repeatMode != .off
        now.updateNowPlayingButtons([shuffle, repeatButton])
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        let detail = CPListTemplate(title: String(localized: "Queue"), sections: [])
        queueDetail = detail
        renderQueue(detail)
        push(detail)
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let track = container.playerState.currentTrack else { return }
        if let destination = LocalMusicDestination(track: track, category: .albums) {
            open(.album(LocalMusicCatalog.collectionID(.albums, key: destination.key)), title: track.albumName ?? String(localized: "Albums"))
        } else if let id = track.albumId {
            open(.album(id), title: track.albumName ?? String(localized: "Albums"))
        }
    }

    private func showNowPlaying() {
        guard connected, interface.topTemplate !== CPNowPlayingTemplate.shared else { return }
        if interface.templates.contains(where: { $0 === CPNowPlayingTemplate.shared }) {
            interface.pop(to: CPNowPlayingTemplate.shared, animated: true, completion: nil)
        } else {
            push(CPNowPlayingTemplate.shared)
        }
    }

    private func push(_ template: CPTemplate, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard connected else { completion(false); return }
        // Audio apps may stack at most five templates. Deep artist navigation must still
        // allow opening Now Playing and its queue without a rejected sixth template.
        if interface.templates.count >= 5 {
            interface.popToRootTemplate(animated: false) { [weak self] success, _ in
                guard let self, self.connected, success else { completion(false); return }
                self.interface.pushTemplate(template, animated: true) { success, _ in completion(success) }
            }
        } else {
            interface.pushTemplate(template, animated: true) { success, _ in completion(success) }
        }
    }

    private func item(_ title: String, detail: String? = nil, symbol: String,
                      action: @escaping @MainActor () async throws -> Void) -> CPListItem {
        let row = CPListItem(text: title, detailText: detail, image: UIImage(systemName: symbol))
        row.handler = { [weak self] _, completion in
            completion()
            self?.run(action)
        }
        return row
    }

    private func message(_ text: String) -> CPListItem {
        let row = CPListItem(text: text, detailText: nil)
        row.isEnabled = false
        return row
    }

    private func fill(_ template: CPListTemplate, _ rows: [CPListItem]) {
        template.updateSections([CPListSection(items: rows)])
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard connected else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[id] = nil }
            do { try await action() }
            catch {
                guard connected, !UserFacingError.isCancellation(error), interface.presentedTemplate == nil else { return }
                let dismiss = CPAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
                    self?.interface.dismissTemplate(animated: true, completion: nil)
                }
                interface.presentTemplate(CPAlertTemplate(titleVariants: [UserFacingError.from(error).displayMessage],
                                                         actions: [dismiss]), animated: true, completion: nil)
            }
        }
    }
}
