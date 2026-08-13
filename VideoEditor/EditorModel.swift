//
//  EditorModel.swift
//  VideoEditor
//
//  The project model. Holds the ordered assembly items + background audio, and
//  drives editing of the currently selected item (frame-accurate trim). Export
//  normalizes every item onto a shared canvas and concatenates them deterministically.
//

import Foundation
import AVFoundation
import Observation
import AppKit
import UniformTypeIdentifiers

/// A resolved position in the gapless output timeline.
struct TimelineHit {
    let itemID: ClipItem.ID
    let itemIndex: Int
    let timelineStart: Double
    let timelineEnd: Double
    let timelineTime: Double
    let sourceTime: Double
}

/// Transient hover state. This is deliberately separate from the committed
/// playhead so moving the pointer never changes selection or playback.
struct TimelinePreview {
    let itemID: ClipItem.ID
    let timelineTime: Double
    /// Set for image clips; video clips render from the scrub player instead.
    let imageURL: URL?
    /// A video clip is being scrubbed — the preview frame comes from the shared
    /// `ScrubPreviewPlayer`, not a still image.
    let showsScrubPlayer: Bool
    /// The pointer is over a clip's black pad. There is no frame to show there
    /// and the export really is black, so the preview must be black too.
    var isBlackPad: Bool = false
}

private enum ProbedLibraryImport: Sendable {
    case image(url: URL, width: Int, height: Int)
    case audio(url: URL, duration: Double)
    case video(url: URL, info: MediaInfo)
}

private enum LibraryImportKind: Sendable {
    case image, audio, video
}

private struct LibraryImportRequest: Sendable {
    let order: Int
    let url: URL
    let generation: Int
    let kind: LibraryImportKind
}

private struct ProbedLibraryImportResult: Sendable {
    let order: Int
    let url: URL
    let generation: Int
    let entry: ProbedLibraryImport?
    let errorMessage: String?
}

@MainActor
@Observable
final class EditorModel {
    // Tooling
    var ff: FFTools? = FFTools.locate()
    var ffMissing: Bool { ff == nil }

    // Project
    var library: [LibraryAsset] = []
    /// The sidebar's search / kind filter. It lives here rather than in the view
    /// so ⌘A can select exactly the cards the sidebar is showing, no more.
    var librarySearchText = ""
    var libraryKindFilter: AssetKind?
    var visibleLibraryAssets: [LibraryAsset] {
        library.filter { asset in
            (libraryKindFilter == nil || asset.kind == libraryKindFilter)
                && (librarySearchText.isEmpty
                    || asset.url.lastPathComponent
                        .localizedCaseInsensitiveContains(librarySearchText))
        }
    }
    var items: [ClipItem] = [] {
        didSet { rebuildTimelineIndex() }
    }
    /// The clip the playhead is parked on — drives the preview player and the
    /// trim/split controls. Independent of the visual selection below.
    var activeItemID: ClipItem.ID?
    /// Desktop-style visual selection (blue border, bulk delete): click replaces,
    /// ⌘-click toggles, marquee replaces, clicking blank space clears.
    var selectedIDs: Set<ClipItem.ID> = []
    /// Library-side selection. The two selection domains are mutually exclusive —
    /// selecting in one clears the other, so Delete always has one clear target.
    var selectedLibraryIDs: Set<LibraryAsset.ID> = []
    /// The pane that last took a click. Only consulted when neither domain holds
    /// a selection (both panes clear their selection on a blank-space click),
    /// which is the one case the selection itself cannot disambiguate.
    var focusedPane: Pane = .timeline

    enum Pane { case timeline, library }

    /// Whether ⌘A / Delete address the timeline. A live selection speaks for
    /// itself; the last-clicked pane only breaks the tie when nothing is selected.
    var timelineHasFocus: Bool {
        if !selectedIDs.isEmpty { return true }
        if !selectedLibraryIDs.isEmpty { return false }
        return focusedPane == .timeline
    }
    var audioURL: URL?
    var audioName: String?
    var audioDuration: Double = 0

    // Editing state (of the selected item's source)
    var currentTime: Double = 0
    var player: AVPlayer?

    /// Drives the hover preview by chase-seeking a dedicated muted player, kept
    /// separate from `player` so scrubbing never disturbs the committed playhead.
    @ObservationIgnored let scrub = ScrubPreviewPlayer()
    var scrubPlayer: AVPlayer { scrub.player }

    // The committed output playhead and the scale of the one canonical timeline.
    var timelineTime: Double = 0
    var timelinePointsPerSecond: Double = 72
    /// Incremented only when the first video is inserted into an empty timeline.
    /// TimelineView consumes this request using its current measured width.
    private(set) var timelineAutoFitRequestID = 0
    /// A pending "scroll this output time into view" request. The scale is
    /// already applied when this is published; only the scroll is outstanding.
    private(set) var timelineZoomRequest: TimelineZoomRequest?
    @ObservationIgnored private var timelineZoomRequestCounter = 0
    var timelinePreview: TimelinePreview?
    var isTimelinePlaying = false

    struct TimelineZoomRequest: Equatable {
        let id: Int
        let time: Double
    }

    // Export
    var isExporting = false
    var exportProgress: Double = 0
    var exportResult: ExportResult?
    /// Where the running/last export writes to, for the progress sheet.
    var exportDestination: URL?
    var exportStartDate: Date?
    /// Wall-clock seconds the last finished export took.
    var exportElapsed: Double?
    var errorMessage: String?
    var isImporting = false
    var imageDefaultDuration: Double = 3

    // True while a time/frame text field has keyboard focus, so single-key
    // shortcuts (space, q, w, s, i, o, delete…) don't fire mid-typing.
    var isTextEditing = false

    private var players: [URL: AVPlayer] = [:]
    private var thumbnailerCache: [URL: Thumbnailer] = [:]
    @ObservationIgnored private var timelineStartsByID: [ClipItem.ID: Double] = [:]
    private var exportTask: Task<Void, Never>?
    private var videoSourceRevisions: [URL: Int] = [:]
    private var sourceImportGenerations: [URL: Int] = [:]
    @ObservationIgnored private var activeImportCount = 0
    @ObservationIgnored private var audioDurationRequestID = 0
    private var timeObserver: Any?
    private var observedPlayer: AVPlayer?
    @ObservationIgnored private var timeObserverGeneration = 0
    @ObservationIgnored private var imagePlaybackTask: Task<Void, Never>?
    @ObservationIgnored private var isAdvancingPlayback = false

    var hasProject: Bool { !items.isEmpty }
    var hasLibrary: Bool { !library.isEmpty }

    // MARK: - Selected item

    var activeIndex: Int? { items.firstIndex { $0.id == activeItemID } }
    var activeItem: ClipItem? { activeIndex.map { items[$0] } }
    func thumbnailer(for url: URL) -> Thumbnailer? {
        thumbnailerCache[normalizedSourceURL(url)]
    }

    func videoSourceRevision(for url: URL) -> Int {
        videoSourceRevisions[normalizedSourceURL(url), default: 0]
    }

    var currentFrameIndex: Int {
        guard let item = activeItem, !item.isImage else { return 0 }
        let first = item.trimStartFrame
        let last = max(first, item.trimEndFrame - 1)
        return min(max(first, item.grid.frameIndex(containing: currentTime)), last)
    }
    /// Nearest real frame start of the active clip (identity for images).
    func snap(_ t: Double) -> Double {
        guard let item = activeItem, !item.isImage else { return t }
        let g = item.grid
        return g.time(ofFrame: g.nearestFrame(to: t))
    }
    // MARK: - Canvas / output

    private func even(_ x: Int) -> Int { x % 2 == 0 ? max(2, x) : x + 1 }

    /// User override for the output canvas. Frame rate deliberately stays
    /// derived: it belongs to the frame lattice, not to the framing, and tying
    /// the two to one control would let a reframe resample the timeline.
    var canvasSizing: CanvasSizing = .automatic

    var canvas: CanvasSpec {
        let size: PixelSize
        switch canvasSizing {
        case .automatic:
            size = derivedCanvasSize
        case .fixed(let fixed):
            size = fixed.isUsable ? fixed : derivedCanvasSize
        }
        // Use the exact rational of the fastest video so a fractional-fps source
        // (e.g. 24.9713) is never resampled to a rounded integer rate.
        let best = items.filter { !$0.isImage && $0.fps > 0 }.max { $0.fps < $1.fps }
        return CanvasSpec(width: even(size.width), height: even(size.height),
                          fps: best?.fpsRational ?? "30", fpsValue: best?.fps ?? 30)
    }

    /// The canvas the sources imply: large enough to hold the biggest of them.
    private var derivedCanvasSize: PixelSize {
        let w = items.map { $0.naturalWidth }.filter { $0 > 0 }.max() ?? 1280
        let h = items.map { $0.naturalHeight }.filter { $0 > 0 }.max() ?? 720
        return PixelSize(width: w, height: h)
    }

    private(set) var totalOutputDuration: Double = 0

    /// Rebuild all timeline-derived coordinates once whenever the value-typed
    /// item array changes. Reads during layout, playback and hit-testing then
    /// stay O(1), rather than repeatedly reducing or scanning the whole array.
    private func rebuildTimelineIndex() {
        var starts: [ClipItem.ID: Double] = [:]
        starts.reserveCapacity(items.count)
        var total = 0.0
        for item in items {
            starts[item.id] = total
            total += item.displayDuration
        }
        timelineStartsByID = starts
        totalOutputDuration = total
    }

    // MARK: - Output timeline coordinates / zoom

    let timelineMinPointsPerSecond: Double = 8
    // At the upper end a 30 fps source gets 120 points per frame, so individual
    // frames can become first-class cells inside the timeline itself.
    let timelineMaxPointsPerSecond: Double = 3_600

    var timelineZoomLevel: Double {
        get {
            log(timelinePointsPerSecond / timelineMinPointsPerSecond)
                / log(timelineMaxPointsPerSecond / timelineMinPointsPerSecond)
        }
        set {
            let level = min(max(newValue, 0), 1)
            setTimelineScale(timelineMinPointsPerSecond
                * pow(timelineMaxPointsPerSecond / timelineMinPointsPerSecond, level))
        }
    }

    func setTimelineScale(_ value: Double) {
        timelinePointsPerSecond = min(max(value, timelineMinPointsPerSecond),
                                      timelineMaxPointsPerSecond)
    }

    func fitTimeline(in viewportWidth: CGFloat) {
        guard totalOutputDuration > 0 else { return }
        setTimelineScale(Double(max(1, viewportWidth)) / totalOutputDuration)
    }

    /// Ask the timeline view to zoom-to-fit; the model doesn't know the
    /// viewport width, so the view consumes this request with its own measure.
    func requestTimelineAutoFit() {
        timelineAutoFitRequestID &+= 1
    }

    func timelineStart(for id: ClipItem.ID) -> Double? {
        timelineStartsByID[id]
    }

    /// Resolve an output time using half-open clip ranges. A time exactly on an
    /// edit point belongs to the clip on its right; the movie end belongs to the
    /// final clip so its last frame can still be inspected.
    func timelineHit(at time: Double) -> TimelineHit? {
        guard !items.isEmpty, time >= 0, time <= totalOutputDuration + 1e-9 else { return nil }
        var start = 0.0
        for (index, item) in items.enumerated() {
            let end = start + item.displayDuration
            let isLast = index == items.count - 1
            if time < end || (isLast && time <= end + 1e-9) {
                let offset = min(max(0, time - start), item.displayDuration)
                let sourceTime: Double
                if item.isImage {
                    sourceTime = offset
                } else {
                    let g = item.grid
                    let firstFrame = item.trimStartFrame
                    let endFrame = max(firstFrame + 1, item.trimEndFrame)
                    let firstTime = g.time(ofFrame: firstFrame)
                    let lastTime = g.time(ofFrame: endFrame - 1)
                    sourceTime = min(max(firstTime, item.inPoint + offset), lastTime)
                }
                return TimelineHit(itemID: item.id, itemIndex: index,
                                   timelineStart: start, timelineEnd: end,
                                   timelineTime: min(max(time, start), end),
                                   sourceTime: sourceTime)
            }
            start = end
        }
        return nil
    }

    /// Quantize a hit to the video frame nearest to it, splitting each frame's
    /// span at its midpoint: the left half of a span stays on that frame, the
    /// right half rounds up to the next one. Hover and click seeks share this,
    /// so the hover line, the playhead and the previewed frame all agree.
    /// Images have no frame grid and pass through unchanged.
    private func frameSnapped(_ hit: TimelineHit) -> TimelineHit {
        let item = items[hit.itemIndex]
        guard !item.isImage else { return hit }
        // The black pad carries no frame lattice, and the frame this would snap
        // to sits before the pad even begins.
        if item.hasVideoPad,
           hit.timelineTime > hit.timelineStart + item.contentDuration { return hit }
        let g = item.grid
        let firstFrame = item.trimStartFrame
        let endFrame = max(firstFrame + 1, item.trimEndFrame)
        let frame = min(max(firstFrame, g.nearestFrame(to: hit.sourceTime)), endFrame - 1)
        let source = g.time(ofFrame: frame)
        let timeline = hit.timelineStart + (source - item.inPoint)
        return TimelineHit(itemID: hit.itemID, itemIndex: hit.itemIndex,
                           timelineStart: hit.timelineStart, timelineEnd: hit.timelineEnd,
                           timelineTime: min(max(timeline, hit.timelineStart), hit.timelineEnd),
                           sourceTime: source)
    }

    private func syncTimelineTimeFromActive() {
        guard let item = activeItem, let start = timelineStart(for: item.id) else {
            timelineTime = min(max(0, timelineTime), totalOutputDuration)
            return
        }
        // A playhead parked in the clip's black pad has no source time to sync
        // from — `currentTime` is pinned to the final frame there — so deriving
        // it would yank the playhead back to where the picture stopped.
        if item.hasVideoPad,
           timelineTime > start + item.contentDuration,
           timelineTime <= start + item.displayDuration + 1e-9 {
            return
        }
        let offset = item.isImage
            ? min(max(0, currentTime), item.contentDuration)
            : min(max(0, currentTime - item.inPoint), item.contentDuration)
        timelineTime = start + offset
    }

    /// True while the playhead sits past the final real frame of the active
    /// clip, inside black that the export will genuinely contain.
    var isPlayheadInVideoPad: Bool {
        guard let item = activeItem, item.hasVideoPad,
              let start = timelineStart(for: item.id) else { return false }
        return timelineTime > start + item.contentDuration + 1e-9
    }

    /// The edit boundary represented by the global playhead. Previewing the
    /// movie end uses the last retained frame, but edits at that position must
    /// still resolve to the exclusive out boundary.
    private var activeEditSourceTime: Double {
        guard let item = activeItem,
              let start = timelineStart(for: item.id) else { return currentTime }
        let offset = min(max(0, timelineTime - start), item.displayDuration)
        return item.isImage ? offset : min(item.outPoint, item.inPoint + offset)
    }

    func seekTimeline(to time: Double) {
        guard let rawHit = timelineHit(at: time) else { return }
        let hit = frameSnapped(rawHit)
        pauseTimelinePlayback()
        if activeItemID != hit.itemID {
            // Selecting a different clip and then seeking used to issue two
            // asynchronous seeks (clip start, then tap target). Initialize the
            // selection at the final target so a single click is sufficient.
            selectItemInternal(hit.itemID,
                               sourceTime: hit.sourceTime,
                               timelinePosition: hit.timelineTime)
            return
        }
        guard let item = activeItem else { return }
        timelineTime = hit.timelineTime
        if item.isImage {
            currentTime = min(max(0, hit.sourceTime), item.displayDuration)
        } else {
            currentTime = min(max(item.inPoint, hit.sourceTime), item.outPoint)
            seekPlayer(to: currentTime)
        }
    }

    /// Park the playhead on the exclusive end boundary while previewing the
    /// final retained frame. A regular frame-snapped seek would place the red
    /// line at that frame's start instead of at the visible end of the movie.
    func seekTimelineToEnd() {
        guard let last = items.last else { return }
        pauseTimelinePlayback()
        let sourceEnd = last.isImage ? last.displayDuration : last.outPoint
        selectItemInternal(last.id,
                           sourceTime: sourceEnd,
                           timelinePosition: totalOutputDuration)
    }

    func updateTimelineHover(at time: Double) {
        guard time >= 0, time <= totalOutputDuration,
              let rawHit = timelineHit(at: time) else {
            clearTimelineHover()
            return
        }
        let hit = frameSnapped(rawHit)
        let item = items[hit.itemIndex]
        if item.isImage {
            scrub.end()
            timelinePreview = TimelinePreview(itemID: item.id,
                                              timelineTime: hit.timelineTime,
                                              imageURL: item.url,
                                              showsScrubPlayer: false)
            return
        }

        if item.hasVideoPad,
           hit.timelineTime > hit.timelineStart + item.contentDuration + 1e-9 {
            scrub.end()
            timelinePreview = TimelinePreview(itemID: item.id,
                                              timelineTime: hit.timelineTime,
                                              imageURL: nil,
                                              showsScrubPlayer: false,
                                              isBlackPad: true)
            return
        }

        let g = item.grid
        let firstFrame = item.trimStartFrame
        let endFrame = max(firstFrame + 1, item.trimEndFrame)
        let firstTime = g.time(ofFrame: firstFrame)
        let lastTime = g.time(ofFrame: endFrame - 1)
        // The exact frame under the pointer (already frame-snapped), clamped into
        // the clip's kept range so scrubbing never previews trimmed-away content.
        let exact = min(max(firstTime, hit.sourceTime), lastTime)
        timelinePreview = TimelinePreview(itemID: item.id,
                                          timelineTime: hit.timelineTime,
                                          imageURL: nil,
                                          showsScrubPlayer: true)
        scrub.prepare(url: normalizedSourceURL(item.url))
        // The pointer is already snapped to one real frame. Request that exact
        // frame once; allowing a tolerance here lets AVPlayer repaint either
        // neighbour while repeated hover events arrive inside the same cell.
        scrub.scrub(to: exact)
    }

    func clearTimelineHover() {
        scrub.end()
        timelinePreview = nil
    }

    // MARK: - Undo / redo

    /// A full copy of everything an edit can touch. Snapshot-based undo keeps
    /// every operation trivially reversible — the arrays are small metadata, so
    /// copies are cheap.
    private struct ProjectSnapshot {
        var library: [LibraryAsset]
        var items: [ClipItem]
        var audioURL: URL?
        var audioName: String?
        var audioDuration: Double
        var activeItemID: ClipItem.ID?
        var selectedIDs: Set<ClipItem.ID>
        var selectedLibraryIDs: Set<LibraryAsset.ID>
        var currentTime: Double
        var timelineTime: Double
        var canvasSizing: CanvasSizing
    }

    private var undoStack: [ProjectSnapshot] = []
    private var redoStack: [ProjectSnapshot] = []
    /// Captures the state at the start of one continuous slider gesture. The
    /// snapshot is only pushed after the gesture actually changes the value, so
    /// clicking the slider without moving it neither adds a no-op undo step nor
    /// clears redo history.
    @ObservationIgnored private var imageDurationEditingSession: (
        itemID: ClipItem.ID,
        undoSnapshot: ProjectSnapshot,
        hasRegisteredUndo: Bool
    )?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func snapshot() -> ProjectSnapshot {
        ProjectSnapshot(library: library, items: items,
                        audioURL: audioURL, audioName: audioName,
                        audioDuration: audioDuration,
                        activeItemID: activeItemID, selectedIDs: selectedIDs,
                        selectedLibraryIDs: selectedLibraryIDs,
                        currentTime: currentTime, timelineTime: timelineTime,
                        canvasSizing: canvasSizing)
    }

    /// Push the current project state as one undo step. Call exactly once per
    /// user action, immediately before its first mutation.
    private func registerUndo() {
        registerUndo(snapshot())
    }

    private func registerUndo(_ undoSnapshot: ProjectSnapshot) {
        undoStack.append(undoSnapshot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        imageDurationEditingSession = nil
        endGeometryEditing()
        guard let past = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        apply(past)
    }

    func redo() {
        imageDurationEditingSession = nil
        endGeometryEditing()
        guard let future = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        apply(future)
    }

    private func apply(_ s: ProjectSnapshot) {
        pauseTimelinePlayback()
        clearTimelineHover()
        audioDurationRequestID &+= 1
        library = s.library
        items = s.items
        canvasSizing = s.canvasSizing
        audioURL = s.audioURL
        audioName = s.audioName
        audioDuration = s.audioDuration
        selectedIDs = s.selectedIDs
        selectedLibraryIDs = s.selectedLibraryIDs
        if let id = s.activeItemID, items.contains(where: { $0.id == id }) {
            selectItemInternal(id, sourceTime: s.currentTime,
                               timelinePosition: s.timelineTime)
        } else if let first = items.first {
            selectItemInternal(first.id)
        } else {
            activeItemID = nil
            detachObserver()
            player = nil
            currentTime = 0
            timelineTime = 0
        }
        reconcileVideoCaches()
    }

    // MARK: - Importing

    func pickAndImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video, .image,
                                     .audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { importAssets(panel.urls) }
    }

    /// Probe files once and add them to the library. Nothing enters the timeline
    /// here — the user drags assets in (or uses the row's add button).
    func importAssets(_ urls: [URL]) {
        guard let ff else { errorMessage = FFError.notFound.errorDescription; return }
        guard !urls.isEmpty else { return }

        var seen: Set<URL> = []
        let requests = urls.enumerated().compactMap { order, rawURL -> LibraryImportRequest? in
            let url = normalizedSourceURL(rawURL)
            guard seen.insert(url).inserted else { return nil }
            let generation = sourceImportGenerations[url, default: 0] &+ 1
            sourceImportGenerations[url] = generation
            let kind: LibraryImportKind
            if isImageURL(url) {
                kind = .image
            } else if isAudioURL(url) {
                kind = .audio
            } else {
                kind = .video
            }
            return LibraryImportRequest(order: order, url: url,
                                        generation: generation, kind: kind)
        }
        guard !requests.isEmpty else { return }

        errorMessage = nil
        activeImportCount += 1
        isImporting = true
        Task {
            let results: [ProbedLibraryImportResult]
            do {
                results = try await withThrowingTaskGroup(
                    of: ProbedLibraryImportResult.self,
                    returning: [ProbedLibraryImportResult].self
                ) { group in
                    for request in requests {
                        group.addTask {
                            do {
                                let entry: ProbedLibraryImport
                                switch request.kind {
                                case .image:
                                    let dimensions = try await ff.probeDimensions(request.url)
                                    entry = .image(url: request.url,
                                                   width: dimensions.w, height: dimensions.h)
                                case .audio:
                                    let duration = try await ff.probeDuration(request.url)
                                    entry = .audio(url: request.url, duration: duration)
                                case .video:
                                    entry = .video(url: request.url,
                                                   info: try await ff.probe(request.url))
                                }
                                return ProbedLibraryImportResult(
                                    order: request.order, url: request.url,
                                    generation: request.generation,
                                    entry: entry, errorMessage: nil)
                            } catch {
                                return ProbedLibraryImportResult(
                                    order: request.order, url: request.url,
                                    generation: request.generation, entry: nil,
                                    errorMessage: (error as? FFError)?.errorDescription
                                        ?? error.localizedDescription)
                            }
                        }
                    }

                    var completed: [ProbedLibraryImportResult] = []
                    completed.reserveCapacity(requests.count)
                    for try await result in group { completed.append(result) }
                    return completed.sorted { $0.order < $1.order }
                }
            } catch {
                // Each child converts its own probe failure to a value, so only
                // task-group cancellation or another structural failure lands here.
                self.errorMessage = error.localizedDescription
                activeImportCount -= 1
                isImporting = activeImportCount > 0
                return
            }

            var probedImports: [(entry: ProbedLibraryImport, url: URL, generation: Int)] = []
            for result in results {
                guard sourceImportGenerations[result.url] == result.generation else {
                    continue
                }
                if let entry = result.entry {
                    probedImports.append((entry, result.url, result.generation))
                } else if let message = result.errorMessage {
                    self.errorMessage = "無法讀取 \(result.url.lastPathComponent)：" + message
                }
            }

            // A result can become stale while this batch is still probing later
            // files. Recheck at commit so the newest import of each path wins.
            let imports = probedImports.compactMap { result -> ProbedLibraryImport? in
                sourceImportGenerations[result.url] == result.generation
                    ? result.entry : nil
            }

            // Refresh video sources before adding new rows. This is intentionally
            // outside undo: the old bytes no longer exist, so restoring their
            // metadata would only make the model disagree with the file on disk.
            let existingVideoURLs = Set(imports.compactMap { entry -> URL? in
                guard case .video(let url, _) = entry,
                      hasVideoReference(to: url) else { return nil }
                return url
            })
            for entry in imports {
                guard case .video(let url, let info) = entry else { continue }
                refreshVideoSource(at: url, with: info)
            }

            let additions = imports.filter { entry in
                guard case .video(let url, _) = entry else { return true }
                return !existingVideoURLs.contains(url)
            }
            if !additions.isEmpty { registerUndo() }

            for entry in additions {
                switch entry {
                case .image(let url, let width, let height):
                    library.append(LibraryAsset(url: url, kind: .image,
                                                width: width, height: height))
                case .audio(let url, let duration):
                    library.append(LibraryAsset(url: url, kind: .audio,
                                                duration: duration, hasAudio: true))
                case .video(let url, let info):
                    library.append(videoLibraryAsset(url: url, info: info))
                }
            }

            activeImportCount -= 1
            isImporting = activeImportCount > 0
        }
    }

    private func normalizedSourceURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isSameSource(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedSourceURL(lhs) == normalizedSourceURL(rhs)
    }

    private func hasVideoReference(to url: URL) -> Bool {
        library.contains { $0.kind == .video && isSameSource($0.url, url) }
            || items.contains { !$0.isImage && isSameSource($0.url, url) }
    }

    private func videoLibraryAsset(url: URL, info: MediaInfo) -> LibraryAsset {
        LibraryAsset(url: url, kind: .video,
                     width: info.width, height: info.height,
                     duration: info.duration, fps: info.fps,
                     fpsRational: info.fpsRational,
                     hasAudio: info.audioCodec != nil,
                     frameTimes: info.frameTimes,
                     containerStartTime: info.containerStartTime,
                     videoStartTime: info.videoStartTime,
                     videoDuration: info.videoDuration,
                     frameEndTime: info.videoEndTime,
                     audioStartTime: info.audioStartTime,
                     audioDuration: info.audioDuration)
    }

    /// Replace every object that can retain the old inode behind a file URL.
    /// A new source revision also makes SwiftUI discard view-local decoded frames.
    private func installFreshVideoCaches(for url: URL) {
        let sourceURL = normalizedSourceURL(url)
        clearTimelineHover()
        scrub.invalidate(url: sourceURL)

        let stalePlayerKeys = players.keys.filter { isSameSource($0, sourceURL) }
        for key in stalePlayerKeys { discardPlayer(forKey: key) }

        let staleThumbnailKeys = thumbnailerCache.keys.filter { isSameSource($0, sourceURL) }
        for key in staleThumbnailKeys { thumbnailerCache.removeValue(forKey: key) }
        thumbnailerCache[sourceURL] = Thumbnailer(url: sourceURL)
        videoSourceRevisions[sourceURL, default: 0] &+= 1
    }

    private func discardPlayer(forKey key: URL) {
        guard let stalePlayer = players.removeValue(forKey: key) else { return }
        stalePlayer.pause()
        if observedPlayer === stalePlayer { detachObserver() }
        if player === stalePlayer { player = nil }
        stalePlayer.replaceCurrentItem(with: nil)
    }

    /// Release decoded media when its last model reference disappears. Undo can
    /// restore a reference later; missing Thumbnailers are recreated here and a
    /// revision bump tells every strip to redraw from the new generator.
    private func reconcileVideoCaches() {
        let itemURLs = Set(items.compactMap { item in
            item.isImage ? nil : normalizedSourceURL(item.url)
        })
        let thumbnailURLs = itemURLs.union(library.compactMap { asset in
            asset.kind == .video ? normalizedSourceURL(asset.url) : nil
        })
        scrub.reconcile(keeping: thumbnailURLs)

        let stalePlayerKeys = players.keys.filter {
            !itemURLs.contains(normalizedSourceURL($0))
        }
        for key in stalePlayerKeys { discardPlayer(forKey: key) }

        let staleThumbnailKeys = thumbnailerCache.keys.filter {
            !thumbnailURLs.contains(normalizedSourceURL($0))
        }
        for key in staleThumbnailKeys { thumbnailerCache.removeValue(forKey: key) }

        for url in thumbnailURLs where thumbnailerCache[url] == nil {
            thumbnailerCache[url] = Thumbnailer(url: url)
            videoSourceRevisions[url, default: 0] &+= 1
        }
    }

    /// Re-importing the same path is a source refresh rather than a duplicate
    /// library row. Metadata, live playback and every decoded frame move to the
    /// new file together, so preview and export can never describe different bytes.
    private func refreshVideoSource(at url: URL, with info: MediaInfo) {
        let sourceURL = normalizedSourceURL(url)
        let refreshedActiveID = activeItem.flatMap {
            !$0.isImage && isSameSource($0.url, sourceURL) ? $0.id : nil
        }
        if refreshedActiveID != nil { pauseTimelinePlayback() }
        let requestedSourceTime = currentTime

        installFreshVideoCaches(for: sourceURL)

        for index in library.indices where library[index].kind == .video
            && isSameSource(library[index].url, sourceURL) {
            refreshVideoLibraryAsset(&library[index], sourceURL: sourceURL, info: info)
        }

        for index in items.indices where !items[index].isImage
            && isSameSource(items[index].url, sourceURL) {
            refreshVideoItem(&items[index], sourceURL: sourceURL, info: info)
        }
        for index in undoStack.indices {
            refreshVideoSnapshot(&undoStack[index], sourceURL: sourceURL, info: info)
        }
        for index in redoStack.indices {
            refreshVideoSnapshot(&redoStack[index], sourceURL: sourceURL, info: info)
        }

        if let refreshedActiveID,
           items.contains(where: { $0.id == refreshedActiveID }) {
            selectItemInternal(refreshedActiveID, sourceTime: requestedSourceTime)
        } else {
            syncTimelineTimeFromActive()
        }
    }

    private func refreshVideoLibraryAsset(_ asset: inout LibraryAsset,
                                          sourceURL: URL, info: MediaInfo) {
        asset.url = sourceURL
        asset.kind = .video
        asset.width = info.width
        asset.height = info.height
        asset.duration = info.duration
        asset.fps = info.fps
        asset.fpsRational = info.fpsRational
        asset.hasAudio = info.audioCodec != nil
        asset.frameTimes = info.frameTimes
        asset.containerStartTime = info.containerStartTime
        asset.videoStartTime = info.videoStartTime
        asset.videoDuration = info.videoDuration
        asset.frameEndTime = info.videoEndTime
        asset.audioStartTime = info.audioStartTime
        asset.audioDuration = info.audioDuration
    }

    private func refreshVideoSnapshot(_ snapshot: inout ProjectSnapshot,
                                      sourceURL: URL, info: MediaInfo) {
        for index in snapshot.library.indices where snapshot.library[index].kind == .video
            && isSameSource(snapshot.library[index].url, sourceURL) {
            refreshVideoLibraryAsset(&snapshot.library[index], sourceURL: sourceURL, info: info)
        }
        for index in snapshot.items.indices where !snapshot.items[index].isImage
            && isSameSource(snapshot.items[index].url, sourceURL) {
            refreshVideoItem(&snapshot.items[index], sourceURL: sourceURL, info: info)
        }

        let totalDuration = snapshot.items.reduce(0) { $0 + $1.displayDuration }
        guard let activeID = snapshot.activeItemID,
              let activeIndex = snapshot.items.firstIndex(where: { $0.id == activeID }) else {
            snapshot.timelineTime = min(max(0, snapshot.timelineTime), totalDuration)
            return
        }
        let activeItem = snapshot.items[activeIndex]
        snapshot.currentTime = activeItem.isImage
            ? min(max(0, snapshot.currentTime), activeItem.displayDuration)
            : min(max(activeItem.inPoint, snapshot.currentTime), activeItem.outPoint)
        let timelineStart = snapshot.items.prefix(activeIndex)
            .reduce(0) { $0 + $1.displayDuration }
        let offset = activeItem.isImage
            ? snapshot.currentTime : snapshot.currentTime - activeItem.inPoint
        snapshot.timelineTime = timelineStart + min(max(0, offset), activeItem.contentDuration)
    }

    private func refreshVideoItem(_ item: inout ClipItem,
                                  sourceURL: URL, info: MediaInfo) {
        let oldGrid = item.grid
        let keptSourceStart = item.trimStartFrame <= oldGrid.firstDisplayedFrame
        let keptSourceEnd = item.trimEndFrame >= oldGrid.frameCount
        let newGrid = FrameGrid(times: info.frameTimes,
                                nominalFps: info.fps > 0 ? info.fps : 30,
                                fallbackDuration: info.videoDuration > 0
                                    ? info.videoDuration : info.duration,
                                fallbackStartTime: info.videoStartTime,
                                observedEndTime: info.videoEndTime)
        let firstFrame = min(newGrid.firstDisplayedFrame, newGrid.frameCount - 1)
        let lastPossibleStart = max(firstFrame, newGrid.frameCount - 1)
        let requestedStart = keptSourceStart
            ? firstFrame : newGrid.nearestBoundary(to: item.inPoint)
        let startFrame = min(max(firstFrame, requestedStart), lastPossibleStart)
        let requestedEnd = keptSourceEnd
            ? newGrid.frameCount : newGrid.nearestBoundary(to: item.outPoint)
        let endFrame = min(max(startFrame + 1, requestedEnd), newGrid.frameCount)

        item.url = sourceURL
        item.naturalWidth = info.width
        item.naturalHeight = info.height
        item.sourceDuration = info.duration
        item.fps = info.fps
        item.fpsRational = info.fpsRational
        item.hasAudio = info.audioCodec != nil
        item.frameTimes = info.frameTimes
        item.containerStartTime = info.containerStartTime
        item.videoStartTime = info.videoStartTime
        item.videoDuration = info.videoDuration
        item.frameEndTime = info.videoEndTime
        item.audioStartTime = info.audioStartTime
        item.audioDuration = info.audioDuration
        item.inPoint = newGrid.boundary(startFrame)
        item.outPoint = newGrid.boundary(endFrame)
        if item.audioOutPoint != nil {
            item.audioOutPoint = min(item.effectiveAudioOutPoint, item.outPoint)
        }
        if item.containerOutPoint != nil {
            item.containerOutPoint = min(item.effectiveContainerOutPoint, item.outPoint)
        }
    }

    func libraryAsset(_ id: LibraryAsset.ID) -> LibraryAsset? {
        library.first { $0.id == id }
    }

    /// Instantiate a library asset onto the timeline. `index` nil appends.
    /// Audio assets become the background music instead of a timeline item.
    func insertLibraryAsset(_ id: LibraryAsset.ID, at index: Int? = nil) {
        guard let asset = libraryAsset(id) else { return }
        switch asset.kind {
        case .audio:
            setAudio(asset.url)
        case .image:
            insertItem(ClipItem(url: asset.url, kind: .image,
                                naturalWidth: asset.width, naturalHeight: asset.height,
                                sourceDuration: 0, fps: 0, hasAudio: false,
                                outPoint: imageDefaultDuration), at: index)
        case .video:
            // In/out default to the real first/last frame boundaries, so files
            // whose video doesn't start at t = 0 begin life on the grid.
            let grid = FrameGrid(times: asset.frameTimes,
                                 nominalFps: asset.fps > 0 ? asset.fps : 30,
                                 fallbackDuration: asset.videoDuration > 0
                                    ? asset.videoDuration : asset.duration,
                                 fallbackStartTime: asset.videoStartTime,
                                 observedEndTime: asset.frameEndTime)
            insertItem(ClipItem(url: asset.url, kind: .video,
                                naturalWidth: asset.width, naturalHeight: asset.height,
                                sourceDuration: asset.duration, fps: asset.fps,
                                fpsRational: asset.fpsRational,
                                hasAudio: asset.hasAudio, frameTimes: asset.frameTimes,
                                inPoint: grid.boundary(grid.firstDisplayedFrame),
                                outPoint: grid.boundary(grid.frameCount),
                                containerStartTime: asset.containerStartTime,
                                videoStartTime: asset.videoStartTime,
                                videoDuration: asset.videoDuration,
                                frameEndTime: asset.frameEndTime,
                                audioStartTime: asset.audioStartTime,
                                audioDuration: asset.audioDuration), at: index)
        }
    }

    private func insertItem(_ item: ClipItem, at index: Int?) {
        pauseTimelinePlayback()
        registerUndo()
        let shouldAutoFit = items.isEmpty && !item.isImage
        let i = min(max(0, index ?? items.count), items.count)
        items.insert(item, at: i)
        if activeItemID == nil { selectItem(item.id) }
        syncTimelineTimeFromActive()
        if shouldAutoFit { timelineAutoFitRequestID &+= 1 }
    }

    func removeFromLibrary(_ id: LibraryAsset.ID) {
        removeLibraryAssets([id])
    }

    func removeSelectedLibraryAssets() {
        removeLibraryAssets(selectedLibraryIDs)
    }

    /// Remove library assets and, in the same undo step, every timeline clip
    /// instantiated from them. A removed audio asset stops being the music.
    func removeLibraryAssets(_ ids: Set<LibraryAsset.ID>) {
        let assets = library.filter { ids.contains($0.id) }
        guard !assets.isEmpty else { return }
        pauseTimelinePlayback()
        clearTimelineHover()
        registerUndo()
        let urls = Set(assets.map(\.url))
        if let audioURL, urls.contains(where: { isSameSource($0, audioURL) }) {
            resetAudioState()
        }
        library.removeAll { ids.contains($0.id) }
        selectedLibraryIDs.subtract(ids)
        let doomed = Set(items.filter { item in
            urls.contains(where: { isSameSource($0, item.url) })
        }.map(\.id))
        if !doomed.isEmpty { removeItemsInternal(doomed) }
        for rawURL in urls {
            let url = normalizedSourceURL(rawURL)
            let stillReferenced = library.contains { isSameSource($0.url, url) }
                || items.contains { isSameSource($0.url, url) }
                || audioURL.map { isSameSource($0, url) } == true
            if !stillReferenced {
                sourceImportGenerations[url, default: 0] &+= 1
            }
        }
        reconcileVideoCaches()
    }

    private func isImageURL(_ url: URL) -> Bool {
        if let t = UTType(filenameExtension: url.pathExtension.lowercased()) {
            return t.conforms(to: .image)
        }
        return ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp"].contains(url.pathExtension.lowercased())
    }

    private func isAudioURL(_ url: URL) -> Bool {
        if let t = UTType(filenameExtension: url.pathExtension.lowercased()),
           t.conforms(to: .audiovisualContent) {
            return t.conforms(to: .audio)
        }
        return ["mp3", "m4a", "wav", "aiff", "aif", "aac", "flac", "ogg"].contains(url.pathExtension.lowercased())
    }

    func setAudio(_ url: URL) {
        registerUndo()
        let sourceURL = normalizedSourceURL(url)
        audioDurationRequestID &+= 1
        let requestID = audioDurationRequestID
        audioURL = sourceURL
        audioName = sourceURL.lastPathComponent
        audioDuration = 0
        Task {
            let duration = if let ff {
                (try? await ff.probeDuration(sourceURL)) ?? 0.0
            } else {
                0.0
            }
            guard audioDurationRequestID == requestID, audioURL == sourceURL else { return }
            audioDuration = duration
        }
    }

    func clearAudio() {
        registerUndo()
        resetAudioState()
    }

    private func resetAudioState() {
        audioDurationRequestID &+= 1
        audioURL = nil
        audioName = nil
        audioDuration = 0
    }

    // MARK: - Item list ops

    func selectItem(_ id: ClipItem.ID) {
        pauseTimelinePlayback()
        selectItemInternal(id)
        selectedIDs = [id]
        selectedLibraryIDs = []
    }

    private func selectItemInternal(_ id: ClipItem.ID,
                                    sourceTime requestedSourceTime: Double? = nil,
                                    timelinePosition requestedTimelinePosition: Double? = nil) {
        player?.pause()
        // Reframing targets one clip. Moving to another leaves the mode rather
        // than silently retargeting the handles at a different picture.
        if activeItemID != id { endGeometryEditing() }
        activeItemID = id
        guard let item = activeItem else { detachObserver(); player = nil; return }
        let itemTimelineStart = timelineStart(for: item.id) ?? 0

        if item.isImage {
            detachObserver(); player = nil
            let target = min(max(0, requestedSourceTime ?? 0), item.displayDuration)
            currentTime = target
            timelineTime = requestedTimelinePosition ?? (itemTimelineStart + target)
            return
        }
        let sourceURL = normalizedSourceURL(item.url)
        // Warm the scrub player on the active source so hovering this clip shows
        // its first frame instantly instead of loading an item mid-sweep.
        scrub.prepare(url: sourceURL)
        let p = players[sourceURL] ?? {
            let np = AVPlayer(url: sourceURL); np.actionAtItemEnd = .pause
            players[sourceURL] = np; return np
        }()
        player = p
        attachObserver(to: p)
        let target = min(max(item.inPoint, requestedSourceTime ?? item.inPoint), item.outPoint)
        currentTime = target
        timelineTime = requestedTimelinePosition
            ?? (itemTimelineStart + min(max(0, target - item.inPoint), item.contentDuration))
        seekPlayer(to: target)
    }

    // MARK: - Visual selection

    func selectOnly(_ id: ClipItem.ID) {
        selectedIDs = [id]
        selectedLibraryIDs = []
        focusedPane = .timeline
    }

    func toggleSelection(_ id: ClipItem.ID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        selectedLibraryIDs = []
        focusedPane = .timeline
    }

    /// ⌘A on the timeline: every clip becomes selected, ready for a bulk Delete.
    /// The playhead and the active clip stay where they are.
    func selectAllItems() {
        guard !items.isEmpty else { return }
        selectedIDs = Set(items.map(\.id))
        selectedLibraryIDs = []
        focusedPane = .timeline
    }

    /// ⌘A in the sidebar. Filtered-out cards are not selected: Delete would
    /// otherwise remove assets the user cannot even see.
    func selectAllLibraryAssets() {
        let visible = visibleLibraryAssets
        guard !visible.isEmpty else { return }
        selectedLibraryIDs = Set(visible.map(\.id))
        selectedIDs = []
        focusedPane = .library
    }

    /// ⌘A: whichever pane is in play selects everything it is showing. Returns
    /// false when that pane has nothing to select, leaving the keystroke free.
    @discardableResult
    func selectAllInFocusedPane() -> Bool {
        if timelineHasFocus {
            guard !items.isEmpty else { return false }
            selectAllItems()
        } else {
            guard !visibleLibraryAssets.isEmpty else { return false }
            selectAllLibraryAssets()
        }
        return true
    }

    func clearSelection() {
        selectedIDs = []
        selectedLibraryIDs = []
    }

    func selectLibraryAsset(_ id: LibraryAsset.ID) {
        selectedLibraryIDs = [id]
        selectedIDs = []
        focusedPane = .library
        // The sidebar's counterpart to `pauseTimelinePlayback`: touching a card
        // means the search field is done, and a search field that silently kept
        // focus would keep swallowing ⌘A and every single-key shortcut.
        endTextEditing()
    }

    func toggleLibrarySelection(_ id: LibraryAsset.ID) {
        if selectedLibraryIDs.contains(id) {
            selectedLibraryIDs.remove(id)
        } else {
            selectedLibraryIDs.insert(id)
        }
        selectedIDs = []
        focusedPane = .library
        endTextEditing()
    }

    /// Remove every selected clip. The playhead lands on the nearest remaining
    /// clip and nothing stays visually selected afterwards.
    func removeSelectedItems() {
        guard !selectedIDs.isEmpty else { return }
        pauseTimelinePlayback()
        clearTimelineHover()
        registerUndo()
        removeItemsInternal(selectedIDs)
        reconcileVideoCaches()
    }

    /// Shared clip-removal core (no undo registration — the caller owns the step).
    private func removeItemsInternal(_ ids: Set<ClipItem.ID>) {
        let firstRemovedIndex = items.firstIndex { ids.contains($0.id) } ?? 0
        let activeRemoved = activeItemID.map { ids.contains($0) } ?? false
        items.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        guard !items.isEmpty else {
            activeItemID = nil
            player = nil
            currentTime = 0
            timelineTime = 0
            detachObserver()
            return
        }
        if activeRemoved {
            selectItemInternal(items[min(firstRemovedIndex, items.count - 1)].id)
        } else {
            syncTimelineTimeFromActive()
        }
    }

    /// Move several clips as one ordered group. Selected clips do not need to be
    /// adjacent: they are lifted out, retain their relative project order, then
    /// are inserted together at the pointed gap. Translating the pre-move gap
    /// into the reduced array keeps drops correct on either side of the group.
    /// A drop that produces the existing order is intentionally not undoable.
    func moveItems(_ ids: Set<ClipItem.ID>, to insertionIndex: Int) {
        pauseTimelinePlayback()
        guard !ids.isEmpty else { return }
        let target = min(max(0, insertionIndex), items.count)
        let moving = items.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }

        let movingIDs = Set(moving.map(\.id))
        let removedBeforeTarget = items.prefix(target).reduce(into: 0) { count, item in
            if movingIDs.contains(item.id) { count += 1 }
        }
        var reordered = items.filter { !movingIDs.contains($0.id) }
        let destination = min(max(0, target - removedBeforeTarget), reordered.count)
        reordered.insert(contentsOf: moving, at: destination)
        guard reordered.map(\.id) != items.map(\.id) else { return }

        registerUndo()
        items = reordered
        syncTimelineTimeFromActive()
    }

    // MARK: - Selected-item editing

    func beginImageDurationEditing(for id: ClipItem.ID) {
        pauseTimelinePlayback()
        guard items.contains(where: { $0.id == id && $0.isImage }) else { return }
        guard imageDurationEditingSession?.itemID != id else { return }
        imageDurationEditingSession = (id, snapshot(), false)
    }

    func endImageDurationEditing(for id: ClipItem.ID) {
        guard imageDurationEditingSession?.itemID == id else { return }
        imageDurationEditingSession = nil
    }

    func setImageDuration(_ seconds: Double, for id: ClipItem.ID) {
        pauseTimelinePlayback()
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isImage else { return }
        let newValue = max(0.1, seconds)
        guard newValue != items[index].outPoint else { return }
        if var session = imageDurationEditingSession, session.itemID == id {
            if !session.hasRegisteredUndo {
                registerUndo(session.undoSnapshot)
                session.hasRegisteredUndo = true
                imageDurationEditingSession = session
            }
        } else {
            registerUndo()
        }
        items[index].outPoint = newValue
        if activeItemID == id {
            currentTime = min(currentTime, items[index].displayDuration)
            syncTimelineTimeFromActive()
        }
    }

    func setTrimStart(_ time: Double, for id: ClipItem.ID) {
        pauseTimelinePlayback()
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isImage else { return }
        let item = items[index]
        let g = item.grid
        let idx = min(max(g.firstDisplayedFrame, g.nearestBoundary(to: time)),
                      item.trimEndFrame - 1)
        let newValue = g.boundary(idx)
        guard newValue != item.inPoint else { return }
        registerUndo()
        items[index].inPoint = newValue
        if activeItemID == id {
            currentTime = max(currentTime, items[index].inPoint)
            seekPlayer(to: currentTime)
            syncTimelineTimeFromActive()
        }
    }

    func setTrimEnd(_ time: Double, for id: ClipItem.ID) {
        pauseTimelinePlayback()
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isImage else { return }
        let item = items[index]
        let g = item.grid
        let idx = min(max(item.trimStartFrame + 1, g.nearestBoundary(to: time)),
                      g.frameCount)
        let newValue = g.boundary(idx)
        guard newValue != item.outPoint else { return }
        registerUndo()
        items[index].outPoint = newValue
        // The pad exists to carry audio past a specific final frame. Once that
        // frame moves, black held after it is just black.
        items[index].videoPadDuration = 0
        if activeItemID == id {
            currentTime = min(currentTime, items[index].outPoint)
            seekPlayer(to: currentTime)
            syncTimelineTimeFromActive()
        }
    }

    func setInHere() {
        guard let id = activeItemID else { return }
        setTrimStart(activeEditSourceTime, for: id)
    }

    func setOutHere() {
        guard let id = activeItemID else { return }
        setTrimEnd(activeEditSourceTime, for: id)
    }

    /// Below this a pad is not a decision worth offering: a quarter second of
    /// black to rescue a quarter second of room tone is a worse movie.
    static let minimumWorthwhilePad = 0.25

    /// Acknowledge a source tail. This is deliberately *not* an edit — export
    /// already caps original audio at the final video boundary and rebuilds the
    /// container, so the recorded caps change nothing about the output. They
    /// only retire the warning. Snapshot undo restores it.
    func dismissTrailingOverhang(for id: ClipItem.ID) {
        pauseTimelinePlayback()
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].trailingOverhangDuration > 1e-9 else { return }
        registerUndo()
        dismissTrailingOverhang(at: index)
    }

    /// Retire every outstanding tail warning at once. Safe as a bulk action
    /// precisely because dismissing cannot change the exported movie.
    func dismissAllTrailingOverhangs() {
        pauseTimelinePlayback()
        let targets = items.indices.filter { items[$0].trailingOverhangDuration > 1e-9 }
        guard !targets.isEmpty else { return }
        registerUndo()
        for index in targets { dismissTrailingOverhang(at: index) }
    }

    private func dismissTrailingOverhang(at index: Int) {
        // Cap at the padded boundary, not the final frame: a clip that was
        // already extended keeps the audio its black tail exists to carry.
        if items[index].audioTailDuration > 1e-9 {
            items[index].audioOutPoint = items[index].paddedOutPoint
        }
        if items[index].containerTailDuration > 1e-9 {
            items[index].containerOutPoint = items[index].paddedOutPoint
        }
    }

    var clipsWithTrailingOverhang: Int {
        items.reduce(0) { $0 + ($1.trailingOverhangDuration > 1e-9 ? 1 : 0) }
    }

    var canExtendVideoToAudioTail: Bool {
        (activeItem?.videoPadCandidate ?? 0) >= Self.minimumWorthwhilePad
    }

    /// Append black video so the whole source-audio tail plays. Unlike
    /// dismissing, this *is* an edit: the clip, the movie and the exported file
    /// all grow, and the added frames are real black frames in the output.
    func extendVideoToAudioTail(for id: ClipItem.ID) {
        pauseTimelinePlayback()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let pad = items[index].videoPadCandidate
        guard pad > 1e-9 else { return }
        registerUndo()
        items[index].videoPadDuration += pad
        // The audio that motivated the pad now runs to the end of it. Anything
        // the container carries beyond that stays an unacknowledged tail.
        items[index].audioOutPoint = items[index].paddedOutPoint
        syncTimelineTimeFromActive()
    }

    /// Ask the timeline view to zoom until a clip's tail reads as a length
    /// rather than a mark, and to bring that boundary into view. The model has
    /// no viewport width, so the view consumes the request — same pattern as
    /// auto-fit.
    func zoomToTail(for id: ClipItem.ID) {
        guard let item = items.first(where: { $0.id == id }),
              item.trailingOverhangDuration > 1e-9,
              let start = timelineStart(for: id) else { return }
        setTimelineScale(24 / item.trailingOverhangDuration)
        timelineZoomRequestCounter &+= 1
        timelineZoomRequest = TimelineZoomRequest(id: timelineZoomRequestCounter,
                                                  time: start + item.displayDuration)
    }

    /// The playhead as an editable frame boundary strictly inside the active
    /// clip. Keeping the outer boundaries out of this operation avoids turning
    /// a one-sided trim into an accidental whole-clip deletion.
    private var activeInteriorEdit: (id: ClipItem.ID, sourceTime: Double)? {
        guard let item = activeItem, !item.isImage else { return nil }
        let grid = item.grid
        let boundary = grid.nearestBoundary(to: activeEditSourceTime)
        guard boundary > item.trimStartFrame, boundary < item.trimEndFrame else { return nil }
        return (item.id, grid.boundary(boundary))
    }

    var canDeleteBeforePlayhead: Bool { activeInteriorEdit != nil }
    var canDeleteAfterPlayhead: Bool { activeInteriorEdit != nil }

    /// Ripple-trim the active clip from its previous edit point to the playhead.
    func deleteBeforePlayhead() {
        guard let edit = activeInteriorEdit else { return }
        setTrimStart(edit.sourceTime, for: edit.id)
    }

    /// Ripple-trim the active clip from the playhead to its next edit point.
    func deleteAfterPlayhead() {
        guard let edit = activeInteriorEdit else { return }
        setTrimEnd(edit.sourceTime, for: edit.id)
    }

    /// Split the selected video item at the playhead into two items.
    func splitAtPlayhead() {
        pauseTimelinePlayback()
        guard let i = activeIndex, !items[i].isImage else { return }
        let seg = items[i]
        let g = seg.grid
        let idx = g.nearestBoundary(to: activeEditSourceTime)
        guard idx > seg.trimStartFrame, idx < seg.trimEndFrame else { return }
        let t = g.boundary(idx)
        registerUndo()
        // The pad hangs off the source's final frame, so it belongs to whichever
        // half still ends there.
        var left = seg; left.outPoint = t; left.videoPadDuration = 0
        let right = ClipItem(url: seg.url, kind: .video, naturalWidth: seg.naturalWidth,
                            naturalHeight: seg.naturalHeight, sourceDuration: seg.sourceDuration,
                            fps: seg.fps, fpsRational: seg.fpsRational,
                            hasAudio: seg.hasAudio, frameTimes: seg.frameTimes,
                            inPoint: t, outPoint: seg.outPoint,
                            containerStartTime: seg.containerStartTime,
                            videoStartTime: seg.videoStartTime,
                            videoDuration: seg.videoDuration,
                            frameEndTime: seg.frameEndTime,
                            audioStartTime: seg.audioStartTime,
                            audioDuration: seg.audioDuration,
                            audioOutPoint: seg.audioOutPoint,
                            containerOutPoint: seg.containerOutPoint,
                            videoPadDuration: seg.videoPadDuration)
        items[i] = left
        items.insert(right, at: i + 1)
        selectItem(right.id)
    }

    // MARK: - Transport

    private func attachObserver(to p: AVPlayer) {
        detachObserver()
        timeObserverGeneration &+= 1
        let generation = timeObserverGeneration
        let itemID = activeItemID
        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)
        observedPlayer = p
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Paused seeks update model time synchronously. Letting delayed
                // AVPlayer callbacks write during that state is what moved the
                // playhead left after the first click.
                guard self.isTimelinePlaying,
                      self.timeObserverGeneration == generation,
                      self.observedPlayer === p,
                      self.player === p,
                      self.activeItemID == itemID else { return }
                guard let item = self.activeItem, !item.isImage else { return }
                if t.seconds >= item.outPoint - item.frameDuration / 2 {
                    p.pause()
                    self.currentTime = item.outPoint
                    self.syncTimelineTimeFromActive()
                    if self.isTimelinePlaying, !self.isAdvancingPlayback {
                        Task { @MainActor [weak self] in
                            self?.playVideoPadThenAdvance(after: item.id)
                        }
                    }
                } else {
                    self.currentTime = max(item.inPoint, t.seconds)
                    self.syncTimelineTimeFromActive()
                }
            }
        }
    }

    private func detachObserver() {
        timeObserverGeneration &+= 1
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observedPlayer = nil
    }

    private func seekPlayer(to t: Double) {
        // Seek just inside the frame. Some sources use uncommon time bases (for
        // example 1/12796800), so even a 60000 timescale can round a boundary
        // backwards and leave the preview one frame behind the model.
        // The out point is an exclusive edit boundary, so preview it using the
        // final retained frame rather than the first frame that will be dropped.
        let previewTime: Double
        if let item = activeItem, !item.isImage,
           t >= item.outPoint - 1e-9 {
            let lastRetainedFrame = max(item.trimStartFrame, item.trimEndFrame - 1)
            previewTime = item.grid.time(ofFrame: lastRetainedFrame)
        } else {
            previewTime = t
        }
        player?.seek(to: interiorFrameTime(previewTime),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Step the playhead by whole frames, walking the real frame grid so a step
    /// always lands on the next/previous picture even on VFR sources. Stepping
    /// past a clip edge moves onto the neighbouring clip.
    func stepFrame(_ delta: Int) {
        pauseTimelinePlayback()
        guard delta != 0, let hit = timelineHit(at: timelineTime) else { return }
        let item = items[hit.itemIndex]
        if item.isImage {
            let frameDuration = 1.0 / canvas.fpsValue
            seekTimeline(to: min(max(0, timelineTime + Double(delta) * frameDuration),
                                 totalOutputDuration))
            return
        }
        let g = item.grid
        let firstFrame = item.trimStartFrame
        let endFrame = max(firstFrame + 1, item.trimEndFrame)
        let idx = g.frameIndex(containing: hit.sourceTime) + delta
        if idx < firstFrame {
            seekTimeline(to: max(0, hit.timelineStart - 1e-4))
        } else if idx >= endFrame {
            seekTimeline(to: min(totalOutputDuration, hit.timelineEnd + 1e-4))
        } else {
            seekTimeline(to: hit.timelineStart + (g.time(ofFrame: idx) - item.inPoint))
        }
    }

    func togglePlay() {
        if isTimelinePlaying {
            pauseTimelinePlayback()
            return
        }
        guard hasProject else { return }
        if timelineTime >= totalOutputDuration - 1e-6 {
            seekTimeline(to: 0)
        } else if activeItem == nil {
            // Deselected (e.g. by clicking empty space): resume from the playhead
            // instead of restarting the whole movie.
            seekTimeline(to: timelineTime)
        }
        isTimelinePlaying = true
        playCurrentTimelineItem()
    }

    /// Return keyboard focus from any time/frame text field to the timeline, so
    /// single-key shortcuts (delete, space, q/w, s/i/o…) act on the selected clip.
    func endTextEditing() {
        isTextEditing = false
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private func pauseTimelinePlayback() {
        // Every timeline interaction lands here, making it the natural spot to
        // reclaim focus from the text fields.
        endTextEditing()
        let wasPlaying = isTimelinePlaying
        isTimelinePlaying = false
        player?.pause()
        imagePlaybackTask?.cancel()
        imagePlaybackTask = nil
        isAdvancingPlayback = false
        // Playback reports time every ~30ms, so pausing almost always lands
        // between two frame boundaries. Snap the committed playhead onto the
        // nearest frame so it lines up with the frame cells and future cuts.
        if wasPlaying, let item = activeItem, !item.isImage {
            let snapped = min(max(item.inPoint, snap(currentTime)), item.outPoint)
            currentTime = snapped
            seekPlayer(to: snapped)
            syncTimelineTimeFromActive()
        }
    }

    private func playCurrentTimelineItem() {
        guard isTimelinePlaying, let item = activeItem else {
            pauseTimelinePlayback()
            return
        }
        if item.isImage {
            let initialTime = currentTime
            let remaining = max(0, item.displayDuration - initialTime)
            guard remaining > 1e-6 else {
                advanceTimelinePlayback(after: item.id)
                return
            }
            imagePlaybackTask?.cancel()
            imagePlaybackTask = Task { [weak self] in
                let startedAt = Date()
                while !Task.isCancelled {
                    guard let self, self.isTimelinePlaying, self.activeItemID == item.id else { return }
                    let elapsed = Date().timeIntervalSince(startedAt)
                    self.currentTime = min(item.displayDuration, initialTime + elapsed)
                    self.syncTimelineTimeFromActive()
                    if self.currentTime >= item.displayDuration - 1e-6 { break }
                    try? await Task.sleep(for: .milliseconds(33))
                }
                guard !Task.isCancelled, let self, self.isTimelinePlaying,
                      self.activeItemID == item.id else { return }
                self.advanceTimelinePlayback(after: item.id)
            }
        } else {
            // Resuming with the playhead already inside the black tail must run
            // the tail, not rewind the clip: `currentTime` is pinned to the out
            // point there, which the restart check below would read as "ended".
            if isPlayheadInVideoPad {
                playVideoPadThenAdvance(after: item.id)
                return
            }
            guard let player else {
                pauseTimelinePlayback()
                return
            }
            if currentTime >= item.outPoint - item.frameDuration / 2 {
                currentTime = item.inPoint
                seekPlayer(to: item.inPoint)
                syncTimelineTimeFromActive()
            }
            player.play()
        }
    }

    /// Play a clip's black tail, then continue to the next clip. Nothing decodes
    /// here — the player has already stopped on the final frame — so the pad
    /// advances on wall-clock time, exactly the way a still image's span does.
    private func playVideoPadThenAdvance(after itemID: ClipItem.ID) {
        guard isTimelinePlaying,
              let item = items.first(where: { $0.id == itemID }), item.hasVideoPad,
              let start = timelineStart(for: itemID) else {
            advanceTimelinePlayback(after: itemID)
            return
        }
        let padEnd = start + item.displayDuration
        let initial = min(max(start + item.contentDuration, timelineTime), padEnd)
        guard padEnd - initial > 1e-6 else {
            advanceTimelinePlayback(after: itemID)
            return
        }
        player?.pause()
        timelineTime = initial
        imagePlaybackTask?.cancel()
        imagePlaybackTask = Task { [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                guard let self, self.isTimelinePlaying,
                      self.activeItemID == itemID else { return }
                self.timelineTime = min(padEnd, initial + Date().timeIntervalSince(startedAt))
                if self.timelineTime >= padEnd - 1e-6 { break }
                try? await Task.sleep(for: .milliseconds(33))
            }
            guard !Task.isCancelled, let self, self.isTimelinePlaying,
                  self.activeItemID == itemID else { return }
            self.advanceTimelinePlayback(after: itemID)
        }
    }

    private func advanceTimelinePlayback(after itemID: ClipItem.ID) {
        guard isTimelinePlaying, !isAdvancingPlayback,
              let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        isAdvancingPlayback = true
        player?.pause()
        imagePlaybackTask?.cancel()
        imagePlaybackTask = nil

        if let next = items[safe: index + 1] {
            selectItemInternal(next.id)
            isAdvancingPlayback = false
            playCurrentTimelineItem()
        } else {
            if let last = items.last {
                currentTime = last.isImage ? last.displayDuration : last.outPoint
            }
            timelineTime = totalOutputDuration
            isTimelinePlaying = false
            isAdvancingPlayback = false
        }
    }

    // MARK: - Export

    private static let exportFolderDefaultsKey = "exportFolderPath"

    /// Default filename (no extension) offered by the export setup sheet.
    var suggestedExportName: String {
        items.first { $0.displayDuration > 1e-3 }?
            .url.deletingPathExtension().lastPathComponent ?? "成品"
    }

    /// Last folder the user exported into, falling back to ~/Movies.
    var defaultExportFolder: URL {
        if let path = UserDefaults.standard.string(forKey: Self.exportFolderDefaultsKey),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Canvas geometry

    /// Reframing is a mode rather than always-on handles, because the keys it
    /// needs are already spoken for: arrows step frames, space plays, Q/W/S cut.
    /// The same `shortcutButtons` gate that stands aside for text entry stands
    /// aside for this.
    var geometryEditing: GeometryEditMode?
    var isGeometryEditing: Bool { geometryEditing != nil }

    /// One undo step per drag, not per pixel. Mirrors the image-duration
    /// slider's session: the snapshot is only pushed once the gesture actually
    /// changes something, so a click that moves nothing costs no history.
    @ObservationIgnored private var geometryGestureSession: (
        itemID: ClipItem.ID,
        undoSnapshot: ProjectSnapshot,
        hasRegisteredUndo: Bool
    )?

    func beginGeometryEditing(_ mode: GeometryEditMode = .crop) {
        guard activeItem != nil else { return }
        pauseTimelinePlayback()
        clearTimelineHover()
        geometryEditing = mode
    }

    func endGeometryEditing() {
        geometryEditing = nil
        geometryGestureSession = nil
    }

    func toggleGeometryEditing() {
        isGeometryEditing ? endGeometryEditing() : beginGeometryEditing()
    }

    func beginGeometryGesture(for id: ClipItem.ID) {
        guard geometryGestureSession?.itemID != id else { return }
        geometryGestureSession = (id, snapshot(), false)
    }

    func endGeometryGesture() {
        geometryGestureSession = nil
    }

    /// Arrows move by one chroma step, so a nudge always lands somewhere the
    /// export can reproduce exactly rather than on a coordinate ffmpeg would
    /// quietly round off.
    static let geometryNudgeStep = 2

    func nudgeGeometry(dx: Int, dy: Int, coarse: Bool = false) {
        guard let mode = geometryEditing, let item = activeItem else { return }
        let step = Self.geometryNudgeStep * (coarse ? 10 : 1)
        switch mode {
        case .crop:
            let source = item.sourcePixelSize
            var crop = item.geometry.sourceCrop
                ?? PixelRect(x: 0, y: 0, width: source.width, height: source.height)
            crop.x += dx * step
            crop.y += dy * step
            setSourceCrop(crop, for: item.id)
        case .position:
            setGeometryOffset(PixelOffset(x: item.geometry.offset.x + dx * step,
                                          y: item.geometry.offset.y + dy * step),
                              for: item.id)
        }
    }

    /// Where `item` lands on the canvas. The same resolver export uses, so the
    /// preview cannot drift from the file.
    func placement(for item: ClipItem) -> Placement? {
        guard item.sourcePixelSize.isUsable else { return nil }
        return FFTools.resolve(item.geometry, source: item.sourcePixelSize, canvas: canvas)
    }

    func placement(forItemID id: ClipItem.ID) -> Placement? {
        items.first { $0.id == id }.flatMap(placement(for:))
    }

    /// Canvas presets offered alongside the derived size. 1080-based rather than
    /// 4K so a reframe never silently upscales a typical source.
    static let canvasPresets: [(label: String, size: PixelSize)] = [
        ("橫式 16:9 · 1920×1080", PixelSize(width: 1920, height: 1080)),
        ("直式 9:16 · 1080×1920", PixelSize(width: 1080, height: 1920)),
        ("方形 1:1 · 1080×1080", PixelSize(width: 1080, height: 1080)),
    ]

    func setCanvasSizing(_ sizing: CanvasSizing) {
        guard sizing != canvasSizing else { return }
        pauseTimelinePlayback()
        registerUndo()
        canvasSizing = sizing
    }

    func setSourceCrop(_ rect: PixelRect?, for id: ClipItem.ID) {
        updateGeometry(for: id) { geometry, source in
            guard let rect else { geometry.sourceCrop = nil; return }
            guard let snapped = rect.snappedToChromaGrid(in: source) else { return }
            geometry.sourceCrop = snapped.coversWholeFrame(of: source) ? nil : snapped
        }
    }

    func setFitMode(_ fit: FitMode, for id: ClipItem.ID) {
        updateGeometry(for: id) { geometry, _ in geometry.fit = fit }
    }

    func setGeometryScale(_ scale: Double, for id: ClipItem.ID) {
        updateGeometry(for: id) { geometry, _ in
            geometry.scale = min(max(0.05, scale), 8)
        }
    }

    func setGeometryOffset(_ offset: PixelOffset, for id: ClipItem.ID) {
        updateGeometry(for: id) { [canvas] geometry, _ in
            // Keep a nudge from throwing the picture off the canvas entirely.
            // Export would paint the segment black, which is never what a drag
            // that overshot by a few pixels meant.
            geometry.offset = PixelOffset(
                x: min(max(-canvas.width, offset.x), canvas.width),
                y: min(max(-canvas.height, offset.y), canvas.height))
        }
    }

    func resetGeometry(for id: ClipItem.ID) {
        updateGeometry(for: id) { geometry, _ in geometry = ClipGeometry() }
    }

    /// Copy one clip's framing onto every other clip. The crop is expressed in
    /// source pixels, so it is re-snapped against each target's own frame size
    /// rather than assumed to fit.
    func applyGeometryToAllItems(from id: ClipItem.ID) {
        guard let source = items.first(where: { $0.id == id })?.geometry else { return }
        guard items.count > 1 else { return }
        pauseTimelinePlayback()
        registerUndo()
        for index in items.indices where items[index].id != id {
            var geometry = source
            if let crop = source.sourceCrop {
                let size = items[index].sourcePixelSize
                geometry.sourceCrop = crop.snappedToChromaGrid(in: size)
                    .flatMap { $0.coversWholeFrame(of: size) ? nil : $0 }
            }
            items[index].geometry = geometry
        }
    }

    /// One undo step per call, and never one for a no-op: the inspector's number
    /// fields re-send their value on every keystroke and on focus changes.
    private func updateGeometry(for id: ClipItem.ID,
                                _ change: (inout ClipGeometry, PixelSize) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let source = items[index].sourcePixelSize
        var updated = items[index].geometry
        change(&updated, source)
        guard updated != items[index].geometry else { return }
        pauseTimelinePlayback()
        if var session = geometryGestureSession, session.itemID == id {
            if !session.hasRegisteredUndo {
                registerUndo(session.undoSnapshot)
                session.hasRegisteredUndo = true
                geometryGestureSession = session
            }
        } else {
            registerUndo()
        }
        items[index].geometry = updated
    }

    /// True when `url` is a clip or the music track this project reads from.
    /// Exporting there is supported, but it consumes the source.
    func isSourceMedia(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return (items.map(\.url) + [audioURL].compactMap { $0 })
            .contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == target }
    }

    func rememberExportFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.exportFolderDefaultsKey)
    }

    /// Resolve the UI model into FFmpeg cuts. Kept as a separate, testable step:
    /// an unacknowledged source tail is visible on the timeline, but original
    /// audio is still capped at the exclusive final-video boundary here.
    func assemblyItemsForExport() -> [AssemblyItem] {
        items.filter { $0.displayDuration > 1e-3 }.map { item -> AssemblyItem in
            if item.isImage {
                return AssemblyItem(url: item.url, isImage: true,
                                    trimStartFrame: 0, trimEndFrame: 0,
                                    trimStart: 0, trimEnd: item.displayDuration,
                                    duration: item.displayDuration, hasAudio: false,
                                    sourceSize: item.sourcePixelSize,
                                    geometry: item.geometry)
            }
            // Resolve the in/out points to indices in the real frame grid: the cut
            // lands on exactly the frames the preview showed, no matter how the
            // source's timestamps sit relative to the nominal k/fps lattice.
            let g = item.grid
            let startFrame = item.trimStartFrame
            let endFrame = max(startFrame + 1, item.trimEndFrame)
            let start = g.boundary(startFrame)
            let end = g.boundary(endFrame)
            let audioEnd: Double?
            if let sourceEnd = item.sourceAudioEndTime,
               let explicitCap = item.audioOutPoint {
                audioEnd = min(sourceEnd, explicitCap)
            } else {
                audioEnd = item.audioOutPoint ?? item.sourceAudioEndTime
            }
            // Keep absolute media timing here. FFTools translates it into the
            // input-local clock ffmpeg exposes without `-copyts`, preserves any
            // delayed track start as silence, and caps/pads the segment to video.
            let pad = max(0, item.videoPadDuration)
            return AssemblyItem(url: item.url, isImage: false,
                                trimStartFrame: startFrame, trimEndFrame: endFrame,
                                trimStart: start, trimEnd: end,
                                duration: end - start + pad,
                                hasAudio: item.hasAudio,
                                inputStartTime: item.containerStartTime,
                                audioStartTime: item.audioStartTime,
                                audioEndTime: audioEnd,
                                padDuration: pad,
                                sourceSize: item.sourcePixelSize,
                                geometry: item.geometry)
        }
    }

    func export(to outURL: URL) {
        guard let ff, hasProject else { return }
        let assemblyItems = assemblyItemsForExport()
        guard !assemblyItems.isEmpty else { errorMessage = "沒有可輸出的素材。"; return }
        let canvas = self.canvas
        let audio = self.audioURL
        isExporting = true
        exportProgress = 0
        exportResult = nil
        exportDestination = outURL
        exportStartDate = Date()
        exportElapsed = nil
        errorMessage = nil

        exportTask = Task {
            do {
                self.exportResult = try await ff.exportAssembly(
                    items: assemblyItems, audioURL: audio,
                    canvas: canvas, output: outURL,
                    onProgress: { [weak self] p in
                        Task { @MainActor [weak self] in self?.exportProgress = p }
                    })
            } catch is CancellationError {
                // ffmpeg only ever wrote to FFTools' scratch file, which it removes
                // itself; anything already sitting at outURL is the user's and stays.
            } catch {
                self.errorMessage = (error as? FFError)?.errorDescription ?? error.localizedDescription
            }
            self.exportElapsed = self.exportStartDate.map { -$0.timeIntervalSinceNow }
            self.isExporting = false
            self.exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
