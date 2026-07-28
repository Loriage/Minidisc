import Testing
import Foundation
@testable import Minidisc

@Suite("LidarrQueueItem — queue payload")
struct LidarrQueueItemTests {

    private func item(_ fields: String) throws -> LidarrQueueItem {
        let json = "{ \"id\": 1, \(fields) }"
        return try JSONDecoder().decode(LidarrQueueItem.self, from: Data(json.utf8))
    }

    // MARK: - State

    /// Every value Lidarr can put in `status` before the download completes: `DownloadItemStatus`, plus
    /// the `PendingReleaseReason` it uses for releases it is holding back.
    static let clientStatuses: [(status: String, state: LidarrQueueState)] = [
        ("queued", .queued),
        ("delay", .queued),
        ("downloadClientUnavailable", .queued),
        ("fallback", .queued),
        ("paused", .paused),
        ("downloading", .downloading),
        ("failed", .downloadFailed),
        ("warning", .warning),
    ]

    @Test("the download client's status decides the state until it completes", arguments: clientStatuses)
    func stateFollowsClientStatus(status: String, state: LidarrQueueState) throws {
        #expect(try item("\"status\": \"\(status)\"").state == state)
    }

    /// Every value of Lidarr's `TrackedDownloadState`, which names two of its cases differently from
    /// Sonarr and Radarr (`downloadFailed`/`importFailed` rather than `failed`).
    static let trackedStates: [(tracked: String, state: LidarrQueueState)] = [
        ("downloading", .downloading),
        ("downloadFailed", .downloadFailed),
        ("downloadFailedPending", .downloadFailed),
        ("importPending", .importPending),
        ("importBlocked", .importBlocked),
        ("importFailed", .importFailed),
        ("importing", .importing),
        ("imported", .imported),
        ("ignored", .ignored),
    ]

    @Test("once completed, the tracked state decides", arguments: trackedStates)
    func stateFollowsTrackedState(tracked: String, state: LidarrQueueState) throws {
        let queued = try item("\"status\": \"completed\", \"trackedDownloadState\": \"\(tracked)\"")
        #expect(queued.state == state)
    }

    @Test("an import left pending with a warning is blocked, the way older Lidarr reports it")
    func warnedImportPendingIsBlocked() throws {
        let queued = try item("""
            "status": "completed",
            "trackedDownloadStatus": "warning", "trackedDownloadState": "importPending"
        """)
        #expect(queued.state == .importBlocked)
        #expect(queued.hasIssue)
    }

    @Test("a state or status from a newer Lidarr degrades instead of lying")
    func unknownValuesDegrade() throws {
        #expect(try item("\"status\": \"somethingNew\"").state == .unknown)
        #expect(try item("\"title\": \"No status at all\"").state == .unknown)
        // A completed download Lidarr has not picked up yet is still, as far as it is concerned, downloading.
        #expect(try item("\"status\": \"completed\", \"trackedDownloadState\": \"alsoNew\"").state == .downloading)
    }

    @Test("only the states the user has to act on count as issues")
    func problemStatesAreFlagged() {
        let problems: Set<LidarrQueueState> = [.downloadFailed, .importBlocked, .importFailed, .warning]
        for state in problems { #expect(state.isProblem, "\(state) should be a problem") }
        let fine: [LidarrQueueState] = [.queued, .paused, .downloading, .importPending, .importing, .imported, .ignored, .unknown]
        for state in fine { #expect(!state.isProblem, "\(state) should not be a problem") }
    }

    // MARK: - Manual import eligibility

    @Test("a warned, import-pending download can be imported by hand")
    func importPendingNeedsManualImport() throws {
        let queued = try item("""
            "downloadId": "ABC", "status": "completed",
            "trackedDownloadStatus": "warning", "trackedDownloadState": "importPending"
        """)
        #expect(queued.needsManualImport)
        #expect(queued.canManuallyImport)
    }

    @Test("a failed import is offered to the user, not hidden")
    func importFailedNeedsManualImport() throws {
        let queued = try item("""
            "downloadId": "ABC", "status": "completed", "trackedDownloadState": "importFailed"
        """)
        #expect(queued.needsManualImport)
        #expect(queued.canManuallyImport)
        #expect(queued.hasIssue)
    }

    @Test("a completed download Lidarr has not flagged can still be imported by hand")
    func completedDownloadCanBeImported() throws {
        let queued = try item("""
            "downloadId": "ABC", "status": "completed",
            "trackedDownloadStatus": "ok", "trackedDownloadState": "importing"
        """)
        #expect(!queued.needsManualImport)
        #expect(queued.canManuallyImport)
    }

    @Test("there is nothing left to import once Lidarr filed or ignored the files", arguments: ["imported", "ignored"])
    func settledDownloadsOfferNoImport(tracked: String) throws {
        let queued = try item("""
            "downloadId": "ABC", "status": "completed", "trackedDownloadState": "\(tracked)"
        """)
        #expect(!queued.canManuallyImport)
    }

    @Test("a download that failed outright has no files to offer")
    func failedDownloadOffersNoImport() throws {
        let queued = try item("""
            "downloadId": "ABC", "status": "completed", "trackedDownloadState": "downloadFailed"
        """)
        #expect(!queued.canManuallyImport)
        #expect(queued.hasIssue)
    }

    @Test("a download still transferring offers no manual import")
    func downloadingCannotBeImported() throws {
        let queued = try item("\"downloadId\": \"ABC\", \"status\": \"downloading\"")
        #expect(!queued.canManuallyImport)
    }

    @Test("without a download id there is nothing to ask Lidarr about")
    func missingDownloadIdCannotBeImported() throws {
        let queued = try item("\"status\": \"completed\", \"trackedDownloadState\": \"importPending\"")
        #expect(!queued.canManuallyImport)
    }

    // MARK: - Time left

    static let timespans: [(raw: String, seconds: Int)] = [
        ("02:14:00", 8_040),
        ("00:12:34.5670000", 754),
        ("1.03:00:00", 97_200),
    ]

    @Test("hours and minutes survive Lidarr's timespan", arguments: timespans)
    func timeRemainingParsesTimespans(raw: String, seconds: Int) throws {
        let queued = try item("\"timeleft\": \"\(raw)\"")
        let expected = Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
        #expect(queued.timeRemaining == expected)
    }

    static let unusableTimespans: [String?] = [nil, "", "00:00:00", "soon"]

    @Test("a missing, zero, or unparsable timespan shows nothing", arguments: unusableTimespans)
    func timeRemainingIsNilWhenUnusable(raw: String?) throws {
        let queued = try item(raw.map { "\"timeleft\": \"\($0)\"" } ?? "\"timeleft\": null")
        #expect(queued.timeRemaining == nil)
    }

    // MARK: - Added date

    static let isoTimestamps: [String] = ["2026-07-23T00:22:00Z", "2026-07-23T00:22:00.000Z"]

    @Test("the added timestamp is read with or without fractional seconds", arguments: isoTimestamps)
    func addedDateParsesBothISOForms(raw: String) throws {
        let queued = try item("\"added\": \"\(raw)\"")
        let expected = DateComponents(
            calendar: .init(identifier: .gregorian), timeZone: .gmt,
            year: 2026, month: 7, day: 23, hour: 0, minute: 22
        ).date
        #expect(queued.addedDate == expected)
    }

    @Test("a missing added timestamp is not a date")
    func addedDateIsNilWhenAbsent() throws {
        #expect(try item("\"status\": \"downloading\"").addedDate == nil)
    }

    // MARK: - Progress and messages

    @Test("progress is the downloaded fraction of the size")
    func progressUsesSizeAndSizeleft() throws {
        let queued = try item("\"size\": 1000, \"sizeleft\": 250")
        #expect(queued.progress == 0.75)
        #expect(queued.totalSize == 1000)
    }

    @Test("the error message leads the reasons, without repeating a status message")
    func allMessagesPutsErrorFirst() throws {
        let queued = try item("""
            "errorMessage": "The download is stalled with no connections",
            "statusMessages": [{ "title": "One Piece", "messages": ["Invalid season or episode"] }]
        """)
        #expect(queued.allMessages == [
            "The download is stalled with no connections",
            "One Piece",
            "Invalid season or episode",
        ])
    }

    @Test("a payload with no reasons has nothing to explain")
    func allMessagesIsEmptyWhenClean() throws {
        #expect(try item("\"status\": \"downloading\"").allMessages.isEmpty)
    }

    // MARK: - Fields the detail sheet shows

    @Test("protocol, client, and indexer are decoded for the information rows")
    func decodesTransportFields() throws {
        let queued = try item("""
            "protocol": "usenet", "downloadClient": "SABnzbd", "indexer": "NZBgeek"
        """)
        #expect(queued.protocol == "usenet")
        #expect(queued.downloadClient == "SABnzbd")
        #expect(queued.indexer == "NZBgeek")
    }

    @Test("the row and the sheet label the state Lidarr reported")
    func statusLabelFollowsState() throws {
        let queued = try item("\"status\": \"completed\", \"trackedDownloadState\": \"importFailed\"")
        #expect(queued.statusLabel == LidarrQueueState.importFailed.label)
        #expect(queued.statusLabel == String(localized: "Import failed"))
    }
}
