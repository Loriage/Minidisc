import Foundation
import AVFoundation
import OSLog

/// Losslessly moves an MP4/M4A `moov` atom ahead of `mdat`.
nonisolated struct AudioFaststartRemuxer: Sendable {
    /// Bump when remux diagnostics change.
    static let diagnosticsVersion = 9

    enum Outcome: Sendable, Equatable {
        case skipped
        case remuxed
        case failed
    }

    enum FaststartState: Sendable, Equatable {
        case notMP4
        case faststart
        case needsRemux
    }

    static let mp4Suffixes: Set<String> = ["m4a", "m4b", "mp4", "aac"]

    /// `container` must come from byte sniffing, never from the server's declared suffix.
    /// A verified MP4 overrides an inconclusive box scan, but not a definite faststart result.
    nonisolated static func shouldExportDespiteDetection(state: FaststartState?, container: String?) -> Bool {
        guard state != .faststart else { return false }
        guard let container = container?.lowercased() else { return false }
        return mp4Suffixes.contains(container)
    }

    /// Replaces the input atomically only after validating the exported layout.
    func remuxToFaststartIfNeeded(at fileURL: URL, container: String? = nil) async -> Outcome {
        let name = fileURL.lastPathComponent
        let sizeOnDisk = Self.fileSize(atPath: fileURL.path)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        let measurements = "size=\(sizeOnDisk) exists=\(exists)"

        let declared = container?.lowercased()
        let boxes = Self.topLevelBoxTypes(atPath: fileURL.path)
        let state = boxes.map(Self.classify(boxTypes:))
        let layout = boxes.map { $0.prefix(8).joined(separator: ",") } ?? "<unreadable>"

        switch state {
        case .needsRemux:
            Logger.download.info("[REMUX v\(Self.diagnosticsVersion)] '\(name, privacy: .public)' — needsRemux (\(measurements, privacy: .public) boxes: \(layout, privacy: .public))")
        case .notMP4, .faststart, nil:
            let verdict = state.map { String(describing: $0) } ?? "unreadable"
            guard Self.shouldExportDespiteDetection(state: state, container: declared) else {
                Logger.download.info("[REMUX v\(Self.diagnosticsVersion)] '\(name, privacy: .public)' — \(verdict, privacy: .public), skipped (\(measurements, privacy: .public) container: \(declared ?? "nil", privacy: .public) boxes: \(layout, privacy: .public))")
                return .skipped
            }
            Logger.download.info("[REMUX v\(Self.diagnosticsVersion)] '\(name, privacy: .public)' — detection says \(verdict, privacy: .public) but bytes are '\(declared ?? "nil", privacy: .public)'; exporting anyway (\(measurements, privacy: .public) boxes: \(layout, privacy: .public))")
        }

        let asset = AVURLAsset(url: fileURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            Logger.download.warning("[REMUX v\(Self.diagnosticsVersion)] passthrough preset unavailable for '\(fileURL.lastPathComponent, privacy: .public)' — original kept")
            return .failed
        }
        session.shouldOptimizeForNetworkUse = true

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("faststart-\(UUID().uuidString).m4a")
        do {
            try await session.export(to: tempURL, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            Logger.download.warning("[REMUX v\(Self.diagnosticsVersion)] export failed for '\(fileURL.lastPathComponent, privacy: .public)': \(error, privacy: .public) — original kept")
            return .failed
        }

        let outSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        guard outSize > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            Logger.download.warning("[REMUX v\(Self.diagnosticsVersion)] empty export for '\(fileURL.lastPathComponent, privacy: .public)' — original kept")
            return .failed
        }

        // A valid output must contain both media and metadata boxes in faststart order.
        guard let outBoxes = Self.topLevelBoxTypes(atPath: tempURL.path),
              Self.isUsableFaststartOutput(boxTypes: outBoxes) else {
            try? FileManager.default.removeItem(at: tempURL)
            Logger.download.warning("[REMUX v\(Self.diagnosticsVersion)] export produced an unusable layout for '\(fileURL.lastPathComponent, privacy: .public)' — original kept")
            return .failed
        }

        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            Logger.download.warning("[REMUX v\(Self.diagnosticsVersion)] atomic swap failed for '\(fileURL.lastPathComponent, privacy: .public)': \(error, privacy: .public) — original kept")
            return .failed
        }

        // replaceItemAt may relocate the item, so verify the caller's path.
        let landedSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        guard landedSize > 0 else {
            Logger.download.error("[REMUX v\(Self.diagnosticsVersion)] post-swap file missing at '\(fileURL.lastPathComponent, privacy: .public)' — download is broken")
            return .failed
        }

        Logger.download.info("[REMUX v\(Self.diagnosticsVersion)] faststart-remuxed '\(fileURL.lastPathComponent, privacy: .public)'")
        return .remuxed
    }

    // MARK: - Box-layout logic

    nonisolated static func fileSize(atPath path: String) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    nonisolated static func isM4AContainer(atPath path: String) -> Bool {
        guard let boxes = topLevelBoxTypes(atPath: path) else { return false }
        return boxes.contains("ftyp")
    }

    /// Classifies the ordering of top-level MP4 boxes.
    nonisolated static func classify(boxTypes types: [String]) -> FaststartState {
        guard types.contains("ftyp") else { return .notMP4 }
        guard let moov = types.firstIndex(of: "moov") else { return .faststart }
        if let mdat = types.firstIndex(of: "mdat"), mdat < moov { return .needsRemux }
        return .faststart
    }

    /// Exported output must contain both required boxes in faststart order.
    nonisolated static func isUsableFaststartOutput(boxTypes types: [String]) -> Bool {
        types.contains("moov") && types.contains("mdat") && classify(boxTypes: types) == .faststart
    }

    nonisolated static func topLevelBoxTypes(in data: Data, limit: Int = 64) -> [String] {
        let bytes = [UInt8](data)
        return scanBoxTypes(total: UInt64(bytes.count), limit: limit) { offset, length in
            let start = Int(offset)
            guard start >= 0, start + length <= bytes.count else { return nil }
            return Array(bytes[start..<start + length])
        }
    }

    /// Reads box headers while seeking past payloads such as `mdat`.
    nonisolated static func topLevelBoxTypes(atPath path: String, limit: Int = 64) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let handleSize = (try? handle.seekToEnd()) ?? 0
        let attrSize = Self.fileSize(atPath: path)
        let total = max(handleSize, attrSize)
        if handleSize != attrSize {
            Logger.download.info("[REMUX v\(Self.diagnosticsVersion)] size disagreement on '\(URL(fileURLWithPath: path).lastPathComponent, privacy: .public)': handle=\(handleSize, privacy: .public) attributes=\(attrSize, privacy: .public)")
        }

        let types = scanBoxTypes(total: total, limit: limit) { offset, length in
            do { try handle.seek(toOffset: offset) } catch { return nil }
            guard let chunk = try? handle.read(upToCount: length), chunk.count == length else { return nil }
            return [UInt8](chunk)
        }

        // Distinguish an unreadable file from valid non-MP4 content.
        if types.isEmpty && total >= 8 {
            let head = (try? handle.seek(toOffset: 0)).flatMap { _ in try? handle.read(upToCount: 16) }
            let hex = head.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "<unreadable>"
            Logger.download.info("[REMUX v\(Self.diagnosticsVersion)] box scan read nothing from a \(total, privacy: .public)-byte file — first bytes: \(hex, privacy: .public)")
            return nil
        }
        return types
    }

    /// Walks the ISO-BMFF top-level box chain: each box is an 8-byte header (UInt32 big-endian
    /// size + 4-char type), with size==1 → 64-bit largesize follows, size==0 → box runs to EOF.
    /// Advances by box size so payloads (notably a large `mdat`) are never read.
    private nonisolated static func scanBoxTypes(
        total: UInt64,
        limit: Int,
        read: (_ offset: UInt64, _ length: Int) -> [UInt8]?
    ) -> [String] {
        var types: [String] = []
        var offset: UInt64 = 0
        while offset + 8 <= total, types.count < limit {
            guard let header = read(offset, 8), header.count == 8 else { break }
            var size = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? "????"
            var headerLength: UInt64 = 8
            if size == 1 {
                guard let large = read(offset + 8, 8), large.count == 8 else { break }
                size = large.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerLength = 16
            } else if size == 0 {
                size = total - offset
            }
            types.append(type)
            guard size >= headerLength else { break }
            offset += size
        }
        return types
    }
}
