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

    var body: some View {
        VStack(spacing: 0) {
            if model.ffMissing { ffmpegBanner }
            editor
        }
        .frame(minWidth: 1120, minHeight: 760)
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
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { loadDropped($0) }
        .sheet(isPresented: $exportSheet) { exportSheetContent }
        .onChange(of: model.errorMessage) { _, msg in
            if msg != nil { exportSheet = false }   // let the error alert stand alone
        }
        .alert("發生錯誤", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
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
                    .background(.black)
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
                .padding(12)
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            committedPreview

            // Stays mounted so the scrub player's layer keeps its last frame and
            // never re-fades between hovers; only visible while scrubbing a video
            // clip. It draws behind the HUD overlay below.
            ScrubPlayerSurface(player: model.scrubPlayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(model.timelinePreview?.showsScrubPlayer == true ? 1 : 0)
                .allowsHitTesting(false)

            if let timelinePreview = model.timelinePreview {
                timelinePreviewOverlay(timelinePreview)
            }
        }
    }

    @ViewBuilder
    private var committedPreview: some View {
        if let item = model.activeItem {
            if item.isImage {
                ImagePreview(url: item.url)
            } else if let player = model.player {
                PlayerSurface(player: player)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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

    @ViewBuilder
    private func timelinePreviewOverlay(_ hover: TimelinePreview) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let imageURL = hover.imageURL {
                ImagePreview(url: imageURL)
            } else {
                // Video frames are drawn by the ScrubPlayerSurface layered behind.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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

    private var shortcutButtons: some View {
        Group {
            Button("") { model.stepFrame(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.stepFrame(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.stepFrame(-10) }.keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("") { model.stepFrame(10) }.keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("") { model.deleteBeforePlayhead() }.keyboardShortcut("q", modifiers: [])
            Button("") { model.deleteAfterPlayhead() }.keyboardShortcut("w", modifiers: [])
            Button("") { model.splitAtPlayhead() }.keyboardShortcut("s", modifiers: [])
            Button("") { model.requestTimelineAutoFit() }.keyboardShortcut("z", modifiers: .shift)
            Button("") {
                if model.selectedLibraryIDs.isEmpty {
                    model.removeSelectedItems()
                } else {
                    model.removeSelectedLibraryAssets()
                }
            }.keyboardShortcut(.delete, modifiers: [])
        }
        .disabled(model.isTextEditing)   // don't fire single-key shortcuts while typing a time
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
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

/// AVKit's SwiftUI `VideoPlayer` always draws its own transport controls, which
/// sit dead under `allowsHitTesting(false)`. Wrap `AVPlayerView` with controls
/// off instead — playback is driven entirely by the app's own transport.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private struct ImagePreview: View {
    let url: URL
    @State private var img: NSImage?
    var body: some View {
        ZStack {
            Color.black
            if let img { Image(nsImage: img).resizable().scaledToFit() } else { ProgressView() }
        }
        .task(id: url) { img = NSImage(contentsOf: url) }
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

/// First frame of the first timeline clip, previewed before the output exists.
private func loadFirstItemThumbnail(_ model: EditorModel) async -> (video: CGImage?, image: NSImage?) {
    guard let item = model.items.first else { return (nil, nil) }
    if item.isImage { return (nil, NSImage(contentsOf: item.url)) }
    return (await model.thumbnailer(for: item.url)?.exactFrame(at: item.inPoint), nil)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                Text("輸出成品").font(.headline)
                Spacer()
                Text(exportSummaryText(model))
                    .font(.caption).foregroundStyle(.secondary)
            }

            ExportThumbnail(cgImage: videoThumb, nsImage: imageThumb)

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

            if destinationExists {
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

/// Letterboxed preview frame shared by both export sheet states.
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

            ExportThumbnail(cgImage: videoThumb, nsImage: imageThumb)

            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("正在輸出成品…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((model.exportProgress * 100).rounded()))%")
                        .font(.title3.weight(.medium)).monospacedDigit()
                }
                ProgressView(value: model.exportProgress)
                    .progressViewStyle(.linear)
                HStack {
                    Text("已用 \(shortClock(elapsed))")
                    Spacer()
                    Text(remainingText)
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
            thumb = await Thumbnailer(url: result.outputURL).exactFrame(at: 0)
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

#Preview {
    ContentView(model: EditorModel())
}
