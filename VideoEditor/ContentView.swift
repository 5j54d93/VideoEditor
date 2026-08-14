//
//  ContentView.swift
//  VideoEditor
//

import SwiftUI
import AVKit
import AppKit
import Combine
import Synchronization

struct ContentView: View {
    let model: EditorModel
    @State private var exportSheet = false
    /// Reframing is occasional work, so its pane stays out of the way until
    /// asked for — and the preview, which is the thing being judged, gets the
    /// width back. Remembered across launches: someone who reframes every
    /// project should not have to reopen it every time.
    @AppStorage("showsGeometryInspector") private var showsInspector = false
    @State private var selectAllKey = SelectAllKeyMonitor()
    @State private var viewport = StageViewport()

    var body: some View {
        VStack(spacing: 0) {
            if model.ffMissing { ffmpegBanner }
            // The error sheet hangs off `editor` rather than the outer stack so it
            // never contends with the export sheet's own presentation anchor.
            editor
                .sheet(isPresented: errorPresented) {
                    ErrorSheet(message: model.errorMessage ?? "") { model.errorMessage = nil }
                }
        }
        .frame(minWidth: 1120, minHeight: 760)
        .onAppear {
            selectAllKey.install {
                guard !model.isTextEditing else { return false }
                return model.selectAllInFocusedPane()
            }
        }
        .onDisappear { selectAllKey.remove() }
        .toolbar {
            if model.hasProject {
                ToolbarItem(placement: .primaryAction) {
                    Button { startExport() } label: {
                        Label("輸出", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonBorderShape(.circle)
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.isExporting || model.ffMissing)
                    .help("輸出成品（⌘E）")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showsInspector.toggle() } label: {
                        Label("版面", systemImage: showsInspector ? "crop.rotate" : "crop")
                            .labelStyle(.iconOnly)
                    }
                    .buttonBorderShape(.circle)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help("畫布尺寸與片段裁剪（⌥⌘I）")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { loadDropped($0) }
        .sheet(isPresented: $exportSheet) { exportSheetContent }
        .onChange(of: model.errorMessage) { _, msg in
            if msg != nil { exportSheet = false }   // let the error sheet stand alone
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    private func startExport() {
        model.exportResult = nil               // reopen in setup state, not last result
        exportSheet = true
    }

    // MARK: Toolbar / empty

    private var ffmpegBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("App 內附的影片處理工具遺失或無法執行，請重新下載或安裝 VideoEditor。")
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Editor

    /// 素材庫｜預覽 在上、時間軸吃滿整個下方；兩條分割線都可拖。
    private var editor: some View {
        VSplitView {
            HSplitView {
                LibraryPanel(model: model)
                    .frame(minWidth: 230, idealWidth: 300, maxWidth: 460)
                preview
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                    // Darker than the canvas is black, so the canvas reads as an
                    // object sitting on the pane rather than as the pane itself.
                    .background(Color(white: 0.13))
                if model.hasProject && showsInspector {
                    GeometryInspector(model: model)
                        .frame(minWidth: 250, idealWidth: 290, maxWidth: 400)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            bottomPane
                .frame(maxWidth: .infinity, minHeight: 250, maxHeight: .infinity)
        }
        .background { shortcutButtons }
    }

    /// The output timeline (transport controls live in its header row). Lives
    /// under an adjustable split divider, so the timeline can be given more
    /// height than the preview.
    private var bottomPane: some View {
        VStack(spacing: 0) {
            if let item = model.activeItem, item.isImage {
                imageControls(item)
                Divider()
            }
            TimelineView(model: model)
                // The toolbar row is the first thing in the timeline, and the
                // pane's inset is the air above it — match it to the 7pt the
                // timeline itself leaves underneath so the row sits centred.
                .padding(.top, TimelineView.headerSpacing)
                .padding([.horizontal, .bottom], 12)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if model.isGeometryEditing, let item = model.activeItem {
            reframingStage(item)
        } else {
            playbackPreview
        }
    }

    @ViewBuilder
    private var playbackPreview: some View {
        ZStack(alignment: .bottomLeading) {
            committedPreview

            // A padded clip's tail is genuinely black in the exported file, so
            // neither the frozen final frame nor a stale scrub frame may stand
            // in for it. Canvas-shaped, because that is the shape of the black.
            if model.isPlayheadInVideoPad || model.timelinePreview?.isBlackPad == true {
                CanvasStage(canvas: model.canvas, placement: nil, sourceSize: .zero) {
                    Color.black
                }
                .allowsHitTesting(false)
            }

            scrubPreviewLayer

            if let hover = model.timelinePreview, let imageURL = hover.imageURL {
                CanvasStage(canvas: model.canvas,
                            placement: model.placement(forItemID: hover.itemID),
                            sourceSize: model.items.first { $0.id == hover.itemID }?
                                .sourcePixelSize ?? .zero) {
                    ImagePreview(url: imageURL)
                }
                .allowsHitTesting(false)
            }

            if let timelinePreview = model.timelinePreview {
                timelinePreviewHUD(timelinePreview)
            }
        }
        // Double-clicking the picture is the other way in, alongside C and the
        // inspector's button.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard model.activeItem != nil else { return }
            model.beginGeometryEditing()
        }
    }

    // MARK: Reframing

    /// One stage. There used to be two — one showing the source with a crop box,
    /// one showing the canvas composition — because a crop and a placement were
    /// separate things. They are one rectangle now, and under the default
    /// canvas-aspect lock that rectangle *is* the output frame, so there is
    /// nothing left for a second picture to tell you.
    @ViewBuilder
    private func reframingStage(_ item: ClipItem) -> some View {
        VStack(spacing: 0) {
            reframingBar(item)
            Divider().opacity(0.4)
            cropStage(item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Deliberately does not reveal the inspector. The stage carries the
        // readout, the presets and the zoom, and forcing the pane open would
        // write over a stored preference the user set on purpose.
        .onAppear { viewport = StageViewport() }
    }

    private func reframingBar(_ item: ClipItem) -> some View {
        HStack(spacing: 10) {
            // Presets set the rectangle; they are not modes that stay switched
            // on. Only fit and fill survive as live framings, because only they
            // have something worth re-deriving when the canvas changes.
            Button("完整放入") { model.setFraming(.automatic(.fit), for: item.id) }
            Button("填滿") { model.setFraming(.automatic(.fill), for: item.id) }
            Button("原尺寸") { model.setActualSizeFraming(for: item.id) }
            Button("重設") { model.resetGeometry(for: item.id) }
                .disabled(item.geometry.isIdentity)

            Divider().frame(height: 16)

            aspectLockMenu(item)

            Spacer(minLength: 8)

            Text(verbatim: "方向鍵微調 \(EditorModel.geometryNudgeStep)px．⇧ ×10")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .layoutPriority(-1)     // first thing to go when the pane narrows

            Button { model.endGeometryEditing() } label: {
                HStack(spacing: 5) {
                    Text("完成")
                    KeyCapHint("↩", prominent: true)
                }
            }
            .keyboardShortcut(.defaultAction)
            .fixedSize()                // the way out never gets clipped
        }
        .font(.callout)
        .buttonStyle(.link)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(white: 0.17))
    }

    private func aspectLockMenu(_ item: ClipItem) -> some View {
        Menu {
            Picker("比例", selection: Binding(
                get: { item.geometry.aspectLock },
                set: { model.setAspectLock($0, for: item.id) }
            )) {
                Text("畫布比例").tag(AspectLock.canvas)
                Text("9:16").tag(AspectLock.ratio(width: 9, height: 16))
                Text("1:1").tag(AspectLock.ratio(width: 1, height: 1))
                Text("4:3").tag(AspectLock.ratio(width: 4, height: 3))
                Text("16:9").tag(AspectLock.ratio(width: 16, height: 9))
                Text("原始比例").tag(AspectLock.source)
                Text("自由").tag(AspectLock.free)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(aspectLockLabel(item.geometry.aspectLock),
                  systemImage: item.geometry.aspectLock == .free ? "lock.open" : "lock")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("裁剪框的比例限制")
    }

    private func aspectLockLabel(_ lock: AspectLock) -> String {
        switch lock {
        case .canvas: return "畫布比例"
        case .ratio(let w, let h): return "\(w):\(h)"
        case .source: return "原始比例"
        case .free: return "自由"
        }
    }

    private func cropStage(_ item: ClipItem) -> some View {
        CropStage(source: item.sourcePixelSize,
                  window: model.window(for: item),
                  canvasAspect: Double(model.canvas.width) / Double(max(1, model.canvas.height)),
                  lockedAspect: model.lockedAspect(for: item),
                  viewport: $viewport,
                  onChange: { model.setFraming(.window($0), for: item.id) },
                  onGestureBegin: { model.beginGeometryGesture(for: item.id) },
                  onGestureEnd: { model.endGeometryGesture() }) { scale in
            let usesNearestNeighbour = StageViewport.usesNearestNeighbour(
                pointsPerSourcePixel: scale)
            if item.isImage {
                ImagePreview(
                    url: item.url,
                    interpolation: usesNearestNeighbour ? .none : .high)
            } else if let player = model.player {
                CropVideoPreview(
                    player: player,
                    thumbnailer: model.thumbnailer(for: item.url),
                    time: item.grid.time(ofFrame: model.currentFrameIndex),
                    request: CropFrameRequest(
                        url: item.url,
                        frameIndex: model.currentFrameIndex,
                        sourceRevision: model.videoSourceRevision(for: item.url)),
                    interpolation: usesNearestNeighbour ? .none : .high)
            }
        }
    }

    /// Stays mounted so the scrub player's layer keeps its last frame and never
    /// re-fades between hovers; only visible while scrubbing a video clip. It is
    /// framed by the *hovered* clip's geometry, which need not be the selected
    /// clip's.
    @ViewBuilder
    private var scrubPreviewLayer: some View {
        let hovered = model.timelinePreview.flatMap { hover in
            model.items.first { $0.id == hover.itemID }
        }
        CanvasStage(canvas: model.canvas,
                    placement: hovered.flatMap { model.placement(for: $0) },
                    sourceSize: hovered?.sourcePixelSize ?? .zero) {
            ScrubPlayerSurface(player: model.scrubPlayer, videoGravity: .resize)
        }
        .opacity(model.timelinePreview?.showsScrubPlayer == true ? 1 : 0)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var committedPreview: some View {
        if let item = model.activeItem {
            CanvasStage(canvas: model.canvas,
                        placement: model.placement(for: item),
                        sourceSize: item.sourcePixelSize) {
                if item.isImage {
                    ImagePreview(url: item.url)
                } else if let player = model.player {
                    PlayerSurface(player: player)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "film.stack").font(.title).foregroundStyle(.tertiary)
                Text(model.hasProject ? "點擊時間軸上的片段以選取並預覽"
                     : model.hasLibrary ? "把素材拖到下方時間軸開始剪輯"
                     : "先在左側素材庫加入影片、圖片或音檔")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Just the readout. The hovered frame itself is drawn by the canvas layers
    /// beneath, so this must not cover them.
    @ViewBuilder
    private func timelinePreviewHUD(_ hover: TimelinePreview) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 7) {
                Image(systemName: "cursorarrow.motionlines")
                Text(clockText(hover.timelineTime))
                    .font(.system(.caption, design: .monospaced))
                Text("預覽")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .padding(10)
        }
        .allowsHitTesting(false)
    }

    private func imageControls(_ item: ClipItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            Text("圖片顯示秒數").font(.callout)
            Slider(
                value: Binding(
                    get: { item.displayDuration },
                    set: { model.setImageDuration($0, for: item.id) }
                ),
                in: 0.2...20,
                onEditingChanged: { isEditing in
                    if isEditing {
                        model.beginImageDurationEditing(for: item.id)
                    } else {
                        model.endImageDurationEditing(for: item.id)
                    }
                }
            )
                .frame(width: 260)
            Text(String(format: "%.1f 秒", item.displayDuration))
                .font(.system(.callout, design: .monospaced)).frame(width: 64, alignment: .leading)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Export progress / result sheet

    @ViewBuilder
    private var exportSheetContent: some View {
        Group {
            if model.isExporting {
                ExportProgressSheet(model: model) {
                    model.cancelExport()
                    exportSheet = false
                }
            } else if let result = model.exportResult {
                ExportDoneSheet(model: model, result: result) { exportSheet = false }
            } else {
                ExportSetupSheet(model: model,
                                 start: { model.export(to: $0) },
                                 cancel: { exportSheet = false })
            }
        }
        .frame(width: 440)
    }

    // MARK: Keyboard

    /// One hidden button per key equivalent, branching inside on the mode.
    ///
    /// Registering the same shortcut twice and separating the pair with
    /// `.disabled` does not work: SwiftUI picks one of the two, and if it picks
    /// the disabled one the key does nothing at all. Reframing needs the arrows
    /// the transport already owns, so the two behaviours share a button.
    private var shortcutButtons: some View {
        Group {
            Button("") { arrow(dx: -1, dy: 0) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { arrow(dx: 1, dy: 0) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { arrow(dx: 0, dy: -1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { arrow(dx: 0, dy: 1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { arrow(dx: -1, dy: 0) }.keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { arrow(dx: 1, dy: 0) }.keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { arrow(dx: 0, dy: -1) }.keyboardShortcut(.upArrow, modifiers: .shift)
            Button("") { arrow(dx: 0, dy: 1) }.keyboardShortcut(.downArrow, modifiers: .shift)

            Button("") { whileEditing { model.togglePlay() } }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { whileEditing { model.deleteBeforePlayhead() } }
                .keyboardShortcut("q", modifiers: [])
            Button("") { whileEditing { model.deleteAfterPlayhead() } }
                .keyboardShortcut("w", modifiers: [])
            Button("") { whileEditing { model.splitAtPlayhead() } }
                .keyboardShortcut("s", modifiers: [])
            Button("") { whileEditing { model.requestTimelineAutoFit() } }
                .keyboardShortcut("z", modifiers: .shift)
            Button("") {
                whileEditing {
                    if model.timelineHasFocus {
                        model.removeSelectedItems()
                    } else {
                        model.removeSelectedLibraryAssets()
                    }
                }
            }.keyboardShortcut(.delete, modifiers: [])

            Button("") { model.toggleGeometryEditing() }.keyboardShortcut("c", modifiers: [])
            // Esc leaves the mode rather than reverting: every change is already
            // live and already on the undo stack, and giving Esc two meanings
            // only makes people afraid to press it.
            Button("") { model.endGeometryEditing() }.keyboardShortcut(.cancelAction)
        }
        .disabled(model.isTextEditing)   // don't fire single-key shortcuts while typing a time
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    /// Arrows step frames normally and nudge the framing while reframing.
    ///
    /// Shift is read from the event rather than distinguished by a second
    /// `keyboardShortcut`: with both `[]` and `.shift` registered for one key,
    /// which of the two SwiftUI picks is not guaranteed, and picking the plain
    /// one silently turns a coarse nudge into a fine one. Reading the flag makes
    /// either match produce the same, correct result.
    private func arrow(dx: Int, dy: Int) {
        let coarse = NSEvent.modifierFlags.contains(.shift)
        if model.isGeometryEditing {
            model.nudgeGeometry(dx: dx, dy: dy, coarse: coarse)
        } else if dy == 0 {
            model.stepFrame(dx * (coarse ? 10 : 1))
        }
    }

    /// Timeline edits stand aside while the preview is an editing surface.
    private func whileEditing(_ action: () -> Void) {
        guard !model.isGeometryEditing else { return }
        action()
    }

    // MARK: Helpers

    private func clockText(_ s: Double) -> String { timeFieldText(s) }

    private func loadDropped(_ providers: [NSItemProvider]) -> Bool {
        let urlProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        let loadedURLs = Mutex(Array<URL?>(repeating: nil, count: urlProviders.count))
        let group = DispatchGroup()
        for (index, provider) in urlProviders.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                loadedURLs.withLock { $0[index] = url }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = loadedURLs.withLock { $0.compactMap { $0 } }
            if !urls.isEmpty { model.importAssets(urls) }
        }
        return true
    }
}

/// ⌘A has to be taken before the main menu sees it: AppKit's stock "全部選取"
/// item sits ahead of anything the app adds and claims the key equivalent, so a
/// menu command of our own never fires while the timeline is what the user is
/// aiming at. A local key monitor runs before `sendEvent:` reaches the menu,
/// giving the timeline first claim — and it declines the key whenever a text
/// field is being typed into, leaving select-all to the text.
@MainActor
final class SelectAllKeyMonitor {
    private var monitor: Any?

    /// `handle` returns true when it consumed ⌘A, false to let it pass through.
    func install(_ handle: @escaping @MainActor () -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "a",
                  MainActor.assumeIsolated({ handle() }) else { return event }
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// AVKit's SwiftUI `VideoPlayer` always draws its own transport controls, which
/// sit dead under `allowsHitTesting(false)`. Wrap `AVPlayerView` with controls
/// off instead — playback is driven entirely by the app's own transport.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        // The canvas stage has already sized this view to the picture's exact
        // aspect; letterboxing again would inset the frame within its placement.
        view.videoGravity = .resize
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Only ever drawn inside a `CanvasStage`, which has already sized the frame to
/// the picture's exact aspect — so the image fills it rather than fitting into
/// it, and the black behind it belongs to the canvas.
private struct ImagePreview: View {
    let url: URL
    /// `.none` past the zoom where interpolation turns a pixel edge into a
    /// gradient — the boundary being placed has to stay visibly where it is.
    var interpolation: Image.Interpolation = .medium
    @State private var img: NSImage?
    var body: some View {
        ZStack {
            if let img {
                Image(nsImage: img).resizable().interpolation(interpolation)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) { img = NSImage(contentsOf: url) }
    }
}

/// Identity for one native-resolution crop preview request. Frame index is
/// stable on VFR sources where tiny time-coordinate differences should still
/// describe the same real picture; source revision invalidates a re-import.
private struct CropFrameRequest: Hashable {
    let url: URL
    let frameIndex: Int
    let sourceRevision: Int
}

/// AVPlayerLayer is ideal while a movie is moving, but a paused layer may keep
/// the raster it produced for the small fit-to-pane view and simply magnify it.
/// Crop mode swaps in an exact, native-resolution still for inspection while
/// retaining the player underneath as the immediate loading/failure fallback.
private struct CropVideoPreview: View {
    let player: AVPlayer
    let thumbnailer: Thumbnailer?
    let time: Double
    let request: CropFrameRequest
    let interpolation: Image.Interpolation

    @State private var frame: CGImage?

    var body: some View {
        ZStack {
            if let frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(interpolation)
            } else {
                RawPlayerSurface(
                    player: player,
                    usesNearestNeighbour: interpolation == .none)
            }
        }
        .task(id: request) {
            frame = nil
            let decoded = await thumbnailer?.fullResolutionFrame(at: time)
            guard !Task.isCancelled else { return }
            frame = decoded
        }
    }
}

/// "m:ss.mmm" (milliseconds truncated, matching frame-boundary display).
private func timeFieldText(_ s: Double) -> String {
    let x = max(0, s)
    return String(format: "%d:%02d.%03d", Int(x) / 60, Int(x) % 60, Int((x - floor(x)) * 1000))
}

// MARK: - Export sheet

/// Whole seconds as "m:ss" (or "h:mm:ss"), for elapsed / remaining readouts.
private func shortClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

private func tildePath(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}

private func fpsText(_ fps: Double) -> String {
    fps == fps.rounded() ? String(format: "%.0f", fps) : String(format: "%.3f", fps)
}

/// "N 段 · 時長 · 解析度 @ fps" shown by the setup and progress sheets.
private func exportSummaryText(_ model: EditorModel) -> String {
    let c = model.canvas
    return "\(model.items.count) 段 · \(shortClock(model.totalOutputDuration))"
        + " · \(c.width)×\(c.height) @ \(fpsText(c.fpsValue))fps"
}

/// Everything needed to draw the source picture as the first output frame.
/// Pure and testable: the view consumes this exact resolved placement instead
/// of rebuilding an approximation of FFmpeg's geometry in the export sheet.
struct ExportPreviewDescriptor: Equatable {
    let itemID: ClipItem.ID
    let url: URL
    let isImage: Bool
    let sourceTime: Double
    let sourceSize: PixelSize
    let placement: Placement?

    static func first(in items: [ClipItem], canvas: CanvasSpec) -> Self? {
        guard let item = items.first(where: \.isExportable) else { return nil }
        let sourceSize = item.sourcePixelSize
        let placement = sourceSize.isUsable
            ? FFTools.resolve(item.geometry, source: sourceSize, canvas: canvas)
            : nil
        // Export cuts videos by this exact frame index. Deriving the timestamp
        // from the same grid avoids a future inPoint/PTS rounding drift.
        let sourceTime = item.isImage ? 0 : item.grid.time(ofFrame: item.trimStartFrame)
        return Self(itemID: item.id, url: item.url, isImage: item.isImage,
                    sourceTime: sourceTime, sourceSize: sourceSize,
                    placement: placement)
    }
}

private func exportPreviewDescriptor(_ model: EditorModel) -> ExportPreviewDescriptor? {
    ExportPreviewDescriptor.first(in: model.items, canvas: model.canvas)
}

/// First frame of the first rendered clip. Geometry is applied by
/// `ExportCompositionThumbnail`; decode the source picture here without the
/// filmstrip's 480px ceiling so a tight crop still has enough detail at 216pt.
private func loadFirstItemThumbnail(_ model: EditorModel) async -> (video: CGImage?, image: NSImage?) {
    guard let preview = exportPreviewDescriptor(model) else { return (nil, nil) }
    if preview.isImage { return (nil, NSImage(contentsOf: preview.url)) }
    return (await model.thumbnailer(for: preview.url)?
        .fullResolutionFrame(at: preview.sourceTime), nil)
}

/// Filename + destination form shown when 輸出 is clicked, replacing NSSavePanel.
private struct ExportSetupSheet: View {
    let model: EditorModel
    let start: (URL) -> Void
    let cancel: () -> Void

    @State private var filename = ""
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser
    @State private var videoThumb: CGImage?
    @State private var imageThumb: NSImage?
    @FocusState private var nameFocused: Bool

    var body: some View {
        let preview = exportPreviewDescriptor(model)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                Text("輸出成品").font(.headline)
                Spacer()
                Text(exportSummaryText(model))
                    .font(.caption).foregroundStyle(.secondary)
            }

            ExportCompositionThumbnail(
                canvas: model.canvas,
                placement: preview?.placement,
                sourceSize: preview?.sourceSize ?? .zero,
                cgImage: videoThumb,
                nsImage: imageThumb)

            VStack(alignment: .leading, spacing: 6) {
                Text("檔名").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("成品", text: $filename)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                    Text(".mp4").font(.callout).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("位置").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(tildePath(folder))
                        .font(.callout)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("選擇…") { pickFolder() }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.08)))
            }

            if destinationIsSource {
                Label("這個檔案也是本專案的素材，輸出後原始檔會被成品取代",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if destinationExists {
                Label("同名檔案已存在，輸出時會覆蓋", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button { cancel() } label: {
                    HStack(spacing: 5) {
                        Text("取消")
                        KeyCapHint("Esc", font: .body)
                    }
                    .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                Button { startExport() } label: {
                    HStack(spacing: 5) {
                        Text("開始輸出")
                        KeyCapHint("↩", prominent: true, font: .body)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(cleanName.isEmpty)
            }
            .controlSize(.large)
            .padding(.top, 2)
        }
        .padding(24)
        .onAppear {
            filename = model.suggestedExportName
            folder = model.defaultExportFolder
        }
        .onChange(of: nameFocused) { _, focused in model.isTextEditing = focused }
        .onDisappear { model.isTextEditing = false }
        .task { (videoThumb, imageThumb) = await loadFirstItemThumbnail(model) }
    }

    /// Typed name minus a redundant ".mp4" and path-hostile characters.
    private var cleanName: String {
        var name = filename.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(".mp4") { name = String(name.dropLast(4)) }
        return name.replacingOccurrences(of: "/", with: "-")
                   .replacingOccurrences(of: ":", with: "-")
    }

    private var destinationURL: URL { folder.appendingPathComponent(cleanName + ".mp4") }

    private var destinationExists: Bool {
        !cleanName.isEmpty && FileManager.default.fileExists(atPath: destinationURL.path)
    }

    private var destinationIsSource: Bool {
        destinationExists && model.isSourceMedia(destinationURL)
    }

    private func startExport() {
        guard !cleanName.isEmpty else { return }
        model.rememberExportFolder(folder)
        start(destinationURL)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "選擇"
        panel.message = "選擇輸出資料夾"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}

/// Before FFmpeg has produced a file, draw the first source frame through the
/// same canvas/placement layout as the editor. The old export sheet displayed a
/// raw, aspect-fitted source thumbnail here, so every crop, cover, scale and
/// offset vanished precisely in the UI that called itself the output preview.
private struct ExportCompositionThumbnail: View {
    let canvas: CanvasSpec
    let placement: Placement?
    let sourceSize: PixelSize
    let cgImage: CGImage?
    var nsImage: NSImage? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            if cgImage != nil || nsImage != nil {
                CanvasStage(canvas: canvas, placement: placement, sourceSize: sourceSize) {
                    sourceImage
                }
            } else {
                Image(systemName: "film").font(.title2).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 216)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var sourceImage: some View {
        if let cgImage {
            Image(decorative: cgImage, scale: 1).resizable().interpolation(.high)
        } else if let nsImage {
            Image(nsImage: nsImage).resizable().interpolation(.high)
        }
    }
}

/// The finished file's actual decoded first frame.
private struct ExportThumbnail: View {
    let cgImage: CGImage?
    var nsImage: NSImage? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            if let cgImage {
                Image(decorative: cgImage, scale: 1).resizable().scaledToFit()
            } else if let nsImage {
                Image(nsImage: nsImage).resizable().scaledToFit()
            } else {
                Image(systemName: "film").font(.title2).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 216)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Live progress: destination, first-frame preview, percentage with elapsed /
/// estimated-remaining, and a one-line summary of what's being written.
private struct ExportProgressSheet: View {
    let model: EditorModel
    let cancel: () -> Void
    @State private var videoThumb: CGImage?
    @State private var imageThumb: NSImage?
    @State private var now = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let preview = exportPreviewDescriptor(model)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.12))
                    .frame(width: 36, height: 36)
                    .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.exportDestination?.lastPathComponent ?? "成品")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    if let destination = model.exportDestination {
                        Text("輸出到 \(tildePath(destination.deletingLastPathComponent()))")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            ExportCompositionThumbnail(
                canvas: model.canvas,
                placement: preview?.placement,
                sourceSize: preview?.sourceSize ?? .zero,
                cgImage: videoThumb,
                nsImage: imageThumb)

            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("正在輸出成品…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(percent)%")
                        .font(.title3.weight(.medium)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(percent)))
                        .animation(.default, value: percent)
                }
                ProgressView(value: model.exportProgress)
                    .progressViewStyle(.linear)
                HStack {
                    Text("已用 \(shortClock(elapsed))")
                        .contentTransition(.numericText(value: elapsed.rounded()))
                        .animation(.default, value: elapsed.rounded())
                    Spacer()
                    Text(remainingText)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.default, value: remainingText)
                }
                .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }

            Divider()

            HStack {
                Text(exportSummaryText(model)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .cancel) { cancel() } label: {
                    HStack(spacing: 5) {
                        Text("取消")
                        KeyCapHint("Esc", font: .body)
                    }
                }
                .keyboardShortcut(.cancelAction)
                .help("中止輸出並刪除寫到一半的檔案")
            }
        }
        .padding(24)
        .onReceive(timer) { now = $0 }
        .task { (videoThumb, imageThumb) = await loadFirstItemThumbnail(model) }
    }

    private var percent: Int { Int((model.exportProgress * 100).rounded()) }

    private var elapsed: Double {
        guard let start = model.exportStartDate else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    /// Naive linear estimate; hidden until there's enough signal to be useful.
    private var remainingText: String {
        let p = model.exportProgress
        guard p > 0.02, elapsed > 1 else { return "預估剩餘 --:--" }
        return "預估剩餘 \(shortClock(elapsed / p * (1 - p)))"
    }

}

/// Finished: the exported file's real first frame, its vitals, and reveal / done.
private struct ExportDoneSheet: View {
    let model: EditorModel
    let result: ExportResult
    let dismiss: () -> Void
    @State private var thumb: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("輸出完成").font(.headline)
                Spacer()
                if let exportElapsed = model.exportElapsed {
                    Text("共花 \(shortClock(exportElapsed))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            ExportThumbnail(cgImage: thumb)
                .overlay(alignment: .bottomTrailing) {
                    Text(shortClock(model.totalOutputDuration))
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(result.outputURL.lastPathComponent)
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(infoLine)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                } label: {
                    Label("在 Finder 中顯示", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                Button { dismiss() } label: {
                    HStack(spacing: 5) {
                        Text("完成")
                        KeyCapHint("↩", prominent: true, font: .body)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 2)
        }
        .padding(24)
        .task(id: result.outputURL) {
            // This is the real encoded result, not a filmstrip cell. Keep its
            // native detail so a Retina export sheet does not enlarge the
            // thumbnailer's 480px overview and look softer than the file.
            thumb = await Thumbnailer(url: result.outputURL).fullResolutionFrame(at: 0)
        }
    }

    private var infoLine: String {
        var parts = [tildePath(result.outputURL.deletingLastPathComponent())]
        if let bytes = fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        let c = model.canvas
        parts.append("\(c.width)×\(c.height) @ \(fpsText(c.fpsValue))fps")
        return parts.joined(separator: " · ")
    }

    private var fileSize: Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }
}

/// Errors carry a whole ffmpeg log, which an alert would render as one unbounded
/// run of text — the window grows past the screen and takes its buttons with it.
/// A fixed-size sheet keeps the dismiss button reachable and the log scrollable.
private struct ErrorSheet: View {
    let message: String
    let dismiss: () -> Void

    /// Enough of the tail to diagnose with, without asking Text to lay out a
    /// pathological log in one pass.
    private static let detailLineLimit = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("發生錯誤").font(.headline)
                    Text(summary)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !detail.isEmpty {
                ScrollView {
                    Text(displayDetail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .defaultScrollAnchor(.bottom)   // the failure is at the tail
                .frame(height: 240)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.08)))
            }

            HStack(spacing: 10) {
                if !detail.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    } label: {
                        Label("複製完整訊息", systemImage: "doc.on.doc")
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    HStack(spacing: 5) {
                        Text("好")
                        KeyCapHint("↩", prominent: true, font: .body)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(width: 560)
    }

    private var summary: String {
        message.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? message
    }

    /// The remainder below the first line — or, when a long error arrives as a
    /// single line, the whole thing, so the truncated headline loses nothing.
    private var detail: String {
        let rest = message.split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst().joined(separator: "\n")
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return rest }
        return summary.count > 160 ? summary : ""
    }

    private var displayDetail: String {
        let lines = detail.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > Self.detailLineLimit else { return detail }
        let dropped = lines.count - Self.detailLineLimit
        return "…（前 \(dropped) 行已略過，可用「複製完整訊息」取得全文）\n"
            + lines.suffix(Self.detailLineLimit).joined(separator: "\n")
    }
}

#Preview {
    ContentView(model: EditorModel())
}
