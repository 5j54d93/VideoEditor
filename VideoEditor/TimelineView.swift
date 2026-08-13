//
//  TimelineView.swift
//  VideoEditor
//
//  The canonical output timeline. Every visible clip is part of the exported
//  movie, in this exact order; trimmed-away source ranges are never drawn here.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum TimelineLaneMetrics {
    static let spacing: CGFloat = 2
    static let audioHeight: CGFloat = 28
    /// Below this a to-scale band carries no information — it is thinner than
    /// the seam between two clips. Under the threshold the tail is a mark, and
    /// the chip's zoom action is how you get to see its real length.
    static let tailBandThreshold: CGFloat = 12
    static let tailBandHeight: CGFloat = 16
    /// A band may never swallow the clip it spills onto.
    static let tailBandCoverage: CGFloat = 0.7
    static let tailChipHeight: CGFloat = 19
}

struct TimelineView: View {
    let model: EditorModel

    /// Air between the toolbar row and the ruler under it. The pane's top inset
    /// matches this, so the row is evenly spaced above and below.
    static let headerSpacing: CGFloat = 7

    private let rulerHeight: CGFloat = 24
    private let baseTrackHeight: CGFloat = 100
    private let trackCornerRadius: CGFloat = 7

    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var scrollOffset: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var pendingAutoFit = false
    @State private var magnificationContext: MagnificationContext?
    @State private var marqueeStart: CGPoint?
    @State private var marqueeRect: CGRect?
    @State private var dropInsertionIndex: Int?
    @State private var dropAutoScrollStep: CGFloat = 0
    @State private var dropAutoScrollTask: Task<Void, Never>?

    private struct MagnificationContext {
        let baseScale: Double
        let anchorTime: Double
        let anchorViewportX: CGFloat
    }

    /// One prefix-sum pass per body evaluation. Rendering and pointer geometry
    /// share these boundaries instead of repeatedly walking `model.items`.
    private struct TimelineLayout {
        struct Entry: Identifiable {
            let item: ClipItem
            let start: Double
            let end: Double

            var id: ClipItem.ID { item.id }
        }

        let entries: [Entry]
        /// Clip boundaries in seconds: index 0 is zero and index n is movie end.
        let boundaries: [Double]
        let totalDuration: Double

        init(items: [ClipItem]) {
            var entries: [Entry] = []
            entries.reserveCapacity(items.count)
            var boundaries: [Double] = [0]
            boundaries.reserveCapacity(items.count + 1)
            var start = 0.0
            for item in items {
                let end = start + item.displayDuration
                entries.append(Entry(item: item, start: start, end: end))
                boundaries.append(end)
                start = end
            }
            self.entries = entries
            self.boundaries = boundaries
            totalDuration = start
        }

        func insertionIndex(at x: CGFloat, scale: CGFloat) -> Int {
            guard !entries.isEmpty, scale > 0 else { return 0 }
            var low = 0
            var high = entries.count
            // Find the first clip midpoint strictly to the right of x. This
            // preserves the existing rule that an exact midpoint inserts after.
            while low < high {
                let mid = (low + high) / 2
                let midpoint = CGFloat((boundaries[mid] + boundaries[mid + 1]) / 2) * scale
                if x < midpoint { high = mid } else { low = mid + 1 }
            }
            return low
        }

        func insertionX(_ index: Int, scale: CGFloat) -> CGFloat {
            CGFloat(boundaries[min(max(0, index), entries.count)]) * scale
        }

        func itemID(at time: Double) -> ClipItem.ID? {
            guard !entries.isEmpty,
                  time >= 0,
                  time <= totalDuration + 1e-9 else { return nil }
            var low = 0
            var high = entries.count
            while low < high {
                let mid = (low + high) / 2
                if boundaries[mid + 1] > time { high = mid } else { low = mid + 1 }
            }
            if low < entries.count { return entries[low].id }
            return entries.last?.id
        }

        func selection(in rect: CGRect, scale: CGFloat) -> Set<ClipItem.ID> {
            Set(entries.lazy.filter { entry in
                let minX = CGFloat(entry.start) * scale
                let maxX = CGFloat(entry.end) * scale
                return rect.minX <= maxX && rect.maxX >= minX
            }.map(\.id))
        }

    }

    var body: some View {
        let layout = TimelineLayout(items: model.items)
        VStack(alignment: .leading, spacing: Self.headerSpacing) {
            header(layout: layout)

            GeometryReader { geo in
                let scale = CGFloat(model.timelinePointsPerSecond)
                let clipsWidth = CGFloat(layout.totalDuration) * scale
                let trailingWorkspace = max(360, geo.size.width * 0.72)
                let contentWidth = max(geo.size.width, clipsWidth + trailingWorkspace)
                // The drop zone always fills the pane; clips inside render at a
                // fixed height so filmstrips never get stretched.
                let trackHeight = max(baseTrackHeight, geo.size.height - rulerHeight)

                ScrollView(.horizontal, showsIndicators: true) {
                    // The chips sit outside the canvas rather than inside it: as
                    // a sibling drawn on top they absorb their own clicks, so
                    // pressing one no longer also runs the canvas-wide tap that
                    // would seek the playhead out from under you.
                    ZStack(alignment: .topLeading) {
                        canvas(layout: layout, width: contentWidth,
                               clipsWidth: clipsWidth, scale: scale,
                               viewportWidth: geo.size.width, trackHeight: trackHeight)
                        tailChips(layout: layout, width: contentWidth,
                                  scale: scale, trackHeight: trackHeight)
                    }
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self,
                                        of: { max(0, $0.contentOffset.x) }) { _, newValue in
                    scrollOffset = newValue
                }
                .onAppear {
                    updateViewportWidth(geo.size.width,
                                        totalDuration: layout.totalDuration)
                }
                .onChange(of: geo.size.width) { _, w in
                    updateViewportWidth(w, totalDuration: layout.totalDuration)
                }
                .onChange(of: model.timelineZoomRequest) { _, request in
                    guard let request else { return }
                    // The scale is already applied; scroll after the content has
                    // been re-laid out at it, or the target is clamped against
                    // the old width.
                    let x = CGFloat(request.time) * CGFloat(model.timelinePointsPerSecond)
                    DispatchQueue.main.async {
                        scrollPosition.scrollTo(x: max(0, x - geo.size.width / 3))
                    }
                }
            }
            .frame(minHeight: baseTrackHeight + rulerHeight, maxHeight: .infinity, alignment: .top)
            .onChange(of: model.timelineAutoFitRequestID) { _, _ in
                fitTimelineToViewport(totalDuration: layout.totalDuration)
            }
        }
    }

    /// Single toolbar row: transport / editing controls on the left, zoom on the
    /// right.
    private func header(layout: TimelineLayout) -> some View {
        HStack(spacing: 9) {
            Button { model.togglePlay() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "playpause.fill")
                    KeyCapHint("Space")
                }
            }
            .help("播放／暫停（空白鍵）")

            if model.activeItem?.isImage == false {
                Button { model.deleteBeforePlayhead() } label: {
                    HStack(spacing: 5) {
                        Label("刪除左側", systemImage: "delete.left")
                        KeyCapHint("Q")
                    }
                }
                .disabled(!model.canDeleteBeforePlayhead)
                .help("刪除播放頭至前一個分割點之間的內容（Q）")
                Button { model.splitAtPlayhead() } label: {
                    HStack(spacing: 5) {
                        Label("分割", systemImage: "scissors")
                        KeyCapHint("S")
                    }
                }
                .help("在播放頭分割成兩段（S）")
                Button { model.deleteAfterPlayhead() } label: {
                    HStack(spacing: 5) {
                        Label("刪除右側", systemImage: "delete.right")
                        KeyCapHint("W")
                    }
                }
                .disabled(!model.canDeleteAfterPlayhead)
                .help("刪除播放頭至下一個分割點之間的內容（W）")

                if let item = model.activeItem, item.trailingOverhangDuration > 1e-9 {
                    Button { model.dismissTrailingOverhang(for: item.id) } label: {
                        Label("忽略尾端", systemImage: "checkmark.circle")
                    }
                    .help("輸出本來就會切齊影像尾端，這只會讓提示消失")
                    if model.canExtendVideoToAudioTail {
                        Button { model.extendVideoToAudioTail(for: item.id) } label: {
                            Label("延長影像", systemImage: "rectangle.portrait.arrowtriangle.2.outward")
                        }
                        .help("在尾端補上真正的黑畫面，讓這段原音留在成品裡")
                    }
                }
            }

            if model.clipsWithTrailingOverhang > 1 {
                Button { model.dismissAllTrailingOverhangs() } label: {
                    Label("忽略全部尾端（\(model.clipsWithTrailingOverhang)）",
                          systemImage: "checkmark.circle.badge.questionmark")
                }
                .help("一次確認所有片段的尾端差異；不會改變輸出")
            }

            if !model.selectedIDs.isEmpty {
                Button(role: .destructive) { model.removeSelectedItems() } label: {
                    HStack(spacing: 5) {
                        Label(model.selectedIDs.count > 1
                              ? "刪除 \(model.selectedIDs.count) 段" : "刪除片段",
                              systemImage: "trash")
                        KeyCapHint("⌫")
                    }
                }
                .help("從成品時間軸與輸出中移除選取的片段（⌫）")
            }

            Text(headerInfo(layout: layout))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { model.timelineZoomLevel },
                set: { newLevel in
                    // Zoom about the playhead: keep it at the same viewport x while
                    // the scale changes; if it's off-screen, bring it to centre.
                    let oldScale = CGFloat(model.timelinePointsPerSecond)
                    model.timelineZoomLevel = newLevel
                    let newScale = CGFloat(model.timelinePointsPerSecond)
                    guard newScale != oldScale else { return }
                    let playheadX = CGFloat(model.timelineTime) * oldScale - scrollOffset
                    let anchorX = (playheadX >= 0 && playheadX <= viewportWidth)
                        ? playheadX : viewportWidth / 2
                    scrollPosition.scrollTo(
                        x: max(0, CGFloat(model.timelineTime) * newScale - anchorX))
                }
            ), in: 0...1)
            .frame(width: 150)
            .help("時間軸縮放")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Button {
                fitTimelineToViewport(totalDuration: layout.totalDuration)
            } label: {
                HStack(spacing: 5) {
                    Text("符合視窗")
                    KeyCapHint("⇧Z")
                }
            }
            .disabled(layout.totalDuration <= 0)
            .help("自動調整縮放，讓整個成品剛好塞進時間軸的可視寬度，並捲回開頭（⇧Z）")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func fitTimelineToViewport(width: CGFloat? = nil, totalDuration: Double) {
        let measuredWidth = width ?? viewportWidth
        guard measuredWidth > 0 else {
            pendingAutoFit = true
            return
        }
        pendingAutoFit = false
        guard totalDuration > 0 else { return }
        model.setTimelineScale(Double(max(120, measuredWidth - 24)) / totalDuration)
        // Scroll after the zoom change has re-laid the content: in the same
        // update the target is clamped against the old width and the viewport
        // stays where it was.
        DispatchQueue.main.async { scrollPosition.scrollTo(x: 0) }
    }

    private func updateViewportWidth(_ width: CGFloat, totalDuration: Double) {
        viewportWidth = width
        guard pendingAutoFit, width > 0 else { return }
        fitTimelineToViewport(width: width, totalDuration: totalDuration)
    }

    private func headerInfo(layout: TimelineLayout) -> String {
        var s = "\(layout.entries.count) 段 · \(timelineClockText(layout.totalDuration))"
        if model.hasProject {
            let c = model.canvas
            let fps = c.fpsValue == c.fpsValue.rounded()
                ? String(format: "%.0f", c.fpsValue)
                : String(format: "%.3f", c.fpsValue)
            s += " · 畫布 \(c.width)×\(c.height) @ \(fps)fps"
        }
        return s
    }

    private func canvas(layout: TimelineLayout, width: CGFloat,
                        clipsWidth: CGFloat, scale: CGFloat,
                        viewportWidth: CGFloat, trackHeight: CGFloat) -> some View {
        let visibleTimelineRange = ClosedRange(
            uncheckedBounds: (
                lower: Double(scrollOffset / scale),
                upper: Double((scrollOffset + viewportWidth) / scale)
            )
        )
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: trackCornerRadius)
                .fill(Color.gray.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: trackCornerRadius)
                        .stroke(Color.secondary.opacity(0.22))
                }
                .frame(width: width, height: trackHeight)
                .offset(y: rulerHeight)

            TimelineRuler(pointsPerSecond: scale, width: width,
                          visibleX: scrollOffset, viewportWidth: viewportWidth)
                .frame(width: width, height: rulerHeight)

            // A *plain* HStack: LazyHStack estimates the width of clips scrolled out
            // of view, which shifts every later clip's strip off the time lattice
            // (≈1 frame once the first clip left the viewport). Laziness isn't
            // needed here — the strips already load frames only for the visible
            // range internally.
            HStack(spacing: 0) {
                ForEach(layout.entries) { entry in
                    TimelineClipView(model: model, item: entry.item,
                                     timelineStart: entry.start,
                                     visibleTimelineRange: visibleTimelineRange,
                                     pointsPerSecond: scale, height: baseTrackHeight)
                }
            }
            .frame(width: clipsWidth, height: baseTrackHeight, alignment: .leading)
            .offset(y: rulerHeight + (trackHeight - baseTrackHeight) / 2)

            tailMarks(layout: layout, width: width, scale: scale, trackHeight: trackHeight)

            trailingDropZone(width: max(1, width - clipsWidth), trackHeight: trackHeight)
                .offset(x: clipsWidth, y: rulerHeight)

            if let preview = model.timelinePreview {
                Rectangle()
                    .fill(Color.white.opacity(0.72))
                    .frame(width: 1, height: trackHeight + 5)
                    .offset(x: CGFloat(preview.timelineTime) * scale, y: rulerHeight - 5)
                    .allowsHitTesting(false)
            }

            if let insertion = dropInsertionIndex {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: baseTrackHeight + 12)
                    .offset(x: layout.insertionX(insertion, scale: scale) - 1.5,
                            y: rulerHeight + (trackHeight - baseTrackHeight) / 2 - 6)
                    .allowsHitTesting(false)
            }

            playhead(scale: scale, width: width, trackHeight: trackHeight)

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
        .frame(width: width, height: rulerHeight + trackHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        // One drop surface for the whole timeline (clips, ruler, blank space,
        // trailing zone): route every reorder / library drop to the nearest
        // insertion gap — including index 0, so a clip can be moved to the very
        // start — and show a caret at that gap while dragging.
        .onDrop(of: [.text], delegate: TimelineInsertionDropDelegate(
            insertionIndex: { location in
                layout.insertionIndex(at: location.x, scale: scale)
            },
            setIndicator: { dropInsertionIndex = $0 },
            autoScroll: { location in updateDropAutoScroll(pointerX: location.x) },
            stopAutoScroll: { stopDropAutoScroll() },
            perform: { payload, index in handleTimelineDrop(payload, at: index) }
        ))
        .coordinateSpace(.named("outputTimelineCanvas"))
        .onContinuousHover(coordinateSpace: .named("outputTimelineCanvas")) { phase in
            switch phase {
            case .active(let location):
                model.updateTimelineHover(at: Double(location.x / scale))
            case .ended:
                model.clearTimelineHover()
            }
        }
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named("outputTimelineCanvas"))
                .onEnded { value in
                    model.focusedPane = .timeline
                    // ⌘-click never seeks, so it would otherwise skip the
                    // focus hand-back that every seek performs — and a search
                    // field still holding focus swallows ⌘A.
                    model.endTextEditing()
                    let clipRowTop = rulerHeight + (trackHeight - baseTrackHeight) / 2
                    let time = Double(value.location.x / scale)
                    let beforeTimelineEnd = value.location.x < clipsWidth
                    let onRuler = value.location.y <= rulerHeight
                        && beforeTimelineEnd
                    let onClips = beforeTimelineEnd
                        && value.location.y >= clipRowTop
                        && value.location.y <= clipRowTop + baseTrackHeight
                    if NSEvent.modifierFlags.contains(.command) {
                        // ⌘-click toggles a clip in/out of the selection and never
                        // moves the playhead.
                        if onClips, let itemID = layout.itemID(at: time) {
                            model.toggleSelection(itemID)
                        }
                        return
                    }
                    if onClips {
                        model.seekTimeline(to: time)
                        if let itemID = layout.itemID(at: time) {
                            model.selectOnly(itemID)
                        }
                    } else if onRuler {
                        model.seekTimeline(to: time)
                    } else {
                        // Blank space clears visual selection. The trailing workspace
                        // represents the exclusive movie-end boundary, while blank
                        // space above/below existing clips keeps its local time.
                        model.clearSelection()
                        if value.location.x >= clipsWidth {
                            model.seekTimelineToEnd()
                        } else {
                            model.seekTimeline(to: min(time, layout.totalDuration))
                        }
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named("outputTimelineCanvas"))
                .onChanged { value in
                    let clipRowTop = rulerHeight + (trackHeight - baseTrackHeight) / 2
                    if marqueeStart == nil {
                        // A marquee only starts from blank space; drags that begin
                        // on a clip belong to drag-reorder, and the ruler stays a
                        // pure seek surface.
                        let s = value.startLocation
                        let onRuler = s.y <= rulerHeight
                        let onClip = s.x <= clipsWidth
                            && s.y >= clipRowTop && s.y <= clipRowTop + baseTrackHeight
                        guard !onRuler, !onClip else { return }
                        marqueeStart = s
                        model.selectedLibraryIDs = []
                        model.focusedPane = .timeline
                        model.endTextEditing()
                    }
                    guard let start = marqueeStart else { return }
                    let rect = CGRect(x: min(start.x, value.location.x),
                                      y: min(start.y, value.location.y),
                                      width: abs(value.location.x - start.x),
                                      height: abs(value.location.y - start.y))
                    marqueeRect = rect
                    model.selectedIDs = marqueeSelection(rect, layout: layout,
                                                         scale: scale,
                                                         clipRowTop: clipRowTop)
                }
                .onEnded { _ in
                    marqueeStart = nil
                    marqueeRect = nil
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if magnificationContext == nil {
                        let base = model.timelinePointsPerSecond
                        magnificationContext = MagnificationContext(
                            baseScale: base,
                            anchorTime: Double(value.startLocation.x) / base,
                            anchorViewportX: value.startLocation.x - scrollOffset
                        )
                    }
                    guard let context = magnificationContext else { return }
                    model.setTimelineScale(context.baseScale * Double(value.magnification))
                    let anchoredX = CGFloat(context.anchorTime * model.timelinePointsPerSecond)
                        - context.anchorViewportX
                    scrollPosition.scrollTo(x: max(0, anchoredX))
                }
                .onEnded { _ in magnificationContext = nil }
        )
    }

    // MARK: Reorder / insertion drops

    private func handleTimelineDrop(_ payload: String, at index: Int) {
        if let assetID = libraryAssetID(payload) {
            model.insertLibraryAsset(assetID, at: index)
        } else {
            let itemIDs = Set(timelineItemIDs(payload))
            if !itemIDs.isEmpty { model.moveItems(itemIDs, to: index) }
        }
    }

    /// Keep scrolling while a drag hovers near a viewport edge, so a clip can be
    /// carried to parts of the timeline that start off-screen.
    private func updateDropAutoScroll(pointerX: CGFloat) {
        let viewportX = pointerX - scrollOffset
        let step: CGFloat
        if viewportX < 48 { step = -14 } else if viewportX > viewportWidth - 48 { step = 14 } else { step = 0 }
        guard step != dropAutoScrollStep else { return }
        dropAutoScrollStep = step
        dropAutoScrollTask?.cancel()
        dropAutoScrollTask = nil
        guard step != 0 else { return }
        dropAutoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                scrollPosition.scrollTo(x: max(0, scrollOffset + step))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopDropAutoScroll() {
        dropAutoScrollStep = 0
        dropAutoScrollTask?.cancel()
        dropAutoScrollTask = nil
    }

    /// Clips whose time span intersects the marquee horizontally, provided the
    /// marquee vertically overlaps the clip row.
    private func marqueeSelection(_ rect: CGRect, layout: TimelineLayout,
                                  scale: CGFloat,
                                  clipRowTop: CGFloat) -> Set<ClipItem.ID> {
        guard rect.maxY >= clipRowTop, rect.minY <= clipRowTop + baseTrackHeight else {
            return []
        }
        return layout.selection(in: rect, scale: scale)
    }

    /// Purely visual — the canvas-wide drop delegate owns the actual drop.
    private func trailingDropZone(width: CGFloat, trackHeight: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            HStack(spacing: 7) {
                Image(systemName: "plus")
                Text(model.items.isEmpty ? "從左側素材庫拖進來開始剪輯" : "拖到這裡即可接在成品後方")
            }
            .font(model.items.isEmpty ? .callout : .caption2)
            .foregroundStyle(model.items.isEmpty ? .secondary : .quaternary)
            .padding(.leading, 14)
        }
        .frame(width: width, height: trackHeight)
    }

    /// The tail's non-interactive half: a persistent 2pt mark on the boundary,
    /// plus a to-scale band once the tail is actually long enough to read as a
    /// length. Neither is hit-testable, so clicking a tail still seeks to the
    /// output time underneath it.
    private func tailMarks(layout: TimelineLayout, width: CGFloat,
                           scale: CGFloat, trackHeight: CGFloat) -> some View {
        let laneTop = laneTop(trackHeight: trackHeight)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(layout.entries.enumerated()), id: \.element.id) { index, entry in
                let tail = entry.item.trailingOverhangDuration
                if tail > 1e-9 {
                    let boundaryX = CGFloat(entry.end) * scale
                    let tailWidth = CGFloat(tail) * scale

                    // Only draw a length once a length is what it is. Below the
                    // threshold the mark carries the whole message.
                    if tailWidth >= TimelineLaneMetrics.tailBandThreshold {
                        Rectangle()
                            .fill(Color.orange.opacity(0.5))
                            .frame(width: min(tailWidth,
                                              bandLimit(after: index, layout: layout, scale: scale)),
                                   height: TimelineLaneMetrics.tailBandHeight)
                            .offset(x: boundaryX, y: laneTop)
                    }

                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 2, height: TimelineLaneMetrics.audioHeight)
                        .offset(x: max(0, boundaryX - 2), y: laneTop)
                }
            }
        }
        .frame(width: width, height: rulerHeight + trackHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The tail's interactive half. Anchored to the boundary and expanding left
    /// at its intrinsic size; because it only appears on hover or selection it
    /// may overlap its own clip freely — which is what keeps the action reachable
    /// on a clip of any length.
    private func tailChips(layout: TimelineLayout, width: CGFloat,
                           scale: CGFloat, trackHeight: CGFloat) -> some View {
        let chipTop = laneTop(trackHeight: trackHeight)
            - TimelineLaneMetrics.tailChipHeight - 3
        return ZStack(alignment: .topLeading) {
            ForEach(layout.entries) { entry in
                if entry.item.trailingOverhangDuration > 1e-9, showsTailChip(entry.id) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        TailChip(model: model, item: entry.item)
                    }
                    .frame(width: max(1, CGFloat(entry.end) * scale),
                           height: TimelineLaneMetrics.tailChipHeight,
                           alignment: .trailing)
                    .offset(y: chipTop)
                }
            }
        }
        .frame(width: width, height: rulerHeight + trackHeight, alignment: .topLeading)
    }

    /// Top of the audio lane in canvas coordinates.
    private func laneTop(trackHeight: CGFloat) -> CGFloat {
        rulerHeight + (trackHeight - baseTrackHeight) / 2
            + baseTrackHeight - TimelineLaneMetrics.audioHeight
    }

    /// A band spills onto the next clip, so it must never swallow it. The final
    /// clip spills into the empty trailing workspace, where nothing needs
    /// protecting.
    private func bandLimit(after index: Int, layout: TimelineLayout,
                           scale: CGFloat) -> CGFloat {
        guard index + 1 < layout.entries.count else { return .greatestFiniteMagnitude }
        let next = layout.entries[index + 1]
        return CGFloat(next.end - next.start) * scale * TimelineLaneMetrics.tailBandCoverage
    }

    private func showsTailChip(_ id: ClipItem.ID) -> Bool {
        model.timelinePreview?.itemID == id
            || model.activeItemID == id
            || model.selectedIDs.contains(id)
    }

    private func playhead(scale: CGFloat, width: CGFloat,
                          trackHeight: CGFloat) -> some View {
        let x = CGFloat(model.timelineTime) * scale
        return ZStack(alignment: .topLeading) {
            // Clip only the vertical line to the same rounded track boundary.
            // At time zero (and at the far edge) it now follows the corner
            // instead of drawing through the transparent area below it.
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: trackHeight)
                    .offset(x: x - 1)
            }
            .frame(width: width, height: trackHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: trackCornerRadius))
            .offset(y: rulerHeight)

            // The handle intentionally remains above the rounded track.
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 9, y: 0))
                path.addLine(to: CGPoint(x: 4.5, y: 6))
                path.closeSubpath()
            }
            .fill(Color.red)
            .frame(width: 9, height: 6)
            .offset(x: x - 4.5, y: rulerHeight - 6)
        }
        .frame(width: width, height: rulerHeight + trackHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct TimelineClipView: View {
    let model: EditorModel
    let item: ClipItem
    let timelineStart: Double
    let visibleTimelineRange: ClosedRange<Double>
    let pointsPerSecond: CGFloat
    let height: CGFloat

    private var selected: Bool { model.selectedIDs.contains(item.id) }
    private var dragPayload: String {
        let draggedItems = selected
            ? model.items.filter { model.selectedIDs.contains($0.id) }
            : [item]
        return "timeline:" + draggedItems.map { $0.id.uuidString }.joined(separator: ",")
    }
    private var width: CGFloat { CGFloat(item.displayDuration) * pointsPerSecond }
    /// The part of the clip that has real frames behind it. Anything past this
    /// is the black pad, which the filmstrip must not try to fill.
    private var contentWidth: CGFloat { CGFloat(item.contentDuration) * pointsPerSecond }
    /// Horizontal breathing room so every cut reads as a visible seam between
    /// clips. Shrinks on sliver-thin clips so they never mask themselves away.
    /// Only the drawn content is inset — the clip still owns its full time span
    /// for hit-testing, so the time↔x mapping stays exact.
    private var edgeInset: CGFloat { min(2, width / 6) }
    private var visibleLocalRange: ClosedRange<Double>? {
        let lower = max(0, visibleTimelineRange.lowerBound - timelineStart)
        let upper = min(item.contentDuration, visibleTimelineRange.upperBound - timelineStart)
        guard upper >= lower, upper >= 0, lower <= item.contentDuration else { return nil }
        return lower...upper
    }

    private var videoLaneHeight: CGFloat {
        height - TimelineLaneMetrics.audioHeight - TimelineLaneMetrics.spacing
    }

    @ViewBuilder
    var body: some View {
        Group {
            if item.isImage {
                videoLane(height: height)
            } else {
                VStack(spacing: TimelineLaneMetrics.spacing) {
                    videoLane(height: videoLaneHeight)
                    originalAudioLane
                        .frame(width: width, height: TimelineLaneMetrics.audioHeight)
                }
                .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .mask(Rectangle().padding(.horizontal, edgeInset))
        .contentShape(Rectangle())
        .overlay {
            Rectangle()
                .stroke(selected ? Color.accentColor : Color.white.opacity(0.22),
                        lineWidth: selected ? 2.5 : 1)
                .padding(.horizontal, edgeInset)
        }
        .accessibilityLabel(item.url.lastPathComponent)
        .accessibilityValue("\(String(format: "%.2f", item.displayDuration)) 秒")
        .contextMenu {
            if item.trailingOverhangDuration > 1e-9 {
                Button("忽略尾端差異") {
                    model.dismissTrailingOverhang(for: item.id)
                }
                if item.videoPadCandidate >= EditorModel.minimumWorthwhilePad {
                    Button("延長影像以保留這段原音") {
                        model.extendVideoToAudioTail(for: item.id)
                    }
                }
                Button("放大到尾端") { model.zoomToTail(for: item.id) }
            }
        }
    }

    @ViewBuilder
    private func mediaStrip(height laneHeight: CGFloat) -> some View {
        if item.isImage {
            TimelineImageStrip(url: item.url)
        } else {
            TimelineVideoStrip(
                itemID: item.id,
                sourceRevision: model.videoSourceRevision(for: item.url),
                thumbnailer: model.thumbnailer(for: item.url),
                grid: item.grid,
                start: item.inPoint,
                end: item.outPoint,
                fps: item.effectiveFps,
                pointsPerSecond: pointsPerSecond,
                width: contentWidth,
                height: laneHeight,
                visibleLocalRange: visibleLocalRange,
                preferredFrame: model.activeItemID == item.id ? model.currentFrameIndex : nil
            )
        }
    }

    private func videoLane(height laneHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // The pad is black in the exported file, so it is black here. The
            // filmstrip covers only the frames that exist.
            Color.black
            mediaStrip(height: laneHeight)
                .frame(width: max(0.01, contentWidth), height: laneHeight, alignment: .leading)
                .clipped()

            if item.hasVideoPad {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: laneHeight)
                    .offset(x: contentWidth)
            }

            LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(0.38)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: item.isImage ? "photo" : "film")
                    Text(item.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.top, 5)

                Spacer()

                Text(String(format: "%.2fs", item.displayDuration))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 7)
                    .padding(.bottom, 5)
            }

            Rectangle()
                .fill(Color.black.opacity(0.001))
                .frame(width: max(0.01, width), height: laneHeight)
                .contentShape(Rectangle())
                .draggable(dragPayload)
        }
        .frame(width: width, height: laneHeight)
        .clipped()
    }

    private var originalAudioLane: some View {
        let start = max(item.inPoint, item.audioStartTime)
        // A padded clip keeps its audio across the black: that is the entire
        // reason the black is there, and it is why the cyan visibly outruns the
        // picture on an extended clip.
        let end = min(item.paddedOutPoint, item.effectiveAudioOutPoint)
        let activeWidth = max(0, CGFloat(end - start) * pointsPerSecond)
        let activeOffset = max(0, CGFloat(start - item.inPoint) * pointsPerSecond)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(0.58))
            if item.hasAudio, activeWidth > 0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.cyan.opacity(0.34))
                    .frame(width: activeWidth)
                    .offset(x: activeOffset)
            }
            HStack(spacing: 4) {
                Image(systemName: item.hasAudio ? "waveform" : "speaker.slash")
                Text(item.hasAudio ? "原音" : "無原音")
                Spacer(minLength: 0)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(item.hasAudio ? Color.white.opacity(0.82) : Color.secondary)
            .padding(.horizontal, 6)

            // Keep the full clip draggable from either lane. The warning button
            // is layered after this surface, so its click remains independent.
            Rectangle()
                .fill(Color.black.opacity(0.001))
                .frame(width: max(0.01, width), height: TimelineLaneMetrics.audioHeight)
                .contentShape(Rectangle())
                .draggable(dragPayload)

            if item.hasVideoPad {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: TimelineLaneMetrics.audioHeight)
                    .offset(x: contentWidth)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(item.hasAudio ? "原始音訊" : "沒有原始音訊")
        .accessibilityValue(item.hasVideoPad
            ? "延長 \(String(format: "%.2f", item.videoPadDuration)) 秒黑畫面以保留原音"
            : "")
    }
}

/// The tail's interactive half. Fixed size and transient by design: it appears
/// on hover or selection, so it can overlap its own clip and stay usable no
/// matter how short that clip is — which the old in-lane button could not do.
private struct TailChip: View {
    let model: EditorModel
    let item: ClipItem

    private var sourceName: String { item.tailSource == .container ? "容器" : "原音" }
    private var canExtend: Bool {
        item.videoPadCandidate >= EditorModel.minimumWorthwhilePad
    }
    private var amount: String {
        let ms = item.trailingOverhangDuration * 1_000
        return ms >= 100 ? String(format: "%.0f ms", ms) : String(format: "%.1f ms", ms)
    }

    var body: some View {
        HStack(spacing: 5) {
            Button { model.zoomToTail(for: item.id) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "waveform.badge.exclamationmark")
                    Text("\(sourceName) +\(amount)")
                }
                .foregroundStyle(Color.orange)
            }
            .help("放大時間軸，直到這個尾端有真實長度可看")

            Divider().frame(height: 10)

            Button("忽略") { model.dismissTrailingOverhang(for: item.id) }
                .help("輸出本來就會切齊影像尾端，這只會讓提示消失")

            if canExtend {
                Button("延長影像") { model.extendVideoToAudioTail(for: item.id) }
                    .help("在尾端補上真正的黑畫面，讓這段原音留在成品裡")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .frame(height: TimelineLaneMetrics.tailChipHeight)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.28), lineWidth: 0.5)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(sourceName)比最後真實影格多出 \(amount)")
    }
}

private struct TimelineImageStrip: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
            if let image {
                Color.clear.overlay {
                    Image(nsImage: image).resizable().scaledToFill()
                }
                .clipped()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}

private struct TimelineRuler: View {
    let pointsPerSecond: CGFloat
    let width: CGFloat
    let visibleX: CGFloat
    let viewportWidth: CGFloat

    private var majorStep: Double {
        let candidates: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return candidates.first { CGFloat($0) * pointsPerSecond >= 72 } ?? 1200
    }

    /// Sub-second steps need sub-second labels, otherwise several neighbouring
    /// ticks all read the same whole second.
    private func tickLabel(_ seconds: Double) -> String {
        guard majorStep < 1 else { return timelineClockText(seconds, compact: true) }
        let m = Int(seconds) / 60
        return String(format: "%02d:%04.1f", m, seconds - Double(m * 60))
    }

    var body: some View {
        let first = max(0, Int(floor(Double(visibleX / pointsPerSecond) / majorStep)) - 1)
        let last = max(first, Int(ceil(Double((visibleX + viewportWidth) / pointsPerSecond)
                                            / majorStep)) + 1)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            ForEach(first...last, id: \.self) { index in
                let seconds = Double(index) * majorStep
                let x = CGFloat(seconds) * pointsPerSecond
                VStack(alignment: .leading, spacing: 1) {
                    Rectangle().fill(Color.secondary.opacity(0.45)).frame(width: 1, height: 6)
                    Text(tickLabel(seconds))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .offset(x: x)
            }
        }
        .clipped()
    }
}

/// The same clip surface progressively reveals more temporal detail. At normal
/// scales it uses a lightweight overview strip; once a source frame has enough
/// horizontal room it switches to exact, individually aligned frame cells.
private struct TimelineVideoStrip: View {
    let itemID: ClipItem.ID
    let sourceRevision: Int
    let thumbnailer: Thumbnailer?
    let grid: FrameGrid
    let start: Double
    let end: Double
    let fps: Double
    let pointsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    let visibleLocalRange: ClosedRange<Double>?
    let preferredFrame: Int?

    private var frameWidth: CGFloat { pointsPerSecond / CGFloat(fps) }

    @ViewBuilder
    var body: some View {
        if frameWidth >= 28 {
            ExactFrameTimelineStrip(
                itemID: itemID,
                sourceRevision: sourceRevision,
                thumbnailer: thumbnailer,
                grid: grid,
                start: start,
                end: end,
                fps: fps,
                pointsPerSecond: pointsPerSecond,
                width: width,
                height: height,
                visibleLocalRange: visibleLocalRange,
                preferredFrame: preferredFrame
            )
        } else {
            FilmstripStrip(sourceRevision: sourceRevision,
                           thumbnailer: thumbnailer, grid: grid,
                           start: start, end: end,
                           width: width, height: height)
        }
    }
}

private struct ExactFrameTimelineStrip: View {
    let itemID: ClipItem.ID
    let sourceRevision: Int
    let thumbnailer: Thumbnailer?
    let grid: FrameGrid
    let start: Double
    let end: Double
    let fps: Double
    let pointsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    let visibleLocalRange: ClosedRange<Double>?
    let preferredFrame: Int?

    @State private var frames: [Int: CGImage] = [:]
    @State private var loadedSourceRevision: Int?
    @State private var loadGeneration: UInt = 0

    private var frameWidth: CGFloat { pointsPerSecond / CGFloat(fps) }
    private var retainedFirstFrame: Int { grid.nearestBoundary(to: start) }
    private var retainedLastFrame: Int {
        max(retainedFirstFrame, grid.nearestBoundary(to: end) - 1)
    }

    private var requestedFrames: [Int] {
        guard let visibleLocalRange else { return [] }
        let buffer = max(2 / fps, Double(140 / pointsPerSecond))
        let visibleSourceStart = start + max(0, visibleLocalRange.lowerBound - buffer)
        let visibleSourceEnd = start + min(end - start, visibleLocalRange.upperBound + buffer)
        let first = max(retainedFirstFrame, grid.frameIndex(containing: visibleSourceStart))
        let last = min(retainedLastFrame, grid.frameIndex(containing: visibleSourceEnd))
        guard last >= first else { return [] }
        return Array(first...last)
    }

    /// Each cell spans its frame's real duration, so VFR cells stay aligned.
    private func cellWidth(_ frameIndex: Int) -> CGFloat {
        CGFloat(grid.boundary(frameIndex + 1) - grid.time(ofFrame: frameIndex)) * pointsPerSecond
    }

    private var requestID: String {
        guard let first = requestedFrames.first, let last = requestedFrames.last else {
            return "\(itemID)-source\(sourceRevision)-none"
        }
        return "\(itemID)-source\(sourceRevision)-\(retainedFirstFrame)-\(retainedLastFrame)-\(first)-\(last)"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.72)
            ForEach(requestedFrames, id: \.self) { frameIndex in
                frameCell(frameIndex)
                    .offset(x: CGFloat(grid.time(ofFrame: frameIndex) - start) * pointsPerSecond)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .task(id: requestID) {
            loadGeneration &+= 1
            let expectedGeneration = loadGeneration
            let expectedRequestID = requestID
            if loadedSourceRevision != sourceRevision {
                frames.removeAll(keepingCapacity: true)
                loadedSourceRevision = sourceRevision
            }
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled,
                  loadGeneration == expectedGeneration,
                  requestID == expectedRequestID else { return }
            await loadRequestedFrames(
                expectedRequestID: expectedRequestID,
                expectedGeneration: expectedGeneration
            )
        }
    }

    @ViewBuilder
    private func frameCell(_ frameIndex: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.secondary.opacity(0.13)
            if let image = frames[frameIndex] {
                // Size + clip the image itself: a bare scaledToFill inside the ZStack
                // grows the stack to the image's overflow size, which shifts the
                // clipping window (side gaps) and pushes the badge out of view.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cellWidth(frameIndex) + 0.5, height: height)
                    .clipped()
            }
            if frameWidth >= 44 {
                Text("f\(frameIndex)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        .black.opacity(0.48),
                        in: RoundedRectangle(cornerRadius: 3)
                    )
                    .padding(3)
            }
        }
        .frame(width: cellWidth(frameIndex) + 0.5, height: height)
        .clipped()
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.28)).frame(width: 1)
        }
        .overlay {
            if preferredFrame == frameIndex {
                Rectangle().stroke(Color.red.opacity(0.92), lineWidth: 2)
            }
        }
    }

    private func loadRequestedFrames(expectedRequestID: String, expectedGeneration: UInt) async {
        guard let thumbnailer else { return }
        let wanted = requestedFrames
        guard !wanted.isEmpty else { return }

        // Submit every visible cache miss together so AVFoundation can walk the
        // source once instead of making a second GOP pass for a priority cell.
        let misses = wanted.compactMap { frameIndex -> Thumbnailer.ExactRequest? in
            guard frames[frameIndex] == nil else { return nil }
            return Thumbnailer.ExactRequest(
                frameIndex: frameIndex,
                time: grid.time(ofFrame: frameIndex)
            )
        }.sorted {
            if $0.time == $1.time { return $0.frameIndex < $1.frameIndex }
            return $0.time < $1.time
        }
        let loaded = await thumbnailer.exactFrames(misses)
        guard !Task.isCancelled,
              loadGeneration == expectedGeneration,
              requestID == expectedRequestID else { return }
        frames.merge(loaded) { _, new in new }

        let retained = Set(wanted)
        frames = frames.filter { retained.contains($0.key) }
    }
}

/// Thumbnails tiling a kept source range [start, end]. The requested times and
/// rendered tile widths both scale with the clip, so the strip always fills it.
struct FilmstripStrip: View {
    let sourceRevision: Int
    let thumbnailer: Thumbnailer?
    let grid: FrameGrid
    let start: Double
    let end: Double
    let width: CGFloat
    let height: CGFloat

    @State private var tiles: [CGImage?] = []
    @State private var loadedSourceRevision: Int?

    private var tileCount: Int {
        let frameCount = max(1, grid.nearestBoundary(to: end) - grid.nearestBoundary(to: start))
        return max(1, min(120, frameCount, Int((width / 70).rounded(.up))))
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<tileCount, id: \.self) { index in
                ZStack {
                    Color.secondary.opacity(0.12)
                    if tiles.indices.contains(index), let image = tiles[index] {
                        Color.clear.overlay {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                    }
                }
                .frame(width: tileWidth, height: height)
                .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(Color.secondary.opacity(0.15))
        .clipped()
        .allowsHitTesting(false)
        .task(id: "source\(sourceRevision)-\(tileCount)-\(Int(start * 1000))-\(Int(end * 1000))") {
            if loadedSourceRevision != sourceRevision {
                tiles = []
                loadedSourceRevision = sourceRevision
            }
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private var tileWidth: CGFloat {
        width / CGFloat(tileCount)
    }

    private func load() async {
        guard let thumbnailer, end > start, width > 0 else { tiles = []; return }
        let span = end - start
        let firstFrame = grid.nearestBoundary(to: start)
        let lastFrame = max(firstFrame, grid.nearestBoundary(to: end) - 1)
        // Each tile may only show a frame from the span it covers, and never one
        // outside the kept range — otherwise the decode snaps to the next scene's
        // keyframe (or to frames the cut removed) and the strip contradicts the
        // exact preview.
        let halfTileSpan = span / Double(tileCount) / 2
        let maxTolerance = min(0.5, halfTileSpan)
        let firstTime = grid.time(ofFrame: firstFrame)
        let lastTime = grid.time(ofFrame: lastFrame)
        let requests = (0..<tileCount).map { index -> Thumbnailer.StripRequest in
            let sample = start + (Double(index) + 0.5) / Double(tileCount) * span
            let frame = min(max(firstFrame, grid.nearestFrame(to: sample)), lastFrame)
            let time = grid.time(ofFrame: frame)
            return Thumbnailer.StripRequest(
                time: time,
                toleranceBefore: max(0, min(maxTolerance, time - firstTime)),
                toleranceAfter: max(0, min(maxTolerance, lastTime - time))
            )
        }
        let loaded = await thumbnailer.filmstrip(requests)
        guard !Task.isCancelled else { return }
        tiles = loaded
    }
}

/// Routes every timeline drop (clip reorder + library insert) to the insertion
/// gap nearest the pointer, drawing a caret there while the drag hovers. Being
/// the only drop surface, drops can never fall through to an append fallback —
/// the caret position is exactly what a release does.
private struct TimelineInsertionDropDelegate: DropDelegate {
    let insertionIndex: (CGPoint) -> Int
    let setIndicator: (Int?) -> Void
    let autoScroll: (CGPoint) -> Void
    let stopAutoScroll: () -> Void
    let perform: (String, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        setIndicator(insertionIndex(info.location))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setIndicator(insertionIndex(info.location))
        autoScroll(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setIndicator(nil)
        stopAutoScroll()
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = insertionIndex(info.location)
        setIndicator(nil)
        stopAutoScroll()
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            Task { @MainActor in perform(payload, index) }
        }
        return true
    }
}

/// Library assets travel as "library:<uuid>"; timeline groups use their own
/// prefix below. Returns the asset id if the payload is a library drag.
func libraryAssetID(_ payload: String) -> UUID? {
    guard payload.hasPrefix("library:") else { return nil }
    return UUID(uuidString: String(payload.dropFirst("library:".count)))
}

/// Timeline drags encode the complete group at drag start so an asynchronous
/// drop cannot be affected by a later selection change. Accept the old bare
/// UUID shape as well, keeping existing in-flight drags harmless during reloads.
func timelineItemIDs(_ payload: String) -> [UUID] {
    if payload.hasPrefix("timeline:") {
        return payload.dropFirst("timeline:".count)
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
    }
    return UUID(uuidString: payload).map { [$0] } ?? []
}

private func timelineClockText(_ seconds: Double, compact: Bool = false) -> String {
    let value = max(0, seconds)
    let hours = Int(value) / 3600
    let minutes = Int(value) / 60 % 60
    let wholeSeconds = Int(value) % 60
    let milliseconds = Int((value - floor(value)) * 1000)
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, wholeSeconds) }
    if compact { return String(format: "%02d:%02d", minutes, wholeSeconds) }
    return String(format: "%02d:%02d.%03d", minutes, wholeSeconds, milliseconds)
}
