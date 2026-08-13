//
//  CropStage.swift
//  VideoEditor
//
//  裁剪來源 mode. Unlike the canvas stage, this shows the *whole* source frame:
//  choosing what to cut away is impossible against a picture the canvas has
//  already cut. The crop rect is drawn over it, everything outside dimmed.
//
//  Zoom lives here rather than in an NSScrollView. The handles have to stay a
//  fixed size on screen and a handle dragged to the edge has to pull the view
//  along with it, both of which mean owning the transform outright — at which
//  point a scroll view is only supplying trackpad events, and those come from a
//  much smaller piece of AppKit.
//

import SwiftUI
import AVKit
import AppKit

/// Pan and zoom for one editing session. View state, deliberately not part of
/// the project: where someone was looking is not an edit.
struct StageViewport: Equatable {
    /// Multiplier on the fit-to-pane scale. 1 shows the whole picture.
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    /// 1600% of the source, where one chroma step is still 32 points wide.
    static let maxPercent: CGFloat = 16
    /// Below this, a pixel grid would be denser than the pixels it describes.
    static let pixelGridThreshold: CGFloat = 8
    /// Points per source pixel beyond which interpolation turns pixel edges into
    /// gradients, and the whole point of zooming in is to see exactly where the
    /// edge is.
    static let nearestNeighbourThreshold: CGFloat = 4

    func zoomLimit(fitScale: CGFloat) -> CGFloat {
        max(1, Self.maxPercent / max(fitScale, 0.0001))
    }

    func percent(fitScale: CGFloat) -> Int {
        Int((fitScale * zoom * 100).rounded())
    }

    mutating func setZoom(_ value: CGFloat, fitScale: CGFloat) {
        zoom = min(max(1, value), zoomLimit(fitScale: fitScale))
        if zoom == 1 { pan = .zero }
    }

    /// Whether displaying one source pixel across this many screen points needs
    /// a hard edge. Kept here so callers cannot accidentally compare the
    /// fit-relative `zoom` value with an absolute pixel threshold again.
    static func usesNearestNeighbour(pointsPerSourcePixel: CGFloat) -> Bool {
        pointsPerSourcePixel >= nearestNeighbourThreshold
    }
}

// MARK: - Crop stage

struct CropStage<Content: View>: View {
    let source: PixelSize
    let crop: PixelRect
    @Binding var viewport: StageViewport
    let onChange: (PixelRect) -> Void
    let onGestureBegin: () -> Void
    let onGestureEnd: () -> Void
    /// Receives the actual on-screen points per source pixel. The fit multiplier
    /// alone is not a picture magnification and made interpolation change at a
    /// different effective zoom for every pane and source size.
    @ViewBuilder var content: (_ pointsPerSourcePixel: CGFloat) -> Content

    /// Screen-space size of a handle. Constant: at 800% a handle that scaled
    /// with the picture would cover a quarter of the crop rect.
    private let handleSize: CGFloat = 9
    /// How close to the pane edge a drag has to get before the view follows.
    private let autoPanMargin: CGFloat = 46

    @State private var dragOrigin: PixelRect?
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let fit = fitScale(in: geo.size)
            let scale = fit * viewport.zoom
            let picture = pictureRect(in: geo.size, scale: scale)
            let cropRect = rect(for: crop, picture: picture, scale: scale)

            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(panGesture)

                content(scale)
                    .frame(width: picture.width, height: picture.height)
                    .placed(at: picture.origin, in: geo.size)
                    .allowsHitTesting(false)

                dimming(picture: picture, cropRect: cropRect)
                if scale >= StageViewport.pixelGridThreshold {
                    pixelGrid(picture: picture, scale: scale, size: geo.size)
                }
                outline(cropRect)
                if isDragging { thirds(cropRect) }

                // Dragging the rect's interior moves the whole crop. Sits under
                // the handles so a grab on a corner still resizes.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: cropRect.width, height: cropRect.height)
                    .placed(at: cropRect.origin, in: geo.size)
                    .gesture(dragGesture(scale: scale, pane: geo.size) { origin, dx, dy in
                        PixelRect(x: origin.x + dx, y: origin.y + dy,
                                  width: origin.width, height: origin.height)
                    })

                handles(cropRect: cropRect, scale: scale, pane: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(alignment: .top) { readout }
            .overlay(alignment: .bottom) { zoomStrip(fit: fit) }
            .background {
                TrackpadGestures(
                    onScroll: { delta in
                        guard viewport.zoom > 1 else { return }
                        viewport.pan.width += delta.width
                        viewport.pan.height += delta.height
                    },
                    onMagnify: { factor in
                        viewport.setZoom(viewport.zoom * (1 + factor), fitScale: fit)
                    })
            }
            .onChange(of: geo.size) { _, _ in
                viewport.setZoom(viewport.zoom, fitScale: fitScale(in: geo.size))
            }
        }
    }

    // MARK: Layout

    /// Points per source pixel with the whole frame visible, leaving a margin so
    /// the handles on the outer edge are still reachable.
    private func fitScale(in pane: CGSize) -> CGFloat {
        guard source.isUsable, pane.width > 0, pane.height > 0 else { return 1 }
        return min((pane.width - 40) / CGFloat(source.width),
                   (pane.height - 40) / CGFloat(source.height))
    }

    private func pictureRect(in pane: CGSize, scale: CGFloat) -> CGRect {
        let size = CGSize(width: CGFloat(source.width) * scale,
                          height: CGFloat(source.height) * scale)
        return CGRect(x: (pane.width - size.width) / 2 + viewport.pan.width,
                      y: (pane.height - size.height) / 2 + viewport.pan.height,
                      width: size.width, height: size.height)
    }

    private func rect(for crop: PixelRect, picture: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: picture.minX + CGFloat(crop.x) * scale,
               y: picture.minY + CGFloat(crop.y) * scale,
               width: CGFloat(crop.width) * scale,
               height: CGFloat(crop.height) * scale)
    }

    // MARK: Chrome

    private func dimming(picture: CGRect, cropRect: CGRect) -> some View {
        Canvas { context, _ in
            var path = Path(picture)
            path.addRect(cropRect)
            context.fill(path, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    private func outline(_ rect: CGRect) -> some View {
        // Neutral white, not an accent: while composing, the eye belongs on the
        // picture rather than on the furniture around it.
        Path(rect).stroke(.white.opacity(0.9), lineWidth: 1)
            .allowsHitTesting(false)
    }

    private func thirds(_ rect: CGRect) -> some View {
        Canvas { context, _ in
            var path = Path()
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.28)), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }

    /// Fine lines are source pixels; heavy lines are the chroma grid the crop
    /// actually snaps to. Without the heavy ones the handles look like they are
    /// sticking, rather than landing where ffmpeg can reproduce them.
    private func pixelGrid(picture: CGRect, scale: CGFloat, size: CGSize) -> some View {
        Canvas { context, _ in
            var fine = Path()
            var chroma = Path()
            let firstColumn = max(0, Int(floor((0 - picture.minX) / scale)))
            let lastColumn = min(source.width, Int(ceil((size.width - picture.minX) / scale)))
            if firstColumn <= lastColumn {
                for column in firstColumn...lastColumn {
                    let x = picture.minX + CGFloat(column) * scale
                    let top = max(0, picture.minY), bottom = min(size.height, picture.maxY)
                    if column % 2 == 0 {
                        chroma.move(to: CGPoint(x: x, y: top))
                        chroma.addLine(to: CGPoint(x: x, y: bottom))
                    } else {
                        fine.move(to: CGPoint(x: x, y: top))
                        fine.addLine(to: CGPoint(x: x, y: bottom))
                    }
                }
            }
            let firstRow = max(0, Int(floor((0 - picture.minY) / scale)))
            let lastRow = min(source.height, Int(ceil((size.height - picture.minY) / scale)))
            if firstRow <= lastRow {
                for row in firstRow...lastRow {
                    let y = picture.minY + CGFloat(row) * scale
                    let left = max(0, picture.minX), right = min(size.width, picture.maxX)
                    if row % 2 == 0 {
                        chroma.move(to: CGPoint(x: left, y: y))
                        chroma.addLine(to: CGPoint(x: right, y: y))
                    } else {
                        fine.move(to: CGPoint(x: left, y: y))
                        fine.addLine(to: CGPoint(x: right, y: y))
                    }
                }
            }
            // Difference blend rather than a fixed tint: at 1600% the picture
            // under the grid is one flat colour, and a translucent white line
            // disappears entirely on anything pale.
            context.blendMode = .difference
            context.stroke(fine, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
            context.stroke(chroma, with: .color(.white.opacity(0.55)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var readout: some View {
        // verbatim: SwiftUI's own interpolation would render 1920 as "1,920".
        Text(verbatim: "\(crop.width)×\(crop.height) @ \(crop.x),\(crop.y)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .padding(8)
            .allowsHitTesting(false)
    }

    /// Floats over the stage rather than sitting in the toolbar: the percentage
    /// is a property of this view, and the toolbar has no room for it.
    private func zoomStrip(fit: CGFloat) -> some View {
        HStack(spacing: 9) {
            Button("適合") { viewport = StageViewport() }
                .disabled(viewport.zoom == 1)
            Slider(value: Binding(get: { viewport.zoom },
                                  set: { viewport.setZoom($0, fitScale: fit) }),
                   in: 1...viewport.zoomLimit(fitScale: fit))
                .frame(width: 96)
            Text(verbatim: "\(viewport.percent(fitScale: fit))%")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 44, alignment: .trailing)
            Button("實際像素") {
                viewport.setZoom(1 / max(fit, 0.0001), fitScale: fit)
            }
            .disabled(viewport.percent(fitScale: fit) == 100)
        }
        .font(.caption)
        .buttonStyle(.link)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(10)
    }

    // MARK: Gestures

    private func handles(cropRect: CGRect, scale: CGFloat, pane: CGSize) -> some View {
        ForEach(CropHandle.allCases, id: \.self) { handle in
            Rectangle()
                .fill(.white)
                .frame(width: handleSize, height: handleSize)
                .placed(at: CGPoint(
                    x: cropRect.minX + cropRect.width * handle.unit.x - handleSize / 2,
                    y: cropRect.minY + cropRect.height * handle.unit.y - handleSize / 2),
                        in: pane)
                .gesture(dragGesture(scale: scale, pane: pane) { origin, dx, dy in
                    handle.resize(origin, dx: dx, dy: dy)
                })
        }
    }

    /// Dragging the picture outside the crop rect pans the view, so the
    /// background is never dead space at high zoom.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                viewport.pan.width += value.translation.width - lastPan.width
                viewport.pan.height += value.translation.height - lastPan.height
                lastPan = value.translation
            }
            .onEnded { _ in lastPan = .zero }
    }

    @State private var lastPan: CGSize = .zero

    private func dragGesture(scale: CGFloat, pane: CGSize,
                             _ transform: @escaping (PixelRect, Int, Int) -> PixelRect)
    -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = crop
                    isDragging = true
                    onGestureBegin()
                }
                guard let origin = dragOrigin, scale > 0 else { return }
                let dx = Int((value.translation.width / scale).rounded())
                let dy = Int((value.translation.height / scale).rounded())
                onChange(transform(origin, dx, dy))
                autoPan(towards: value.location, in: pane)
            }
            .onEnded { _ in
                dragOrigin = nil
                isDragging = false
                onGestureEnd()
            }
    }

    /// At high zoom the rest of the crop rect is off screen, so a handle taken
    /// to the edge of the pane pulls the picture after it. Driven by pointer
    /// movement rather than a timer: it follows the drag instead of running
    /// away on its own when the pointer stops.
    private func autoPan(towards point: CGPoint, in pane: CGSize) {
        guard viewport.zoom > 1 else { return }
        var delta = CGSize.zero
        if point.x < autoPanMargin { delta.width = autoPanMargin - point.x }
        if point.x > pane.width - autoPanMargin {
            delta.width = -(point.x - (pane.width - autoPanMargin))
        }
        if point.y < autoPanMargin { delta.height = autoPanMargin - point.y }
        if point.y > pane.height - autoPanMargin {
            delta.height = -(point.y - (pane.height - autoPanMargin))
        }
        guard delta != .zero else { return }
        viewport.pan.width += delta.width * 0.3
        viewport.pan.height += delta.height * 0.3
    }
}

// MARK: - Handles

enum CropHandle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    /// Position within the crop rect, 0...1 on each axis.
    var unit: CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: 0, y: 0)
        case .top:         return CGPoint(x: 0.5, y: 0)
        case .topRight:    return CGPoint(x: 1, y: 0)
        case .left:        return CGPoint(x: 0, y: 0.5)
        case .right:       return CGPoint(x: 1, y: 0.5)
        case .bottomLeft:  return CGPoint(x: 0, y: 1)
        case .bottom:      return CGPoint(x: 0.5, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }

    /// The rect this drag asks for, in source pixels. Snapping to the chroma
    /// grid and clamping into the frame belong to the model, which owns what a
    /// legal crop is.
    func resize(_ rect: PixelRect, dx: Int, dy: Int) -> PixelRect {
        var result = rect
        if movesLeftEdge { result.x += dx; result.width -= dx }
        if movesRightEdge { result.width += dx }
        if movesTopEdge { result.y += dy; result.height -= dy }
        if movesBottomEdge { result.height += dy }
        return result
    }

    private var movesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    private var movesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
    private var movesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
    private var movesBottomEdge: Bool {
        self == .bottomLeft || self == .bottom || self == .bottomRight
    }
}

// MARK: - AppKit event bridge

/// Trackpad pinch and two-finger scroll, which SwiftUI's gesture set does not
/// deliver on macOS. Nothing else about the stage needs AppKit.
struct TrackpadGestures: NSViewRepresentable {
    let onScroll: (CGSize) -> Void
    let onMagnify: (CGFloat) -> Void

    func makeNSView(context: Context) -> TrackpadGestureView {
        let view = TrackpadGestureView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ view: TrackpadGestureView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
    }
}

final class TrackpadGestureView: NSView {
    var onScroll: ((CGSize) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    private var monitor: Any?

    /// SwiftUI draws its own content in front of this view, so hit-testing never
    /// reaches it and neither do `scrollWheel` or `magnify` — overriding them
    /// does nothing. A local monitor sees the events wherever they land, and
    /// claims only the ones inside this view's own bounds. The same trick the
    /// editor already uses to get ahead of the main menu for ⌘A.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) {
            [weak self] event in
            guard let self, let window = self.window else { return event }
            // A synthesised scroll can arrive with no window attached; fall back
            // to the pointer's own position rather than ignoring the event.
            let windowPoint: NSPoint
            if let eventWindow = event.window {
                guard eventWindow === window else { return event }
                windowPoint = event.locationInWindow
            } else {
                windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            }
            let point = self.convert(windowPoint, from: nil)
            guard self.bounds.contains(point) else { return event }
            if event.type == .magnify {
                self.onMagnify?(event.magnification)
            } else {
                self.onScroll?(CGSize(width: event.scrollingDeltaX,
                                      height: event.scrollingDeltaY))
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Picture layer

/// An `AVPlayerLayer` the caller can size exactly and switch to nearest-neighbour
/// magnification. `AVPlayerView` gives neither, and both matter once the picture
/// is blown up far enough to place a boundary on it.
struct RawPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var usesNearestNeighbour = false

    func makeNSView(context: Context) -> RawPlayerNSView {
        RawPlayerNSView(player: player, nearest: usesNearestNeighbour)
    }

    func updateNSView(_ view: RawPlayerNSView, context: Context) {
        view.setPlayer(player)
        view.setNearestNeighbour(usesNearestNeighbour)
    }
}

final class RawPlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer, nearest: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.videoGravity = .resize
        playerLayer.player = player
        setNearestNeighbour(nearest)
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // the frame is driven by a drag
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setPlayer(_ player: AVPlayer) {
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
    }

    func setNearestNeighbour(_ nearest: Bool) {
        let filter: CALayerContentsFilter = nearest ? .nearest : .linear
        guard playerLayer.magnificationFilter != filter else { return }
        playerLayer.magnificationFilter = filter
    }
}
