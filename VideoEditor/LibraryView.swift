//
//  LibraryView.swift
//  VideoEditor
//
//  The media library sidebar: a searchable, filterable card grid. Cards are
//  draggable onto the timeline; the payload is "library:<uuid>" so timeline
//  drop targets can tell it apart from reorders.
//

import SwiftUI
import AppKit

struct LibraryPanel: View {
    let model: EditorModel

    @State private var cardFrames: [LibraryAsset.ID: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeRect: CGRect?
    @State private var searchText = ""
    @State private var kindFilter: AssetKind?
    @FocusState private var searchFocused: Bool

    private var filteredAssets: [LibraryAsset] {
        model.library.filter { asset in
            (kindFilter == nil || asset.kind == kindFilter)
                && (searchText.isEmpty
                    || asset.url.lastPathComponent
                        .localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.library.isEmpty {
                if model.isImporting {
                    EmptyLibraryLoadingView()
                } else {
                    EmptyLibraryButton { model.pickAndImport() }
                }
            } else {
                searchBar
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                if filteredAssets.isEmpty {
                    noMatchPlaceholder
                } else {
                    assetGrid
                }
            }
        }
        .onChange(of: searchFocused) { _, focused in model.isTextEditing = focused }
    }

    // MARK: Header / search / footer

    private var header: some View {
        HStack(spacing: 7) {
            Text("素材庫").font(.headline)
            if !model.library.isEmpty {
                Text("\(model.library.count)")
                    .font(.caption2.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.gray.opacity(0.13)))
            }
            Spacer()
            if model.isImporting && !model.library.isEmpty {
                ProgressView().controlSize(.small)
            }
            if !model.library.isEmpty {
                Button { model.pickAndImport() } label: { Image(systemName: "plus") }
                    .keyboardShortcut("i", modifiers: .command)
                    .help("加入素材（影片、圖片、音檔）（⌘I）")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("搜尋素材", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜尋")
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.09)))

            Menu {
                Picker("種類", selection: $kindFilter) {
                    Text("全部").tag(AssetKind?.none)
                    Label("影片", systemImage: "film").tag(AssetKind?.some(.video))
                    Label("圖片", systemImage: "photo").tag(AssetKind?.some(.image))
                    Label("音檔", systemImage: "music.note").tag(AssetKind?.some(.audio))
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: kindFilter == nil
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("篩選素材種類")
        }
    }

    private var noMatchPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title3).foregroundStyle(.tertiary)
            Text("沒有符合的素材")
                .font(.caption).foregroundStyle(.secondary)
            Button("清除條件") {
                searchText = ""
                kindFilter = nil
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Grid + marquee

    private var assetGrid: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 126, maximum: 240),
                                             spacing: 8)],
                          spacing: 8) {
                    ForEach(filteredAssets) { asset in
                        LibraryAssetCard(model: model, asset: asset)
                            .background {
                                GeometryReader { cardGeometry in
                                    Color.clear.preference(
                                        key: LibraryCardFramePreferenceKey.self,
                                        value: [asset.id: cardGeometry.frame(
                                            in: .named("libraryViewport"))]
                                    )
                                }
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .contentShape(Rectangle())
            .coordinateSpace(.named("libraryViewport"))
            .onPreferenceChange(LibraryCardFramePreferenceKey.self) { cardFrames = $0 }
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("libraryViewport"))
                    .onEnded { value in
                        guard !cardFrames.values.contains(where: {
                            $0.contains(value.location)
                        }) else { return }
                        model.clearSelection()
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 5,
                            coordinateSpace: .named("libraryViewport"))
                    .onChanged(updateMarquee)
                    .onEnded { _ in endMarquee() }
            )

            if let rect = marqueeRect {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
                    }
                    .frame(width: max(1, rect.width), height: max(1, rect.height))
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .frame(maxHeight: .infinity)
    }

    private func updateMarquee(_ value: DragGesture.Value) {
        if marqueeStart == nil {
            // A marquee only starts from blank space; drags that begin on a
            // card belong to drag-to-timeline.
            guard !cardFrames.values.contains(where: {
                $0.contains(value.startLocation)
            }) else { return }
            marqueeStart = value.startLocation
            model.selectedIDs = []
        }
        guard let start = marqueeStart else { return }
        let rect = CGRect(x: min(start.x, value.location.x),
                          y: min(start.y, value.location.y),
                          width: abs(value.location.x - start.x),
                          height: abs(value.location.y - start.y))
        marqueeRect = rect
        model.selectedLibraryIDs = Set(cardFrames.compactMap { id, frame in
            marqueeIntersects(rect, frame) ? id : nil
        })
    }

    private func endMarquee() {
        marqueeStart = nil
        marqueeRect = nil
    }

    private func marqueeIntersects(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.minX <= rhs.maxX && lhs.maxX >= rhs.minX
            && lhs.minY <= rhs.maxY && lhs.maxY >= rhs.minY
    }
}

// MARK: - Card

/// One asset in the library grid: a large thumbnail with a duration badge,
/// hover quick-actions, and the filename + vitals underneath.
private struct LibraryAssetCard: View {
    let model: EditorModel
    let asset: LibraryAsset
    @State private var videoThumb: CGImage?
    @State private var imageThumb: NSImage?
    @State private var hovering = false

    private var isActiveMusic: Bool { asset.kind == .audio && model.audioURL == asset.url }
    private var selected: Bool { model.selectedLibraryIDs.contains(asset.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            thumbnailArea
            VStack(alignment: .leading, spacing: 1) {
                Text(asset.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.13)
                      : hovering ? Color.gray.opacity(0.12)
                      : Color.gray.opacity(0.07))
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            // Let any single-click selection handlers finish first, then make
            // the activated card the unambiguous selection and add it once.
            DispatchQueue.main.async {
                model.selectLibraryAsset(asset.id)
                model.insertLibraryAsset(asset.id)
            }
        }
        .simultaneousGesture(
            TapGesture(count: 1).onEnded { selectFromPointer() }
        )
        .draggable("library:\(asset.id.uuidString)")
        .contextMenu { contextItems }
        .task(id: thumbnailTaskID) { await loadThumbnail() }
        .accessibilityLabel(asset.url.lastPathComponent)
    }

    private var thumbnailArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(asset.kind == .audio ? Color.gray.opacity(0.14)
                                           : Color.black.opacity(0.24))
            switch asset.kind {
            case .video:
                if let videoThumb {
                    Color.clear.overlay {
                        Image(decorative: videoThumb, scale: 1)
                            .resizable().scaledToFill()
                    }
                    .clipped()
                }
            case .image:
                if let imageThumb {
                    Color.clear.overlay {
                        Image(nsImage: imageThumb).resizable().scaledToFill()
                    }
                    .clipped()
                }
            case .audio:
                Image(systemName: isActiveMusic ? "speaker.wave.2.fill" : "waveform")
                    .font(.title3)
                    .foregroundStyle(isActiveMusic ? Color.orange : Color.secondary)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottomTrailing) {
            if let badge = durationBadge {
                Text(badge)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(Color.black.opacity(0.55),
                                in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .overlay(alignment: .topLeading) {
            if isActiveMusic {
                Text("背景音樂")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(Color.orange.opacity(0.92),
                                in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering { hoverActions }
        }
    }

    /// Quick actions in the thumbnail corner, shown only while hovering so the
    /// resting grid stays clean.
    private var hoverActions: some View {
        HStack(spacing: 4) {
            Button { primaryAction() } label: {
                Image(systemName: primaryActionIcon)
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.regularMaterial))
            }
            .buttonStyle(.plain)
            .help(primaryActionHelp)

            Button { model.removeFromLibrary(asset.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.regularMaterial))
            }
            .buttonStyle(.plain)
            .help("移除素材（含時間軸片段）")
        }
        .padding(4)
    }

    private func primaryAction() {
        if isActiveMusic {
            model.clearAudio()
        } else {
            model.insertLibraryAsset(asset.id)
        }
    }

    private var primaryActionIcon: String {
        switch asset.kind {
        case .audio: return isActiveMusic ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .video, .image: return "plus"
        }
    }

    private var primaryActionHelp: String {
        switch asset.kind {
        case .audio: return isActiveMusic ? "取消背景音樂" : "設為背景音樂"
        case .video, .image: return "加到時間軸結尾"
        }
    }

    @ViewBuilder
    private var contextItems: some View {
        if asset.kind == .audio {
            if isActiveMusic {
                Button("取消背景音樂") { model.clearAudio() }
            } else {
                Button("設為背景音樂") { model.insertLibraryAsset(asset.id) }
            }
        } else {
            Button("加到時間軸結尾") { model.insertLibraryAsset(asset.id) }
        }
        Button("移除素材（含時間軸片段）", role: .destructive) {
            model.removeFromLibrary(asset.id)
        }
    }

    private func selectFromPointer() {
        if NSEvent.modifierFlags.contains(.command) {
            model.toggleLibrarySelection(asset.id)
        } else {
            model.selectLibraryAsset(asset.id)
        }
    }

    private var thumbnailTaskID: String {
        "\(asset.id)-source\(asset.kind == .video ? model.videoSourceRevision(for: asset.url) : 0)"
    }

    private func loadThumbnail() async {
        switch asset.kind {
        case .video:
            videoThumb = nil
            let revision = model.videoSourceRevision(for: asset.url)
            let image = await model.thumbnailer(for: asset.url)?.exactFrame(at: 0)
            guard !Task.isCancelled,
                  revision == model.videoSourceRevision(for: asset.url) else { return }
            videoThumb = image
        case .image:
            imageThumb = NSImage(contentsOf: asset.url)
        case .audio:
            break
        }
    }

    private var durationBadge: String? {
        switch asset.kind {
        case .video, .audio: return mediaClock(asset.duration)
        case .image: return nil
        }
    }

    private var subtitle: String {
        switch asset.kind {
        case .video:
            let fps = asset.fps > 0 ? " · \(fpsLabel(asset.fps)) fps" : ""
            return "\(asset.width)×\(asset.height)\(fps)"
        case .image:
            return "圖片 · \(asset.width)×\(asset.height)"
        case .audio:
            return "音檔"
        }
    }
}

// MARK: - Empty state

/// Keep import progress in the user's focus while the first batch is being
/// probed. The compact header spinner is too easy to miss in an otherwise empty
/// panel, and the add button should not invite a second picker mid-import.
private struct EmptyLibraryLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("正在載入素材…")
                .font(.headline)
            Text("正在分析檔案資訊")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.1))
        )
        .padding(10)
    }
}

/// The whole empty-library area is one big, obviously clickable "+" button.
private struct EmptyLibraryButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("加入素材").font(.headline)
                    KeyCapHint("⌘I", font: .headline)
                }
                Text("影片、圖片、音檔\n也可以直接拖進來")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(hovering ? 0.17 : 0.1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .padding(10)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("i", modifiers: .command)
        .onHover { hovering = $0 }
        .help("加入素材（影片、圖片、音檔）（⌘I）")
    }
}

// MARK: - Support

private struct LibraryCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [LibraryAsset.ID: CGRect] = [:]

    static func reduce(value: inout [LibraryAsset.ID: CGRect],
                       nextValue: () -> [LibraryAsset.ID: CGRect]) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}

/// Compact media length: sub-minute assets keep a decimal ("42.5s"), longer
/// ones read as m:ss.
private func mediaClock(_ seconds: Double) -> String {
    let s = max(0, seconds)
    guard s >= 60 else { return String(format: "%.1fs", s) }
    return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
}

private func fpsLabel(_ fps: Double) -> String {
    fps == fps.rounded() ? String(format: "%.0f", fps) : String(format: "%.2f", fps)
}
