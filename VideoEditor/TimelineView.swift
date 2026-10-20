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
    /// A clip's own sound, the lower part of the clip: its level line and fade
    /// handles need the same room as a piece of the track.
    static let audioHeight: CGFloat = 36
    /// The audio track under the clip row: one lane per overlapping clip. Tall
    /// enough for a level line, a pair of fade handles and a label to each
    /// have room of their own.
    static let audioLaneHeight: CGFloat = 40
    static let audioLaneSpacing: CGFloat = 2
    static let audioTrackGap: CGFloat = 6
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
    /// The picture keeps its 70 points; the clip's own sound below it takes
    /// the rest.
    private let baseTrackHeight: CGFloat = 108
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

    /// Where the rows sit vertically. One place rather than the arithmetic
    /// repeated at every call site — which is how the audio track could have
    /// ended up drawn in one spot and hit-tested in another.
    private struct TrackGeometry {
        let rulerHeight: CGFloat
        let clipRowHeight: CGFloat
        let audioLanes: Int
        let trackHeight: CGFloat

        init(paneHeight: CGFloat, rulerHeight: CGFloat, clipRowHeight: CGFloat, audioLanes: Int) {
            self.rulerHeight = rulerHeight
            self.clipRowHeight = clipRowHeight
            self.audioLanes = audioLanes
            // The drop zone always fills the pane; the rows inside render at
            // fixed heights so filmstrips never get stretched.
            trackHeight = max(clipRowHeight + Self.audioArea(lanes: audioLanes),
                              paneHeight - rulerHeight)
        }

        private static func audioArea(lanes: Int) -> CGFloat {
            guard lanes > 0 else { return 0 }
            return TimelineLaneMetrics.audioTrackGap
                + CGFloat(lanes) * TimelineLaneMetrics.audioLaneHeight
                + CGFloat(lanes - 1) * TimelineLaneMetrics.audioLaneSpacing
        }

        var audioArea: CGFloat { Self.audioArea(lanes: audioLanes) }
        var totalHeight: CGFloat { rulerHeight + trackHeight }
        /// The clip row and the track under it, centred together in the pane.
        var clipRowTop: CGFloat { rulerHeight + (trackHeight - clipRowHeight - audioArea) / 2 }
        var clipRowBottom: CGFloat { clipRowTop + clipRowHeight }
        var audioTrackTop: CGFloat { clipRowBottom + TimelineLaneMetrics.audioTrackGap }

        func laneTop(_ lane: Int) -> CGFloat {
            audioTrackTop + CGFloat(lane)
                * (TimelineLaneMetrics.audioLaneHeight + TimelineLaneMetrics.audioLaneSpacing)
        }

        /// The lane under a y, or `nil` between lanes and off the track.
        func audioLane(at y: CGFloat) -> Int? {
            guard audioLanes > 0, y >= audioTrackTop else { return nil }
            let pitch = TimelineLaneMetrics.audioLaneHeight + TimelineLaneMetrics.audioLaneSpacing
            let lane = Int((y - audioTrackTop) / pitch)
            guard lane < audioLanes,
                  y - laneTop(lane) <= TimelineLaneMetrics.audioLaneHeight else { return nil }
            return lane
        }

        /// Every lane a vertical span touches.
        func lanes(touching range: ClosedRange<CGFloat>) -> ClosedRange<Int>? {
            let touched = (0..<audioLanes).filter { lane in
                let top = laneTop(lane)
                return range.lowerBound <= top + TimelineLaneMetrics.audioLaneHeight
                    && range.upperBound >= top
            }
            guard let first = touched.first, let last = touched.last else { return nil }
            return first...last
        }
    }

    var body: some View {
        let layout = TimelineLayout(items: model.items)
        let track = AudioTrackLayout(clips: model.audioClips)
        VStack(alignment: .leading, spacing: Self.headerSpacing) {
            header(layout: layout)

            GeometryReader { geo in
                let scale = CGFloat(model.timelinePointsPerSecond)
                let clipsWidth = CGFloat(layout.totalDuration) * scale
                let trailingWorkspace = max(360, geo.size.width * 0.72)
                let contentWidth = max(geo.size.width, clipsWidth + trailingWorkspace)
                let geometry = TrackGeometry(paneHeight: geo.size.height, rulerHeight: rulerHeight,
                                             clipRowHeight: baseTrackHeight,
                                             audioLanes: track.laneCount)

                ScrollView(.horizontal, showsIndicators: true) {
                    // The chips sit outside the canvas rather than inside it: as
                    // a sibling drawn on top they absorb their own clicks, so
                    // pressing one no longer also runs the canvas-wide tap that
                    // would seek the playhead out from under you.
                    ZStack(alignment: .topLeading) {
                        canvas(layout: layout, track: track, width: contentWidth,
                               clipsWidth: clipsWidth, scale: scale,
                               viewportWidth: geo.size.width, geometry: geometry)
                        tailChips(layout: layout, width: contentWidth,
                                  scale: scale, geometry: geometry)
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

    /// The row over the timeline. The transport sits in its middle, beside the
    /// time it reads, which keeps the picture above at its whole height; the
    /// three edits a mouse reaches for most are icons on the left, each with
    /// its key beside it, and the zoom and the tails are on the right.
    /// Everything else this row used to carry is on the clips, in their menus
    /// and on the keys.
    private func header(layout: TimelineLayout) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Button { model.deleteBeforePlayhead() } label: { editIcon("delete.left", key: "Q") }
                    .disabled(!model.canDeleteBeforePlayhead)
                    .help("刪除播放頭至前一個分割點之間的內容（Q）")
                    .accessibilityLabel("刪除左側")
                Button { model.splitAtPlayhead() } label: { editIcon("scissors", key: "S") }
                    .disabled(!model.canSplitAtPlayhead)
                    .help("在播放頭分割成兩段；選著一段音訊時分割的是那段音訊（S）")
                    .accessibilityLabel("分割")
                Button { model.deleteAfterPlayhead() } label: { editIcon("delete.right", key: "W") }
                    .disabled(!model.canDeleteAfterPlayhead)
                    .help("刪除播放頭至下一個分割點之間的內容（W）")
                    .accessibilityLabel("刪除右側")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            transport(totalDuration: layout.totalDuration)

            HStack(spacing: 8) {
                tailMenu
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
                .frame(width: 130)
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
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// One of the edits on the left: its icon, with its key beside it the way
    /// 符合視窗 carries ⇧Z.
    private func editIcon(_ symbol: String, key: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            KeyCapHint(key)
        }
    }

    /// Previous cut, play, next cut, and where the playhead is in the movie.
    private func transport(totalDuration: Double) -> some View {
        HStack(spacing: 4) {
            Button { model.jumpToPreviousCut() } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(.borderless)
                .disabled(totalDuration <= 0)
                .help("前一個剪點（↑）")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isTimelinePlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .disabled(totalDuration <= 0)
            .help("播放／暫停（空白鍵）")
            Button { model.jumpToNextCut() } label: { Image(systemName: "forward.end.fill") }
                .buttonStyle(.borderless)
                .disabled(totalDuration <= 0)
                .help("下一個剪點（↓）")
            Text("\(timelineClockText(model.timelineTime)) / \(timelineClockText(totalDuration))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 6)
                .accessibilityLabel("播放頭位置")
        }
        .fixedSize()
    }

    /// The clips whose sound or container outlives their last frame: one menu,
    /// to go and look at a tail or to retire them all. Dismissing one alone,
    /// or padding its picture, is on the tail's own chip and the clip's menu.
    @ViewBuilder
    private var tailMenu: some View {
        let tails = model.items.filter { $0.trailingOverhangDuration > 1e-9 }
        if !tails.isEmpty {
            Menu {
                ForEach(tails) { item in
                    Button("放大到「\(item.url.lastPathComponent)」的尾端") { model.zoomToTail(for: item.id) }
                }
                Divider()
                Button("忽略全部尾端（\(tails.count)）") { model.dismissAllTrailingOverhangs() }
            } label: {
                Label("尾端 \(tails.count)", systemImage: "waveform.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            .fixedSize()
            .help("有 \(tails.count) 段的原音或容器比最後一格影像長；輸出會切齊影像尾端")
        }
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

    private func canvas(layout: TimelineLayout, track: AudioTrackLayout, width: CGFloat,
                        clipsWidth: CGFloat, scale: CGFloat,
                        viewportWidth: CGFloat, geometry: TrackGeometry) -> some View {
        let trackHeight = geometry.trackHeight
        let visibleTimelineRange = ClosedRange(
            uncheckedBounds: (
                lower: Double(scrollOffset / scale),
                upper: Double((scrollOffset + viewportWidth) / scale)
            )
        )
        // What a clip's own fade handles are pulled onto: the cuts and the
        // ends of every piece of the track.
        let soundSnapTimes = layout.boundaries
            + track.entries.flatMap { [$0.clip.timelineStart, $0.clip.timelineEnd] }
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
                                     pointsPerSecond: scale, height: baseTrackHeight,
                                     snapTimes: soundSnapTimes)
                }
            }
            .frame(width: clipsWidth, height: baseTrackHeight, alignment: .leading)
            .offset(y: geometry.clipRowTop)

            audioTrack(track: track, layout: layout, scale: scale, geometry: geometry,
                       visibleTimelineRange: visibleTimelineRange, width: width)

            tailMarks(layout: layout, width: width, scale: scale, geometry: geometry)

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
                            y: geometry.clipRowTop - 6)
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
            dropTime: { location in Double(location.x / scale) },
            setIndicator: { dropInsertionIndex = $0 },
            autoScroll: { location in updateDropAutoScroll(pointerX: location.x) },
            stopAutoScroll: { stopDropAutoScroll() },
            perform: { payload, index, time in handleTimelineDrop(payload, at: index, time: time) }
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
                    let clipRowTop = geometry.clipRowTop
                    let time = Double(value.location.x / scale)
                    let beforeTimelineEnd = value.location.x < clipsWidth
                    let onRuler = value.location.y <= rulerHeight
                        && beforeTimelineEnd
                    let onClips = beforeTimelineEnd
                        && value.location.y >= clipRowTop
                        && value.location.y <= clipRowTop + baseTrackHeight
                    let onTrack = track.clip(at: time,
                                             lane: geometry.audioLane(at: value.location.y))
                    if let onTrack, let lane = geometry.audioLane(at: value.location.y),
                       soundControlClick(
                           on: onTrack,
                           at: CGPoint(x: value.location.x - CGFloat(onTrack.timelineStart) * scale,
                                       y: value.location.y - geometry.laneTop(lane)),
                           scale: scale, movieDuration: layout.totalDuration) {
                        return
                    }
                    if onClips, let itemID = layout.itemID(at: time),
                       let entry = layout.entries.first(where: { $0.id == itemID }),
                       originalSoundControlClick(
                           on: entry.item,
                           at: CGPoint(x: value.location.x - CGFloat(entry.start) * scale,
                                       y: value.location.y - originalAudioLaneTop(geometry)),
                           scale: scale) {
                        return
                    }
                    if NSEvent.modifierFlags.contains(.command) {
                        // ⌘-click toggles a clip in/out of the selection and never
                        // moves the playhead.
                        if let onTrack {
                            model.toggleAudioSelection(onTrack.id)
                        } else if onClips, let itemID = layout.itemID(at: time) {
                            model.toggleSelection(itemID)
                        }
                        return
                    }
                    if let onTrack {
                        // A piece of the track: select it, with the playhead
                        // parked under the pointer as a clip click would.
                        model.seekTimeline(to: min(time, layout.totalDuration))
                        model.selectAudioClip(onTrack.id)
                    } else if onClips {
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
                    let clipRowTop = geometry.clipRowTop
                    if marqueeStart == nil {
                        // A marquee only starts from blank space; drags that begin
                        // on a clip belong to drag-reorder, those on a piece of
                        // the track to moving or trimming it, and the ruler
                        // stays a pure seek surface.
                        let s = value.startLocation
                        let onRuler = s.y <= rulerHeight
                        let onClip = s.x <= clipsWidth
                            && s.y >= clipRowTop && s.y <= clipRowTop + baseTrackHeight
                        let onTrack = track.clip(at: Double(s.x / scale),
                                                 lane: geometry.audioLane(at: s.y)) != nil
                        guard !onRuler, !onClip, !onTrack else { return }
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
                    model.selectedAudioIDs = marqueeAudioSelection(rect, track: track,
                                                                   scale: scale,
                                                                   geometry: geometry)
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

    private func handleTimelineDrop(_ payload: String, at index: Int, time: Double) {
        if let assetID = libraryAssetID(payload) {
            if let asset = model.libraryAsset(assetID), asset.kind == .audio {
                // Sound lands where it was dropped, not in a gap between
                // clips: the track has no gaps to insert into.
                model.insertAudioClip(from: asset, at: max(0, time))
            } else {
                model.insertLibraryAsset(assetID, at: index)
            }
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

    /// Pieces of the track whose span the marquee crosses, in the lanes it
    /// reaches.
    private func marqueeAudioSelection(_ rect: CGRect, track: AudioTrackLayout,
                                       scale: CGFloat,
                                       geometry: TrackGeometry) -> Set<AudioClip.ID> {
        guard let lanes = geometry.lanes(touching: rect.minY...rect.maxY) else { return [] }
        return track.clips(in: Double(rect.minX / scale)...Double(rect.maxX / scale),
                           lanes: lanes)
    }

    /// A click on one of a piece's own controls: the speaker mutes it or
    /// brings it back, and ⌥ on the line or a handle puts that control back
    /// where it started. True when the click was one of these; it then neither
    /// selects nor moves the playhead, as a click anywhere else on the piece
    /// still does. Here rather than on the bar because this tap sees every
    /// click on the canvas, a button inside it included.
    private func soundControlClick(on clip: AudioClip, at point: CGPoint,
                                   scale: CGFloat, movieDuration: Double) -> Bool {
        let bar = SoundBarGeometry(piece: clip, width: max(2, CGFloat(clip.duration) * scale),
                                   height: TimelineLaneMetrics.audioLaneHeight,
                                   pointsPerSecond: scale, movieDuration: movieDuration)
        let option = NSEvent.modifierFlags.contains(.option)
        switch bar.zone(at: point, isMuted: clip.isMuted, trims: true) {
        case .mute:
            model.setAudioClipMuted(!clip.isMuted, for: clip.id)
        case .level where option:
            model.setAudioClipGain(1, for: clip.id)
        case .fadeIn where option:
            model.setAudioClipFades(in: 0, out: clip.fadeOut, for: clip.id)
        case .fadeOut where option:
            model.setAudioClipFades(in: clip.fadeIn, out: 0, for: clip.id)
        default:
            return false
        }
        return true
    }

    /// The same, on a clip's own sound: the lower part of the clip, which has
    /// no ends of its own to trim.
    private func originalSoundControlClick(on item: ClipItem, at point: CGPoint,
                                           scale: CGFloat) -> Bool {
        guard !item.isImage, item.hasAudio,
              point.y >= 0, point.y <= TimelineLaneMetrics.audioHeight else { return false }
        let bar = SoundBarGeometry(original: item, width: CGFloat(item.displayDuration) * scale,
                                   height: TimelineLaneMetrics.audioHeight, pointsPerSecond: scale)
        let option = NSEvent.modifierFlags.contains(.option)
        switch bar.zone(at: point, isMuted: item.isAudioMuted, trims: false) {
        case .mute:
            model.setOriginalAudioMuted(!item.isAudioMuted, for: item.id)
        case .level where option:
            model.setOriginalAudioGain(1, for: item.id)
        case .fadeIn where option:
            model.setOriginalAudioFades(in: 0, out: item.audioFadeOut, for: item.id)
        case .fadeOut where option:
            model.setOriginalAudioFades(in: item.audioFadeIn, out: 0, for: item.id)
        default:
            return false
        }
        return true
    }

    /// The audio track: every piece of sound in its lane, under the clip row.
    private func audioTrack(track: AudioTrackLayout, layout: TimelineLayout, scale: CGFloat,
                            geometry: TrackGeometry, visibleTimelineRange: ClosedRange<Double>,
                            width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(track.entries) { entry in
                TimelineAudioClipView(
                    model: model, clip: entry.clip, pointsPerSecond: scale,
                    height: TimelineLaneMetrics.audioLaneHeight,
                    top: geometry.laneTop(entry.lane),
                    movieDuration: layout.totalDuration,
                    snapTimes: track.snapTimes(excluding: entry.id,
                                               clipBoundaries: layout.boundaries),
                    visibleTimelineRange: visibleTimelineRange)
                .offset(x: CGFloat(entry.clip.timelineStart) * scale,
                        y: geometry.laneTop(entry.lane))
            }
        }
        .frame(width: width, height: geometry.totalHeight, alignment: .topLeading)
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
                           scale: CGFloat, geometry: TrackGeometry) -> some View {
        let laneTop = originalAudioLaneTop(geometry)
        let trackHeight = geometry.trackHeight
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
                           scale: CGFloat, geometry: TrackGeometry) -> some View {
        let chipTop = originalAudioLaneTop(geometry)
            - TimelineLaneMetrics.tailChipHeight - 3
        let trackHeight = geometry.trackHeight
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

    /// Top of a clip's own audio lane in canvas coordinates.
    private func originalAudioLaneTop(_ geometry: TrackGeometry) -> CGFloat {
        geometry.clipRowBottom - TimelineLaneMetrics.audioHeight
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
    /// Moments a fade handle on the clip's own sound is pulled onto: the cuts
    /// and the ends of the track's pieces.
    let snapTimes: [Double]

    /// The clip's own sound, read once per file off the main thread.
    @State private var peaks: AudioPeaks?
    /// A drag on the clip's own line or one of its handles, with what it has
    /// set so far; the model hears of it once, on release.
    @State private var soundDrag: SoundDrag?
    /// The control of the clip's own sound under the pointer.
    @State private var soundHover: SoundBarGeometry.Zone?
    @State private var showsSoundPanel = false

    private struct SoundDrag {
        let zone: SoundBarGeometry.Zone
        var gain: Double
        var fadeIn: Double
        var fadeOut: Double
        /// Where the level drag last changed gear, as on a piece of the track.
        var levelBase: (gain: Double, rise: CGFloat, fine: Bool)?
        var readoutX: CGFloat
    }

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
        .overlay(alignment: .topLeading) {
            // Over the picture, just above its sound: the clip clips what is
            // inside it, and this has to be seen.
            if let soundDrag {
                SoundReadout(text: soundReadout(soundDrag))
                    .offset(x: soundDrag.readoutX + 10,
                            y: videoLaneHeight + TimelineLaneMetrics.spacing - 22)
            }
        }
        .accessibilityLabel(item.url.lastPathComponent)
        .accessibilityValue("\(String(format: "%.2f", item.displayDuration)) 秒")
        .contextMenu {
            // Finder's rule: right-clicking inside the selection acts on all
            // of it, anywhere else on just the clip under the pointer.
            let targets = selected ? model.selectedIDs : [item.id]
            if !item.isImage, item.hasAudio {
                let sounds = model.items.filter { targets.contains($0.id) && $0.hasAudio }
                Button(item.isAudioMuted ? "取消原音靜音" : "原音靜音") {
                    model.setSoundMuted(!item.isAudioMuted, pieces: [], clips: targets)
                }
                Button("原音音量重設為 100%") { model.resetSoundGain(pieces: [], clips: targets) }
                    .disabled(sounds.allSatisfy { $0.audioGain == 1 })
                Button("移除原音淡入淡出") { model.removeSoundFades(pieces: [], clips: targets) }
                    .disabled(sounds.allSatisfy { $0.audioFadeIn == 0 && $0.audioFadeOut == 0 })
                Button("原音音量與淡入淡出…") { showsSoundPanel = true }
                Button("分離原音") { model.detachOriginalAudio(from: item.id) }
                    .disabled(item.isAudioMuted)
                Divider()
            }
            Button("向右旋轉 90°") { model.rotateItems(targets, by: 1) }
            Button("向左旋轉 90°") { model.rotateItems(targets, by: -1) }
            if item.trailingOverhangDuration > 1e-9 {
                Divider()
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
            TimelineImageStrip(url: item.url,
                               source: item.orientedPixelSize,
                               rotation: item.geometry.rotation,
                               crop: model.visibleSourceRegion(for: item))
        } else {
            TimelineVideoStrip(
                itemID: item.id,
                source: item.orientedPixelSize,
                rotation: item.geometry.rotation,
                crop: model.visibleSourceRegion(for: item),
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
        ZStack(alignment: .leading) {
            if item.hasAudio {
                originalSoundBar
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.58))
                HStack(spacing: 4) {
                    Image(systemName: "speaker.slash")
                    Text("無原音")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 6)
            }

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

            if item.hasAudio { originalSoundControls }
        }
        .onContinuousHover { phase in
            guard item.hasAudio else { return }
            switch phase {
            case .active(let point):
                guard soundDrag == nil else { return }
                let zone = originalGeometry.zone(at: point, isMuted: item.isAudioMuted, trims: false)
                if zone != soundHover { soundHover = zone }
                // The body of the bar carries the clip, as the picture does.
                (zone == .body ? NSCursor.arrow : SoundBarCursor.cursor(for: zone)).set()
            case .ended:
                soundHover = nil
                NSCursor.arrow.set()
            }
        }
        .popover(isPresented: $showsSoundPanel, arrowEdge: .bottom) {
            SoundShapingPanel(model: model, target: .original(item.id))
        }
        .accessibilityLabel(!item.hasAudio ? "沒有原始音訊"
                            : item.isAudioMuted ? "原始音訊已靜音" : "原始音訊")
        .accessibilityValue(originalSoundAccessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard item.hasAudio else { return }
            switch direction {
            case .increment: model.nudgeSoundGain(by: 0.05, pieces: [], clips: [item.id])
            case .decrement: model.nudgeSoundGain(by: -0.05, pieces: [], clips: [item.id])
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text(item.isAudioMuted ? "取消原音靜音" : "原音靜音")) {
            guard item.hasAudio else { return }
            model.setOriginalAudioMuted(!item.isAudioMuted, for: item.id)
        }
        .task(id: item.hasAudio ? item.url : nil) {
            peaks = item.hasAudio ? await AudioWaveformStore.shared.peaks(for: item.url) : nil
        }
    }

    private var originalSoundAccessibilityValue: String {
        guard item.hasAudio else { return "" }
        var value = soundAccessibilityValue(gain: item.audioGain, isMuted: item.isAudioMuted,
                                            fadeIn: item.audioFadeIn, fadeOut: item.audioFadeOut)
        if item.hasVideoPad {
            value += "，延長 \(String(format: "%.2f", item.videoPadDuration)) 秒黑畫面以保留原音"
        }
        return value
    }

    /// The clip's own sound as drawn: a drag in hand applied.
    private var originalGeometry: SoundBarGeometry {
        var geometry = SoundBarGeometry(original: item, width: width,
                                        height: TimelineLaneMetrics.audioHeight,
                                        pointsPerSecond: pointsPerSecond)
        if let soundDrag {
            geometry.gain = soundDrag.gain
            geometry.fadeIn = soundDrag.fadeIn
            geometry.fadeOut = soundDrag.fadeOut
        }
        return geometry
    }

    /// The clip's own sound, drawn the way the track's pieces are. Its span is
    /// the clip's, black included: a padded clip keeps its audio across the
    /// black — the entire reason the black is there — and the export shapes
    /// the whole span.
    private var originalSoundBar: some View {
        let start = max(item.inPoint, item.audioStartTime)
        let end = min(item.paddedOutPoint, item.effectiveAudioOutPoint)
        let soundFrom = max(0, CGFloat(start - item.inPoint) * pointsPerSecond)
        let soundTo = min(width, soundFrom + max(0, CGFloat(end - start) * pointsPerSecond))
        let firstVisible = max(0, CGFloat(visibleTimelineRange.lowerBound - timelineStart) * pointsPerSecond)
        let lastVisible = min(width, CGFloat(visibleTimelineRange.upperBound - timelineStart) * pointsPerSecond)
        // Muted — or detached onto the track, which mutes — draws like no
        // sound at all: the bar shows what will be heard from the clip itself.
        return SoundBar(kind: .original,
                        geometry: originalGeometry,
                        isMuted: item.isAudioMuted,
                        label: item.isAudioMuted ? "原音已靜音" : "原音",
                        peaks: peaks,
                        peaksOffset: item.inPoint - item.audioStartTime,
                        soundRange: soundFrom...max(soundFrom, soundTo),
                        visibleRange: firstVisible...max(firstVisible, lastVisible),
                        showsHandles: selected || soundHover != nil || soundDrag != nil,
                        hot: soundDrag?.zone ?? soundHover)
    }

    /// Where a drag shapes the clip's own sound instead of picking the clip
    /// up: the handles, and a band along the line. Laid over the surface that
    /// carries the clip, so it takes those hits first and leaves it all others.
    private var originalSoundControls: some View {
        Color.clear
            .frame(width: max(0.01, width), height: TimelineLaneMetrics.audioHeight)
            .contentShape(originalGeometry.controlsShape(isMuted: item.isAudioMuted))
            .gesture(originalSoundDrag)
    }

    private var originalSoundDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                let fine = NSEvent.modifierFlags.contains(.command)
                let stored = SoundBarGeometry(original: item, width: width,
                                              height: TimelineLaneMetrics.audioHeight,
                                              pointsPerSecond: pointsPerSecond)
                if soundDrag == nil {
                    let zone = stored.zone(at: value.startLocation, isMuted: item.isAudioMuted,
                                           trims: false)
                    guard [SoundBarGeometry.Zone.level, .fadeIn, .fadeOut].contains(zone) else { return }
                    soundDrag = SoundDrag(zone: zone, gain: item.audioGain, fadeIn: item.audioFadeIn,
                                          fadeOut: item.audioFadeOut, readoutX: value.location.x)
                    model.beginContinuousEdit(soundEditKey(zone))
                }
                guard var drag = soundDrag else { return }
                if drag.zone == .level {
                    let rise = -value.translation.height
                    if drag.levelBase == nil {
                        drag.levelBase = (item.audioGain, 0, fine)
                    } else if drag.levelBase?.fine != fine {
                        drag.levelBase = (drag.gain, rise, fine)
                    }
                    let base = drag.levelBase ?? (item.audioGain, 0, fine)
                    drag.gain = stored.gain(from: base.gain, rise: rise - base.rise, fine: fine)
                } else {
                    var current = stored
                    current.fadeIn = drag.fadeIn
                    current.fadeOut = drag.fadeOut
                    let origin = CGFloat(timelineStart) * pointsPerSecond
                    let snaps = fine ? [] : (snapTimes + [model.timelineTime])
                        .map { CGFloat($0) * pointsPerSecond - origin }
                    if drag.zone == .fadeIn {
                        drag.fadeIn = current.fade(.fadeIn, handleAt: value.location.x, snaps: snaps)
                    } else {
                        drag.fadeOut = current.fade(.fadeOut, handleAt: value.location.x, snaps: snaps)
                    }
                }
                drag.readoutX = value.location.x
                soundDrag = drag
            }
            .onEnded { _ in
                guard let drag = soundDrag else { return }
                soundDrag = nil
                if drag.zone == .level {
                    model.setOriginalAudioGain(drag.gain, for: item.id)
                } else {
                    model.setOriginalAudioFades(in: drag.fadeIn, out: drag.fadeOut, for: item.id)
                }
                model.endContinuousEdit(soundEditKey(drag.zone))
            }
    }

    private func soundEditKey(_ zone: SoundBarGeometry.Zone) -> String {
        zone == .level ? "original-gain:\(item.id)" : "original-fade:\(item.id)"
    }

    private func soundReadout(_ drag: SoundDrag) -> String {
        switch drag.zone {
        case .fadeIn: String(format: "原音淡入 %.2f 秒", drag.fadeIn)
        case .fadeOut: String(format: "原音淡出 %.2f 秒", drag.fadeOut)
        default: "原音 \(Int((drag.gain * 100).rounded()))%"
            + (drag.levelBase?.fine == true ? " · 微調" : "")
        }
    }
}

/// One piece of sound on the track, with its controls on it. Dragging its body
/// slides it along the movie; dragging either end trims it, keeping the sound
/// where it was; dragging the line sets its level and the handles at the top
/// its fades. Every one of them is drawn live from the view's own copy of the
/// drag and handed to the model once, on release — one undo step, and no
/// re-laning under the pointer while it is still moving. Clicks on the
/// speaker, and ⌥-clicks that put a control back, are the canvas's: its tap
/// sees every click first, so it is where they are told apart from a click
/// that selects.
private struct TimelineAudioClipView: View {
    let model: EditorModel
    let clip: AudioClip
    let pointsPerSecond: CGFloat
    let height: CGFloat
    /// The lane's top in the canvas, which the drag's coordinates are in.
    let top: CGFloat
    let movieDuration: Double
    let snapTimes: [Double]
    let visibleTimelineRange: ClosedRange<Double>

    /// Screen distance within which an end is pulled onto a cut or the playhead.
    private let snapDistance: CGFloat = 6

    private enum DragKind { case move, trimStart, trimEnd, level, fadeIn, fadeOut }
    private struct Drag {
        let kind: DragKind
        let origin: AudioClip
        /// Where a level drag last changed gear, ⌘ going down or up: the gain
        /// and the pointer's rise there, so the line never jumps.
        var levelBase: (gain: Double, rise: CGFloat, fine: Bool)?
    }

    @State private var drag: Drag?
    /// The clip with the drag in flight applied; `nil` when nothing is moving.
    @State private var shown: AudioClip?
    @State private var peaks: AudioPeaks?
    /// The control under the pointer, `nil` when the pointer is elsewhere.
    @State private var hoverZone: SoundBarGeometry.Zone?
    /// What the drag in hand is setting, and where along the bar to say it.
    @State private var readout: (text: String, x: CGFloat)?
    @State private var showsPanel = false

    private var selected: Bool { model.selectedAudioIDs.contains(clip.id) }
    private var canSplitAtPlayhead: Bool {
        model.timelineTime > clip.timelineStart + AudioClip.minimumDuration
            && model.timelineTime < clip.timelineEnd - AudioClip.minimumDuration
    }

    var body: some View {
        let shown = self.shown ?? clip
        let width = max(2, CGFloat(shown.duration) * pointsPerSecond)
        SoundBar(kind: .track,
                 geometry: barGeometry(shown, width: width),
                 isMuted: shown.isMuted,
                 label: shown.name,
                 peaks: peaks,
                 peaksOffset: shown.inPoint - shown.audioStartTime,
                 visibleRange: visibleColumns(shown, width: width),
                 selected: selected,
                 showsHandles: selected || hoverZone != nil || drag != nil,
                 hot: drag.map(zone(of:)) ?? hoverZone)
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            if let readout {
                SoundReadout(text: readout.text)
                    .offset(x: readout.x + 10, y: -22)
            }
        }
        .offset(x: CGFloat(shown.timelineStart - clip.timelineStart) * pointsPerSecond)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                guard drag == nil else { return }
                let zone = barGeometry(clip, width: width)
                    .zone(at: point, isMuted: clip.isMuted, trims: true)
                if zone != hoverZone { hoverZone = zone }
                SoundBarCursor.cursor(for: zone).set()
            case .ended:
                hoverZone = nil
                NSCursor.arrow.set()
            }
        }
        .gesture(dragGesture(width: width))
        .contextMenu {
            // Finder's rule, as on a clip: inside the selection the menu acts
            // on all of it, anywhere else on just this piece.
            let pieces = selected ? model.selectedAudioIDs : [clip.id]
            let shaped = model.audioClips.filter { pieces.contains($0.id) }
            Button(clip.isMuted ? "取消靜音" : "靜音") {
                model.setSoundMuted(!clip.isMuted, pieces: pieces, clips: [])
            }
            Button("音量重設為 100%") { model.resetSoundGain(pieces: pieces, clips: []) }
                .disabled(shaped.allSatisfy { $0.gain == 1 })
            Button("移除淡入淡出") { model.removeSoundFades(pieces: pieces, clips: []) }
                .disabled(shaped.allSatisfy { $0.fadeIn == 0 && $0.fadeOut == 0 })
            Button("音量與淡入淡出…") { showsPanel = true }
            Divider()
            Button("在播放頭分割") { model.splitAudioClip(clip.id, at: model.timelineTime) }
                .disabled(!canSplitAtPlayhead)
            Divider()
            Button("刪除", role: .destructive) {
                model.selectAudioClip(clip.id)
                model.removeSelectedItems()
            }
        }
        .popover(isPresented: $showsPanel, arrowEdge: .bottom) {
            SoundShapingPanel(model: model, target: .piece(clip.id))
        }
        .task(id: clip.url) { peaks = await AudioWaveformStore.shared.peaks(for: clip.url) }
        .accessibilityLabel("音訊 \(clip.name)")
        .accessibilityValue("\(String(format: "%.2f", clip.duration)) 秒，"
                            + "從 \(String(format: "%.2f", clip.timelineStart)) 秒起，"
                            + soundAccessibilityValue(gain: clip.gain, isMuted: clip.isMuted,
                                                      fadeIn: clip.fadeIn, fadeOut: clip.fadeOut))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.nudgeSoundGain(by: 0.05, pieces: [clip.id], clips: [])
            case .decrement: model.nudgeSoundGain(by: -0.05, pieces: [clip.id], clips: [])
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text(clip.isMuted ? "取消靜音" : "靜音")) {
            model.setAudioClipMuted(!clip.isMuted, for: clip.id)
        }
    }

    private func zone(of drag: Drag) -> SoundBarGeometry.Zone {
        switch drag.kind {
        case .move: .body
        case .trimStart: .trimStart
        case .trimEnd: .trimEnd
        case .level: .level
        case .fadeIn: .fadeIn
        case .fadeOut: .fadeOut
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("outputTimelineCanvas"))
            .onChanged { value in
                if drag == nil {
                    let start = CGPoint(x: value.startLocation.x - CGFloat(clip.timelineStart) * pointsPerSecond,
                                        y: value.startLocation.y - top)
                    let kind: DragKind
                    switch barGeometry(clip, width: width).zone(at: start, isMuted: clip.isMuted, trims: true) {
                    case .fadeIn: kind = .fadeIn
                    case .fadeOut: kind = .fadeOut
                    case .level: kind = .level
                    case .trimStart: kind = .trimStart
                    case .trimEnd: kind = .trimEnd
                    case .mute, .body: kind = .move
                    }
                    drag = Drag(kind: kind, origin: clip)
                    if !selected { model.selectAudioClip(clip.id) }
                    // A level or a fade is a continuous edit, as a slider's was:
                    // playback stops for it, and the drag is one undo step.
                    if let key = editKey(kind) { model.beginContinuousEdit(key) }
                }
                guard var drag else { return }
                let result = apply(&drag, value: value)
                self.drag = drag
                shown = result
                readout = (readoutText(drag, result),
                           value.location.x - CGFloat(result.timelineStart) * pointsPerSecond)
            }
            .onEnded { _ in
                defer { drag = nil; shown = nil; readout = nil }
                guard let drag else { return }
                if let result = shown {
                    switch drag.kind {
                    case .move:
                        model.moveAudioClip(clip.id, to: result.timelineStart)
                    case .trimStart, .trimEnd:
                        model.trimAudioClip(clip.id, inPoint: result.inPoint,
                                            outPoint: result.outPoint,
                                            timelineStart: result.timelineStart)
                    case .level:
                        model.setAudioClipGain(result.gain, for: clip.id)
                    case .fadeIn, .fadeOut:
                        model.setAudioClipFades(in: result.fadeIn, out: result.fadeOut, for: clip.id)
                    }
                }
                if let key = editKey(drag.kind) { model.endContinuousEdit(key) }
            }
    }

    private func editKey(_ kind: DragKind) -> String? {
        switch kind {
        case .level: "audio-gain:\(clip.id)"
        case .fadeIn, .fadeOut: "audio-fade:\(clip.id)"
        case .move, .trimStart, .trimEnd: nil
        }
    }

    /// The clip as the drag so far leaves it: moved, or trimmed at one end
    /// with that end pulled onto a nearby cut, or set to a new level or fade.
    private func apply(_ drag: inout Drag, value: DragGesture.Value) -> AudioClip {
        var clip = drag.origin
        let delta = Double(value.translation.width / pointsPerSecond)
        let fine = NSEvent.modifierFlags.contains(.command)
        switch drag.kind {
        case .move:
            var start = max(0, clip.timelineStart + delta)
            // Either end may snap, whichever a cut is nearer to.
            if let snapped = snap(start) {
                start = snapped
            } else if let snappedEnd = snap(start + clip.duration) {
                start = max(0, snappedEnd - clip.duration)
            }
            clip.timelineStart = start
        case .trimStart:
            let floor = max(clip.sourceFloor, clip.inPoint - clip.timelineStart)   // not before the movie's start
            let ceiling = clip.outPoint - AudioClip.minimumDuration
            var inPoint = min(max(clip.inPoint + delta, floor), ceiling)
            if let snapped = snap(clip.timelineStart + (inPoint - clip.inPoint)) {
                let candidate = clip.inPoint + (snapped - clip.timelineStart)
                if candidate >= floor && candidate <= ceiling { inPoint = candidate }
            }
            clip.timelineStart += inPoint - clip.inPoint
            clip.inPoint = inPoint
        case .trimEnd:
            let floor = clip.inPoint + AudioClip.minimumDuration
            var outPoint = min(max(clip.outPoint + delta, floor), clip.sourceCeiling)
            if let snapped = snap(clip.timelineStart + (outPoint - clip.inPoint)) {
                let candidate = clip.inPoint + (snapped - clip.timelineStart)
                if candidate >= floor && candidate <= clip.sourceCeiling { outPoint = candidate }
            }
            clip.outPoint = outPoint
        case .level:
            let rise = -value.translation.height
            if drag.levelBase == nil {
                drag.levelBase = (clip.gain, 0, fine)
            } else if drag.levelBase?.fine != fine {
                drag.levelBase = ((shown ?? clip).gain, rise, fine)
            }
            let base = drag.levelBase ?? (clip.gain, 0, fine)
            clip.gain = barGeometry(clip, width: 0)
                .gain(from: base.gain, rise: rise - base.rise, fine: fine)
        case .fadeIn, .fadeOut:
            // The handle follows the pointer; the other fade stays put and
            // bounds it.
            let current = shown ?? clip
            let geometry = barGeometry(current, width: max(2, CGFloat(current.duration) * pointsPerSecond))
            let origin = CGFloat(clip.timelineStart) * pointsPerSecond
            let snaps = fine ? [] : (snapTimes + [0, model.timelineTime])
                .map { CGFloat($0) * pointsPerSecond - origin }
            let x = value.location.x - origin
            if drag.kind == .fadeIn {
                clip.fadeIn = geometry.fade(.fadeIn, handleAt: x, snaps: snaps)
                clip.fadeOut = current.fadeOut
            } else {
                clip.fadeOut = geometry.fade(.fadeOut, handleAt: x, snaps: snaps)
                clip.fadeIn = current.fadeIn
            }
        }
        return clip
    }

    private func readoutText(_ drag: Drag, _ result: AudioClip) -> String {
        switch drag.kind {
        case .move: "起 \(timelineClockText(result.timelineStart))"
        case .trimStart, .trimEnd: String(format: "長度 %.2f 秒", result.duration)
        case .level: "\(Int((result.gain * 100).rounded()))%"
            + (drag.levelBase?.fine == true ? " · 微調" : "")
        case .fadeIn: String(format: "淡入 %.2f 秒", result.fadeIn)
        case .fadeOut: String(format: "淡出 %.2f 秒", result.fadeOut)
        }
    }

    private func snap(_ time: Double) -> Double? {
        let candidates = snapTimes + [0, model.timelineTime]
        guard let nearest = candidates.min(by: { abs($0 - time) < abs($1 - time) }),
              abs(nearest - time) * Double(pointsPerSecond) <= Double(snapDistance) else {
            return nil
        }
        return nearest
    }

    /// The bar's shape for `shown`: its fade-out leads into wherever the
    /// sound stops being heard, the movie's end when the clip outruns it.
    private func barGeometry(_ shown: AudioClip, width: CGFloat) -> SoundBarGeometry {
        SoundBarGeometry(piece: shown, width: width, height: height,
                         pointsPerSecond: pointsPerSecond, movieDuration: movieDuration)
    }

    /// The columns of the bar on screen, in points from its start.
    private func visibleColumns(_ shown: AudioClip, width: CGFloat) -> ClosedRange<CGFloat> {
        let first = max(0, CGFloat(visibleTimelineRange.lowerBound - shown.timelineStart) * pointsPerSecond)
        let last = min(width, CGFloat(visibleTimelineRange.upperBound - shown.timelineStart) * pointsPerSecond)
        return first...max(first, last)
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
    /// The turned picture, which `crop` is in.
    let source: PixelSize
    let rotation: ClipRotation
    let crop: PixelRect?
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.82)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .turned(rotation)
                        .showingSourceRegion(crop, of: source, filling: geo.size)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
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
    /// The turned picture, which `crop` is in. The frames decode unturned and
    /// are turned as they are drawn, so turning a clip never re-decodes it.
    let source: PixelSize
    let rotation: ClipRotation
    let crop: PixelRect?
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
                source: source,
                rotation: rotation,
                crop: crop,
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
            FilmstripStrip(source: source, rotation: rotation, crop: crop,
                           sourceRevision: sourceRevision,
                           thumbnailer: thumbnailer, grid: grid,
                           start: start, end: end,
                           width: width, height: height)
        }
    }
}

private struct ExactFrameTimelineStrip: View {
    let itemID: ClipItem.ID
    let source: PixelSize
    let rotation: ClipRotation
    let crop: PixelRect?
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
                // The image is sized and clipped to the cell rather than left to
                // overflow: a bare scaledToFill grows the enclosing stack to the
                // overflow size, shifting the clipping window and pushing the
                // badge out of view.
                Image(decorative: image, scale: 1, orientation: rotation.imageOrientation)
                    .resizable()
                    .showingSourceRegion(crop, of: source,
                                         filling: CGSize(width: cellWidth(frameIndex) + 0.5,
                                                         height: height))
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
    /// The turned picture, which `crop` is in; the tiles decode unturned and
    /// are turned as they are drawn.
    let source: PixelSize
    let rotation: ClipRotation
    let crop: PixelRect?
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
                        Image(decorative: image, scale: 1,
                              orientation: rotation.imageOrientation)
                            .resizable()
                            .showingSourceRegion(crop, of: source,
                                                 filling: CGSize(width: tileWidth,
                                                                 height: height))
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
    /// The moment under the pointer, for what lands on the track rather than
    /// in the clip order.
    let dropTime: (CGPoint) -> Double
    let setIndicator: (Int?) -> Void
    let autoScroll: (CGPoint) -> Void
    let stopAutoScroll: () -> Void
    let perform: (String, Int, Double) -> Void

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
        let time = dropTime(info.location)
        setIndicator(nil)
        stopAutoScroll()
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            Task { @MainActor in perform(payload, index, time) }
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
