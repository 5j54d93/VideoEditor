//
//  CropStage.swift
//  VideoEditor
//
//  The reframing stage. It shows the *whole* source frame with the window over
//  it — choosing what to cut away is impossible against a picture the canvas has
//  already cut — and everything outside the window dimmed.
//
//  The window is the output frame. Under the default canvas-aspect lock what
//  sits inside it is exactly what the viewer gets, which is why the second
//  stage this replaced is no longer needed. When the window is deliberately a
//  different shape from the canvas, a dashed outline shows the letterbox.
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
    /// Points per source pixel at which the picture stops being filtered and
    /// starts simply being shown.
    ///
    /// Anything past 1:1 is magnification, and a magnified pixel that has been
    /// smoothed is a pixel whose edge has moved — which is the one thing the
    /// stage exists to let someone judge. Below 1:1 the picture is being reduced
    /// instead, where filtering is what keeps it readable.
    ///
    /// This used to be 4, which left the grain lagging the zoom over the whole
    /// 100%–400% range: you were magnifying the picture and still looking at an
    /// interpolation of it, until it snapped to real pixels at some number that
    /// had nothing to do with what you were doing.
    static let nearestNeighbourThreshold: CGFloat = 1

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

    /// The selection border's width: never more than half the pixel it marks,
    /// never thinner than a hairline.
    ///
    /// A fixed 1pt border is honest at fit zoom and a lie once the picture is
    /// magnified, where it spans a whole source pixel — so the closer someone
    /// gets to the edge they came to judge, the more of it the line is hiding.
    /// Half a pixel rather than a whole one, because a line that exactly covers
    /// the boundary pixel answers the question by erasing it.
    ///
    /// 0.5pt is the floor because it is the thinnest line a display can still
    /// draw crisply; past 1:1 there is nothing further to give, which is why the
    /// border is also drawn clear of the boundary rather than across it.
    static func borderWidth(pointsPerSourcePixel scale: CGFloat) -> CGFloat {
        min(1, max(0.5, 0.5 / max(scale, 0.0001)))
    }

    /// How many source pixels one point of pointer travel moves the rectangle:
    /// the inverse of the zoom, so the edge stays under the pointer.
    ///
    /// Which means the sizes a drag can reach are spaced this far apart. At the
    /// common half-size fit that is every second pixel, and an odd width cannot
    /// be dragged to at all — a screen point covers two source pixels there, and
    /// no amount of care lets one point pick between them.
    ///
    /// Capping this at one pixel per point was tried and taken back out. It does
    /// reach every size, but only by moving the rectangle slower than the hand:
    /// a hundred points of travel left the edge forty points behind the pointer,
    /// which is the one thing a crop tool cannot do — the whole act is aiming an
    /// edge at something in the picture. Precision belongs to the zoom instead,
    /// where it costs nothing: 實際像素 makes a point a pixel and every integer
    /// reachable, and the numbers rail takes an exact value at any zoom.
    static func sourcePixelsPerPoint(scale: CGFloat) -> CGFloat {
        1 / max(scale, 0.0001)
    }
}

// MARK: - Marquee

/// The rectangle a marquee drag describes, in source pixels.
///
/// Preview's model, and the reason it is worth copying: the rectangle you want
/// gets drawn where you want it, in one gesture. Walking it in from the four
/// edges of a rectangle that starts as the whole picture is the same job done
/// four times, and it is also the case where the zoom's own resolution bites
/// hardest — trimming 1920 down to 900 by eye is a long drag on an edge, and a
/// short one across the picture.
///
/// Kept apart from the view so it can be reasoned about as arithmetic: the
/// conversion out of screen space, the clamping to the picture, and the ratio
/// lock all have to agree, and none of them needs a view to be tested.
nonisolated enum CropMarquee {

    static func rect(from start: CGPoint, to end: CGPoint,
                     picture: CGRect, scale: CGFloat,
                     source: PixelSize, aspect: Double?) -> PixelRect {
        guard scale > 0, source.isUsable else {
            return PixelRect(x: 0, y: 0, width: source.width, height: source.height)
        }
        // A selection comes out of the picture that exists, so both ends are
        // pinned to the frame before anything else looks at them — dragging off
        // the edge stops at the edge instead of describing black.
        let ax = clamp(Double((start.x - picture.minX) / scale), 0, Double(source.width))
        let ay = clamp(Double((start.y - picture.minY) / scale), 0, Double(source.height))
        var bx = clamp(Double((end.x - picture.minX) / scale), 0, Double(source.width))
        var by = clamp(Double((end.y - picture.minY) / scale), 0, Double(source.height))

        if let aspect, aspect > 0 {
            // Whichever axis the hand has committed to leads, and the anchor
            // stays put: the corner under the pointer is the one that moves.
            let signX: Double = bx >= ax ? 1 : -1
            let signY: Double = by >= ay ? 1 : -1
            // Room left in the direction being dragged. Trimming the width by
            // the *height's* room as well is what keeps the ratio exact when a
            // drag runs into an edge, instead of the rectangle quietly squashing.
            let roomX = signX > 0 ? Double(source.width) - ax : ax
            let roomY = signY > 0 ? Double(source.height) - ay : ay
            let width = min(max(abs(bx - ax), abs(by - ay) * aspect), roomX, roomY * aspect)
            bx = ax + signX * width
            by = ay + signY * width / aspect
        }

        let x0 = Int(min(ax, bx).rounded()), x1 = Int(max(ax, bx).rounded())
        let y0 = Int(min(ay, by).rounded()), y1 = Int(max(ay, by).rounded())
        // Sizes below the model's own minimum are left as they are: clamping to
        // a legal window is the model's job, and doing it twice would move the
        // rectangle away from the corner the pointer is holding.
        return PixelRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    private static func clamp(_ v: Double, _ low: Double, _ high: Double) -> Double {
        min(max(low, v), high)
    }
}

// MARK: - Letterbox

/// The canvas outline's line segments, with the runs that lie along the
/// window's own border left out.
///
/// A letterbox is fitted around the window and keeps one of its dimensions, so
/// two of its four sides run down the selection border. Drawing them there was
/// drawing a second dashed line on top of the first, and the two are out of
/// step — [4, 3] against [4, 4] — so each fills the other's gaps and the pair
/// reads as a solid rule. Twice the width, too: the canvas line is a fixed 1pt
/// centred on the boundary, which is both thicker than the hairline `outline`
/// draws there and on the wrong side of it. Zooming in made it worse rather
/// than better, because only one of the two lines thins with the picture.
enum LetterboxOutline {
    static func segments(of rect: CGRect, around window: CGRect) -> [(CGPoint, CGPoint)] {
        var segments: [(CGPoint, CGPoint)] = []
        func line(_ a: CGPoint, _ b: CGPoint) { segments.append((a, b)) }

        if rect.height > window.height {
            // Taller than the window: the sides are shared and only the stubs
            // beyond the window's own top and bottom are ours to draw.
            line(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
            line(CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
            for x in [rect.minX, rect.maxX] {
                line(CGPoint(x: x, y: rect.minY), CGPoint(x: x, y: window.minY))
                line(CGPoint(x: x, y: window.maxY), CGPoint(x: x, y: rect.maxY))
            }
        } else {
            line(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
            line(CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
            for y in [rect.minY, rect.maxY] {
                line(CGPoint(x: rect.minX, y: y), CGPoint(x: window.minX, y: y))
                line(CGPoint(x: window.maxX, y: y), CGPoint(x: rect.maxX, y: y))
            }
        }
        return segments
    }
}

// MARK: - Crop stage

struct CropStage<Content: View>: View {
    let source: PixelSize
    /// In source pixels, and allowed to extend beyond the frame — outside it the
    /// output is black, which is what "fit the whole picture" amounts to.
    let window: PixelRect
    let canvasAspect: Double
    /// `nil` when the ratio is unconstrained.
    let lockedAspect: Double?
    @Binding var viewport: StageViewport
    let onChange: (PixelRect) -> Void
    let onGestureBegin: () -> Void
    let onGestureEnd: () -> Void
    /// Shown against the rectangle while it is being dragged. Enlarging past the
    /// source's own pixels is the one framing choice that costs picture quality,
    /// and it is decided during the drag rather than afterwards in a pane.
    var upscaleNote: String? = nil
    /// Receives the actual on-screen points per source pixel. The fit multiplier
    /// alone is not a picture magnification and made interpolation change at a
    /// different effective zoom for every pane and source size.
    @ViewBuilder var content: (_ pointsPerSourcePixel: CGFloat) -> Content

    /// Screen-space size of a grip's *drawing*. Constant: at 800% a grip that
    /// scaled with the picture would cover a quarter of the crop rect.
    private let gripSize: CGFloat = 7
    /// Screen-space size of a handle's *hit area*, which is deliberately much
    /// larger than the drawing. The two used to be the same 9pt square, and
    /// grabbing a corner was the single most frustrating thing about reframing.
    private let handleHitSize: CGFloat = 24
    /// How wide the grab strip along each edge is, centred on the line.
    private let edgeGrabWidth: CGFloat = 16
    /// How close to the pane edge a drag has to get before the view follows.
    private let autoPanMargin: CGFloat = 46
    /// Screen-space distance within which an edge is pulled onto a guide.
    private let snapDistance: CGFloat = 6

    @State private var dragOrigin: PixelRect?
    @State private var isDragging = false
    /// Dash offset of the selection border, animated forever while the stage is
    /// up. It is the one moving thing on the stage, and what it says is that the
    /// rectangle is a live selection rather than part of the picture.
    @State private var antPhase: CGFloat = 0
    /// Source-pixel coordinates the current drag landed on, for drawing the
    /// guide that claimed them.
    @State private var snappedX: Int?
    @State private var snappedY: Int?

    var body: some View {
        GeometryReader { geo in
            let fit = fitScale(in: geo.size)
            let scale = fit * viewport.zoom
            let picture = pictureRect(in: geo.size, scale: scale)
            let windowRect = rect(for: window, picture: picture, scale: scale)

            ZStack(alignment: .topLeading) {
                // Panning the view is only meaningful once there is more picture
                // than pane. At fit zoom this used to slide the whole picture
                // around for any drag that started outside the rectangle, which
                // read as the canvas wandering off on its own.
                Color.clear.contentShape(Rectangle())
                    .gesture(panGesture(pane: geo.size, scale: scale),
                             isEnabled: viewport.zoom > 1)
                    .pointingCursor(viewport.zoom > 1 ? .openHand : .arrow)

                content(scale)
                    .frame(width: picture.width, height: picture.height)
                    .placed(at: picture.origin, in: geo.size)
                    .allowsHitTesting(false)

                // Drawing a new rectangle. Sits on the picture and *under* the
                // current selection, so dragging inside that still moves it and
                // the grips still resize — anywhere else on the picture starts
                // again from scratch, which is how every selection tool on this
                // platform behaves.
                if let area = onPane(picture, geo.size) {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: area.width, height: area.height)
                        .placed(at: area.origin, in: geo.size)
                        .pointingCursor(.crosshair)
                        .gesture(marqueeGesture(picture: picture, scale: scale))
                }

                dimming(picture: picture, cropRect: windowRect)
                if scale >= StageViewport.pixelGridThreshold {
                    pixelGrid(picture: picture, scale: scale, size: geo.size)
                }
                if let letterbox = letterboxRect(around: windowRect) {
                    canvasOutline(letterbox, around: windowRect)
                }
                outline(windowRect, scale: scale)
                grips(windowRect, in: geo.size)
                if isDragging {
                    thirds(windowRect)
                    snapGuides(picture: picture, scale: scale, size: geo.size)
                    dragBadge(windowRect, in: geo.size)
                }

                // Dragging the rect's interior moves the whole crop. Sits under
                // the handles so a grab on a corner still resizes.
                if let interior = onPane(windowRect, geo.size) {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: interior.width, height: interior.height)
                        .placed(at: interior.origin, in: geo.size)
                        .pointingCursor(isDragging ? .closedHand : .openHand)
                        .gesture(dragGesture(scale: scale, pane: geo.size, handle: nil) { origin, dx, dy, _ in
                            PixelRect(x: origin.x + dx, y: origin.y + dy,
                                      width: origin.width, height: origin.height)
                        })
                }

                handles(windowRect: windowRect, scale: scale, pane: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // `clipped()` clips drawing, not hit testing. Without this the
            // gesture layers above keep receiving clicks outside the stage.
            .contentShape(Rectangle())
            .overlay(alignment: .top) { readout }
            .overlay(alignment: .bottom) { zoomStrip(fit: fit, pane: geo.size) }
            .background {
                TrackpadGestures(
                    onScroll: { delta in
                        guard viewport.zoom > 1 else { return }
                        viewport.pan = clampedPan(
                            CGSize(width: viewport.pan.width + delta.width,
                                   height: viewport.pan.height + delta.height),
                            pane: geo.size, scale: scale)
                    },
                    onMagnify: { factor in
                        viewport.setZoom(viewport.zoom * (1 + factor), fitScale: fit)
                        // Zooming out shrinks the room to pan; without this the
                        // picture stays wherever the old, larger bound left it.
                        viewport.pan = clampedPan(viewport.pan, pane: geo.size,
                                                  scale: fit * viewport.zoom)
                    })
            }
            .onChange(of: geo.size) { _, _ in
                viewport.setZoom(viewport.zoom, fitScale: fitScale(in: geo.size))
            }
        }
    }

    // MARK: Layout

    /// Points per source pixel with the whole frame visible, leaving a margin so
    /// the handles on its outer edge are still reachable.
    ///
    /// This used to have to account for a window larger than the source, and to
    /// be frozen mid-drag because that extent changed under the pointer. A
    /// window is now always inside the frame, so the fit depends on the source
    /// alone and simply cannot move while dragging.
    private func fitScale(in pane: CGSize) -> CGFloat {
        guard source.isUsable, pane.width > 0, pane.height > 0 else { return 1 }
        return min((pane.width - 40) / CGFloat(max(1, source.width)),
                   (pane.height - 40) / CGFloat(max(1, source.height)))
    }

    /// The source picture's rect, anchored on the *source* and moved only by an
    /// explicit pan.
    ///
    /// This used to centre on the window instead, the idea being that the thing
    /// under adjustment should stay put while the picture slid beneath it. In
    /// the hand it is the opposite of direct manipulation: the rectangle you are
    /// dragging never moves, the photograph lurches around behind it, and the
    /// pointer agrees with neither. The picture is the fixed thing you are
    /// choosing a region of; the rectangle is what moves.
    private func pictureRect(in pane: CGSize, scale: CGFloat) -> CGRect {
        let size = CGSize(width: CGFloat(source.width) * scale,
                          height: CGFloat(source.height) * scale)
        return CGRect(x: (pane.width - size.width) / 2 + viewport.pan.width,
                      y: (pane.height - size.height) / 2 + viewport.pan.height,
                      width: size.width, height: size.height)
    }

    /// The canvas the window is fitted into, when the two are different shapes.
    /// The gap between them is the letterbox the export will add.
    private func letterboxRect(around windowRect: CGRect) -> CGRect? {
        guard canvasAspect > 0, windowRect.width > 0, windowRect.height > 0 else { return nil }
        let windowAspect = windowRect.width / windowRect.height
        guard abs(windowAspect - canvasAspect) > 0.001 else { return nil }
        let size = windowAspect > canvasAspect
            ? CGSize(width: windowRect.width, height: windowRect.width / canvasAspect)
            : CGSize(width: windowRect.height * canvasAspect, height: windowRect.height)
        return CGRect(x: windowRect.midX - size.width / 2,
                      y: windowRect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func canvasOutline(_ rect: CGRect, around window: CGRect) -> some View {
        Path { path in
            for (a, b) in LetterboxOutline.segments(of: rect, around: window) {
                path.move(to: a)
                path.addLine(to: b)
            }
        }
        .stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .allowsHitTesting(false)
    }

    private func rect(for crop: PixelRect, picture: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: picture.minX + CGFloat(crop.x) * scale,
               y: picture.minY + CGFloat(crop.y) * scale,
               width: CGFloat(crop.width) * scale,
               height: CGFloat(crop.height) * scale)
    }

    // MARK: Chrome

    /// Lighter while dragging, not darker. Choosing where to cut means judging
    /// what is being thrown away, and that is exactly the part under the mask —
    /// so the mask gets out of the way for as long as the decision is live.
    private func dimming(picture: CGRect, cropRect: CGRect) -> some View {
        Canvas { context, _ in
            var path = Path(picture)
            path.addRect(cropRect)
            context.fill(path, with: .color(.black.opacity(isDragging ? 0.35 : 0.6)),
                         style: FillStyle(eoFill: true))
        }
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .allowsHitTesting(false)
    }

    /// Marching ants: one dashed hairline, with real gaps in it.
    ///
    /// The classical pair — a solid white line with black dashes crawling along
    /// it — is neutral on any picture, but the black only ever *tints* the white
    /// rather than breaking it, so from any normal viewing distance the border
    /// reads as a solid white rule drawn around the photograph. A single dashed
    /// line is quieter and still says *live selection*: the motion does that,
    /// not the weight. Legibility on a pale picture comes from the hairline of
    /// shadow instead, the same trick the grips use.
    private func outline(_ rect: CGRect, scale: CGFloat) -> some View {
        let width = StageViewport.borderWidth(pointsPerSourcePixel: scale)
        // Outset by half the line, so the stroke sits entirely on the discarded
        // side and its inner edge lands exactly on the boundary. A stroke is
        // centred on its path by default, which means half of it always covers
        // kept picture — at high zoom, half of the very pixel the zoom was for.
        let path = Path(rect.insetBy(dx: -width / 2, dy: -width / 2))
        return path
            .stroke(.white.opacity(0.8),
                    style: StrokeStyle(lineWidth: width, dash: [4, 4],
                                       dashPhase: antPhase))
            .shadow(color: .black.opacity(0.45), radius: 1)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.linear(duration: 0.75).repeatForever(autoreverses: false)) {
                    antPhase = -8
                }
            }
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

            // A centre mark as well as the thirds: centring a subject is at
            // least as common a composition as placing it on a third, and
            // eyeballing the middle of two thirds lines is not the same thing.
            var centre = Path()
            centre.move(to: CGPoint(x: rect.midX - 6, y: rect.midY))
            centre.addLine(to: CGPoint(x: rect.midX + 6, y: rect.midY))
            centre.move(to: CGPoint(x: rect.midX, y: rect.midY - 6))
            centre.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 6))
            context.stroke(centre, with: .color(.white.opacity(0.5)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// One line per source pixel. The heavier every-second line this used to
    /// draw existed only to explain the chroma-grid snapping; with the chain
    /// composing through yuv444p there is no coarser grid to land on.
    private func pixelGrid(picture: CGRect, scale: CGFloat, size: CGSize) -> some View {
        Canvas { context, _ in
            var fine = Path()
            let firstColumn = max(0, Int(floor((0 - picture.minX) / scale)))
            let lastColumn = min(source.width, Int(ceil((size.width - picture.minX) / scale)))
            if firstColumn <= lastColumn {
                for column in firstColumn...lastColumn {
                    let x = picture.minX + CGFloat(column) * scale
                    let top = max(0, picture.minY), bottom = min(size.height, picture.maxY)
                    fine.move(to: CGPoint(x: x, y: top))
                    fine.addLine(to: CGPoint(x: x, y: bottom))
                }
            }
            let firstRow = max(0, Int(floor((0 - picture.minY) / scale)))
            let lastRow = min(source.height, Int(ceil((size.height - picture.minY) / scale)))
            if firstRow <= lastRow {
                for row in firstRow...lastRow {
                    let y = picture.minY + CGFloat(row) * scale
                    let left = max(0, picture.minX), right = min(size.width, picture.maxX)
                    fine.move(to: CGPoint(x: left, y: y))
                    fine.addLine(to: CGPoint(x: right, y: y))
                }
            }
            // Difference blend rather than a fixed tint: at 1600% the picture
            // under the grid is one flat colour, and a translucent white line
            // disappears entirely on anything pale.
            context.blendMode = .difference
            context.stroke(fine, with: .color(.white.opacity(0.4)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    /// The lines the current drag has snapped onto, drawn the full height or
    /// width of the picture so it is obvious what the rectangle agreed with.
    private func snapGuides(picture: CGRect, scale: CGFloat, size: CGSize) -> some View {
        Canvas { context, _ in
            var path = Path()
            if let x = snappedX {
                let px = picture.minX + CGFloat(x) * scale
                path.move(to: CGPoint(x: px, y: max(0, picture.minY)))
                path.addLine(to: CGPoint(x: px, y: min(size.height, picture.maxY)))
            }
            if let y = snappedY {
                let py = picture.minY + CGFloat(y) * scale
                path.move(to: CGPoint(x: max(0, picture.minX), y: py))
                path.addLine(to: CGPoint(x: min(size.width, picture.maxX), y: py))
            }
            context.stroke(path, with: .color(.white.opacity(0.75)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// Sits against the rectangle rather than in a fixed corner: at any zoom
    /// worth using, a corner readout describes something the eye is nowhere
    /// near. Flips above the rectangle when there is no room below.
    private func dragBadge(_ rect: CGRect, in pane: CGSize) -> some View {
        let below = rect.maxY + 34 < pane.height
        return VStack(alignment: .leading, spacing: 1) {
            // verbatim: SwiftUI's own interpolation would render 1920 as "1,920".
            Text(verbatim: "\(window.width)×\(window.height) @ \(window.x),\(window.y)")
                .foregroundStyle(.white.opacity(0.9))
            if let upscaleNote {
                Text(upscaleNote).foregroundStyle(.orange)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
        .fixedSize()
        .placed(at: CGPoint(x: max(6, rect.minX),
                            y: below ? rect.maxY + 7 : max(6, rect.minY - 30)),
                in: pane)
        .allowsHitTesting(false)
    }

    private var readout: some View {
        // verbatim: SwiftUI's own interpolation would render 1920 as "1,920".
        Text(verbatim: "\(window.width)×\(window.height) @ \(window.x),\(window.y)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .padding(8)
            .opacity(isDragging ? 0 : 1)   // the badge takes over during a drag
            .allowsHitTesting(false)
    }

    /// Floats over the stage rather than sitting in the toolbar: the percentage
    /// is a property of this view, and the toolbar has no room for it.
    private func zoomStrip(fit: CGFloat, pane: CGSize) -> some View {
        HStack(spacing: 9) {
            Button("適合") { viewport = StageViewport() }
                .disabled(viewport.zoom == 1)
            Slider(value: Binding(get: { viewport.zoom },
                                  set: {
                                      viewport.setZoom($0, fitScale: fit)
                                      viewport.pan = clampedPan(viewport.pan, pane: pane,
                                                                scale: fit * viewport.zoom)
                                  }),
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

    /// All eight, always.
    ///
    /// A locked ratio used to hide the four edge handles, on the grounds that an
    /// edge moves one axis and the lock forbids exactly that. But the lock does
    /// not forbid the drag, it *determines the other axis* — and hiding the
    /// handles left the most natural way to grab a rectangle doing nothing at
    /// all, on the most common setting in the app.
    private var activeHandles: [CropHandle] { CropHandle.allCases }

    /// Every edge, along its whole length, plus the four corners on top.
    ///
    /// The edges used to be a 20pt bar at the midpoint of each side. Nothing on
    /// screen said that only the middle of a line could be grabbed, so the rest
    /// of the line — which is most of it, and the obvious place to aim — did
    /// nothing, and the drag fell through to the layer behind.
    ///
    /// Every target is trimmed to the pane first. Zoomed in, the rectangle is
    /// several times the size of the stage and starts well outside it; a hit
    /// area cut to that shape reaches past the stage and over the window's own
    /// buttons, where it silently eats the click meant for 完成 and drags the
    /// picture instead.
    @ViewBuilder
    private func handles(windowRect: CGRect, scale: CGFloat, pane: CGSize) -> some View {
        ForEach(CropHandle.edges, id: \.self) { handle in
            if let strip = onPane(edgeStrip(handle, in: windowRect), pane) {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: strip.width, height: strip.height)
                    .placed(at: strip.origin, in: pane)
                    .pointingCursor(handle.cursor)
                    .gesture(resizeGesture(handle, scale: scale, pane: pane))
            }
        }
        // After the edges, so a corner grab always wins the overlap.
        ForEach(CropHandle.corners, id: \.self) { handle in
            if let box = onPane(cornerBox(handle, in: windowRect), pane) {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: box.width, height: box.height)
                    .placed(at: box.origin, in: pane)
                    .pointingCursor(handle.cursor)
                    .gesture(resizeGesture(handle, scale: scale, pane: pane))
            }
        }
    }

    /// The part of `rect` that is actually on the stage, or `nil` when none of
    /// it is. Interactive layers are built from this and never from the raw
    /// rectangle — see `handles`.
    private func onPane(_ rect: CGRect, _ pane: CGSize) -> CGRect? {
        let visible = rect.intersection(CGRect(origin: .zero, size: pane))
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
        return visible
    }

    private func cornerBox(_ handle: CropHandle, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + rect.width * handle.unit.x - handleHitSize / 2,
               y: rect.minY + rect.height * handle.unit.y - handleHitSize / 2,
               width: handleHitSize, height: handleHitSize)
    }

    /// Eight small square grips, corners and edge midpoints alike.
    ///
    /// The corner brackets these replace drew two arms *inside* the rectangle,
    /// which said "corner" but not "handle", and said nothing at all about the
    /// four edges — those were live along their whole length with no mark to
    /// show it, so the most natural way to grab a rectangle looked inert until
    /// the pointer happened to cross it.
    ///
    /// Drawn separately from the hit areas, at the true positions: trimming a
    /// hit area to the pane must not drag its drawing along with it.
    ///
    /// These and the resize cursor are the whole of the answer to "can I grab
    /// this?". A hovered edge also used to light up under a 3pt bar of flat
    /// white running its full length — which, magnified, is a solid rule from
    /// one end of the stage to the other, laid down the moment the pointer
    /// approaches the edge, over the one part of the picture the zoom was for.
    private func grips(_ rect: CGRect, in pane: CGSize) -> some View {
        ForEach(CropHandle.allCases, id: \.self) { handle in
            Rectangle()
                .fill(.white)
                .frame(width: gripSize, height: gripSize)
                // A hairline of shadow, so a grip sitting on a white part of the
                // picture is still a grip rather than a hole.
                .shadow(color: .black.opacity(0.5), radius: 1)
                .placed(at: CGPoint(
                    x: rect.minX + rect.width * handle.unit.x - gripSize / 2,
                    y: rect.minY + rect.height * handle.unit.y - gripSize / 2),
                        in: pane)
        }
        .allowsHitTesting(false)
    }

    /// A grab strip centred on one side of the rectangle, running its full
    /// length. Deliberately reaches a little outside the rectangle as well as
    /// inside, so aiming slightly wide still lands on the edge.
    private func edgeStrip(_ handle: CropHandle, in rect: CGRect) -> CGRect {
        let reach = edgeGrabWidth / 2
        switch handle {
        case .top:
            return CGRect(x: rect.minX, y: rect.minY - reach,
                          width: rect.width, height: edgeGrabWidth)
        case .bottom:
            return CGRect(x: rect.minX, y: rect.maxY - reach,
                          width: rect.width, height: edgeGrabWidth)
        case .left:
            return CGRect(x: rect.minX - reach, y: rect.minY,
                          width: edgeGrabWidth, height: rect.height)
        default:
            return CGRect(x: rect.maxX - reach, y: rect.minY,
                          width: edgeGrabWidth, height: rect.height)
        }
    }

    /// Drawing a fresh rectangle over the picture.
    ///
    /// The 4pt threshold is what keeps a click from becoming a crop: without it
    /// every stray press on the picture would replace the framing with a
    /// two-pixel rectangle, and the undo stack would fill with them.
    private func marqueeGesture(picture: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onGestureBegin()
                }
                onChange(CropMarquee.rect(from: value.startLocation, to: value.location,
                                          picture: picture, scale: scale,
                                          source: source,
                                          aspect: marqueeAspect(NSEvent.modifierFlags)))
            }
            .onEnded { _ in
                isDragging = false
                onGestureEnd()
            }
    }

    /// ⇧ inverts the persistent lock here as it does everywhere else, with the
    /// one difference that a marquee has no shape to take when it comes free —
    /// there is no rectangle yet. It constrains to a square instead, which is
    /// both the useful thing to ask for and what the rest of the platform does
    /// with ⇧ on a selection.
    private func marqueeAspect(_ modifiers: NSEvent.ModifierFlags) -> Double? {
        guard modifiers.contains(.shift) else { return lockedAspect }
        return lockedAspect == nil ? 1 : nil
    }

    private func resizeGesture(_ handle: CropHandle, scale: CGFloat, pane: CGSize) -> some Gesture {
        dragGesture(scale: scale, pane: pane, handle: handle) { origin, dx, dy, mods in
            handle.resize(origin, dx: dx, dy: dy,
                          lockedAspect: effectiveAspect(origin, modifiers: mods),
                          fromCentre: mods.contains(.option))
        }
    }

    /// ⇧ inverts whatever the persistent lock says: locked drags come free, and
    /// a free drag takes the rectangle's current shape with it.
    private func effectiveAspect(_ origin: PixelRect,
                                 modifiers: NSEvent.ModifierFlags) -> Double? {
        guard modifiers.contains(.shift) else { return lockedAspect }
        guard lockedAspect == nil else { return nil }
        guard origin.height > 0 else { return nil }
        return Double(origin.width) / Double(origin.height)
    }

    /// Dragging the picture outside the crop rect pans the view, so the
    /// background is never dead space at high zoom.
    private func panGesture(pane: CGSize, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                var pan = viewport.pan
                pan.width += value.translation.width - lastPan.width
                pan.height += value.translation.height - lastPan.height
                viewport.pan = clampedPan(pan, pane: pane, scale: scale)
                lastPan = value.translation
            }
            .onEnded { _ in lastPan = .zero }
    }

    /// Keep the picture on the pane. Panning was unbounded, so a few flicks of
    /// the wrist could send the whole frame off the edge of the stage, leaving
    /// a dark rectangle and no obvious way back other than 適合.
    ///
    /// The bound is the picture's own overflow plus a margin: at any zoom you
    /// can bring either edge of the picture to the middle of the pane and no
    /// further.
    private func clampedPan(_ pan: CGSize, pane: CGSize, scale: CGFloat) -> CGSize {
        let overflowX = max(0, (CGFloat(source.width) * scale - pane.width) / 2)
        let overflowY = max(0, (CGFloat(source.height) * scale - pane.height) / 2)
        let slackX = overflowX + pane.width / 2 - 60
        let slackY = overflowY + pane.height / 2 - 60
        return CGSize(width: min(max(pan.width, -max(0, slackX)), max(0, slackX)),
                      height: min(max(pan.height, -max(0, slackY)), max(0, slackY)))
    }

    @State private var lastPan: CGSize = .zero

    private func dragGesture(scale: CGFloat, pane: CGSize, handle: CropHandle?,
                             _ transform: @escaping (PixelRect, Int, Int,
                                                     NSEvent.ModifierFlags) -> PixelRect)
    -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = window
                    isDragging = true
                    onGestureBegin()
                }
                guard let origin = dragOrigin, scale > 0 else { return }
                // Read the flags from the event stream rather than registering
                // modifier variants of the gesture: SwiftUI picks one variant
                // and there is no guarantee it is the one being held.
                let modifiers = NSEvent.modifierFlags
                let step = StageViewport.sourcePixelsPerPoint(scale: scale)
                let dx = Int((value.translation.width * step).rounded())
                let dy = Int((value.translation.height * step).rounded())
                let proposed = transform(origin, dx, dy, modifiers)
                onChange(snapping(proposed, handle: handle, step: step, modifiers: modifiers))
                autoPan(towards: value.location, in: pane, scale: scale)
            }
            .onEnded { _ in
                dragOrigin = nil
                isDragging = false
                snappedX = nil
                snappedY = nil
                onGestureEnd()
            }
    }

    /// Pull edges onto the source's own boundaries and centre lines.
    ///
    /// Deliberately not applied to a ratio-locked resize: snapping one axis
    /// there would either break the ratio or silently drag the other axis
    /// somewhere the pointer never went. Moving the whole rectangle keeps its
    /// shape by definition, so that case always snaps.
    private func snapping(_ rect: PixelRect, handle: CropHandle?,
                          step: CGFloat, modifiers: NSEvent.ModifierFlags) -> PixelRect {
        guard source.isUsable, step > 0, !modifiers.contains(.command) else {
            snappedX = nil; snappedY = nil; return rect
        }
        if handle != nil && lockedAspect != nil {
            snappedX = nil; snappedY = nil; return rect
        }
        // In the same pixels-per-point the drag itself is using, so the pull
        // stays a fixed distance on screen at every zoom.
        let tolerance = Int((snapDistance * step).rounded(.up))
        var result = rect
        var hitX: Int?
        var hitY: Int?

        func nearest(_ value: Int, _ targets: [Int]) -> Int? {
            targets.filter { abs($0 - value) <= tolerance }
                   .min { abs($0 - value) < abs($1 - value) }
        }

        if let handle {
            if handle.movesLeftEdge, let target = nearest(result.x, [0, source.width / 2]) {
                result.width += result.x - target
                result.x = target
                hitX = target
            }
            if handle.movesRightEdge,
               let target = nearest(result.x + result.width, [source.width, source.width / 2]) {
                result.width = target - result.x
                hitX = target
            }
            if handle.movesTopEdge, let target = nearest(result.y, [0, source.height / 2]) {
                result.height += result.y - target
                result.y = target
                hitY = target
            }
            if handle.movesBottomEdge,
               let target = nearest(result.y + result.height, [source.height, source.height / 2]) {
                result.height = target - result.y
                hitY = target
            }
        } else {
            // Flush left, flush right, or centred — the three positions anyone
            // ever nudges towards by eye.
            let centredX = (source.width - result.width) / 2
            if let target = nearest(result.x, [0, source.width - result.width, centredX]) {
                result.x = target
                hitX = target == centredX ? source.width / 2 : target
            }
            let centredY = (source.height - result.height) / 2
            if let target = nearest(result.y, [0, source.height - result.height, centredY]) {
                result.y = target
                hitY = target == centredY ? source.height / 2 : target
            }
        }
        snappedX = hitX
        snappedY = hitY
        return result
    }

    /// At high zoom the rest of the crop rect is off screen, so a handle taken
    /// to the edge of the pane pulls the picture after it. Driven by pointer
    /// movement rather than a timer: it follows the drag instead of running
    /// away on its own when the pointer stops.
    private func autoPan(towards point: CGPoint, in pane: CGSize, scale: CGFloat) {
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
        viewport.pan = clampedPan(CGSize(width: viewport.pan.width + delta.width * 0.3,
                                         height: viewport.pan.height + delta.height * 0.3),
                                  pane: pane, scale: scale)
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

    static var corners: [CropHandle] { [.topLeft, .topRight, .bottomLeft, .bottomRight] }
    static var edges: [CropHandle] { [.top, .bottom, .left, .right] }

    var isCorner: Bool { Self.corners.contains(self) }

    /// macOS 15 made the eight frame-resize cursors public API; before that the
    /// diagonals were private and everyone drew a crosshair instead.
    var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch self {
        case .topLeft:     position = .topLeft
        case .top:         position = .top
        case .topRight:    position = .topRight
        case .left:        position = .left
        case .right:       position = .right
        case .bottomLeft:  position = .bottomLeft
        case .bottom:      position = .bottom
        case .bottomRight: position = .bottomRight
        }
        return .frameResize(position: position, directions: .all)
    }

    /// The rect this drag asks for, in source pixels. Clamping into something
    /// the exporter can render belongs to the model, which owns what a legal
    /// window is.
    ///
    /// With a locked ratio the horizontal drag leads and the other axis follows,
    /// anchored at the corner opposite the one being held — so the corner under
    /// the pointer tracks it and the rest of the rectangle grows away from it.
    ///
    /// `fromCentre` (⌥) mirrors every edge the handle moves, so the rectangle
    /// grows around its middle instead of away from the opposite corner. It is
    /// how you resize a crop you have already centred on a subject.
    ///
    /// Mirroring is why a centred resize moves the width in twos: the grabbed
    /// edge follows the pointer and the opposite one answers it, so the width
    /// changes by twice the drag and an even one stays even. Splitting the drag
    /// between the two edges instead would reach every width, at the price of
    /// the grabbed edge moving at half the speed of the hand — the same trade
    /// the drag mapping refuses. Odd sizes come from a single edge, or from the
    /// numbers rail.
    func resize(_ rect: PixelRect, dx: Int, dy: Int, lockedAspect: Double?,
                fromCentre: Bool = false) -> PixelRect {
        var result = rect
        if movesLeftEdge { result.x += dx; result.width -= dx }
        if movesRightEdge { result.width += dx }
        if movesTopEdge { result.y += dy; result.height -= dy }
        if movesBottomEdge { result.height += dy }

        if fromCentre {
            if movesLeftEdge || movesRightEdge {
                let delta = movesLeftEdge ? -dx : dx
                result.x = rect.x - delta
                result.width = max(2, rect.width + delta * 2)
            }
            if movesTopEdge || movesBottomEdge {
                let delta = movesTopEdge ? -dy : dy
                result.y = rect.y - delta
                result.height = max(2, rect.height + delta * 2)
            }
            guard let aspect = lockedAspect, aspect > 0 else { return result }
            // Keep the centre fixed while the ratio re-derives the short axis.
            let centreX = rect.x + rect.width / 2
            let centreY = rect.y + rect.height / 2
            let width: Int, height: Int
            if abs(dx) >= abs(dy) {
                width = max(2, result.width)
                height = max(2, Int((Double(width) / aspect).rounded()))
            } else {
                height = max(2, result.height)
                width = max(2, Int((Double(height) * aspect).rounded()))
            }
            return PixelRect(x: centreX - width / 2, y: centreY - height / 2,
                             width: width, height: height)
        }

        guard let aspect = lockedAspect, aspect > 0 else { return result }

        // An edge handle under a locked ratio: the axis it owns leads, and the
        // other one is derived around the rectangle's own centre line. Falling
        // through to the corner logic below would instead hinge the whole shape
        // off one corner, so dragging the right edge would also walk the
        // rectangle downwards.
        if !isCorner {
            if movesLeftEdge || movesRightEdge {
                let width = max(2, result.width)
                let height = max(2, Int((Double(width) / aspect).rounded()))
                return PixelRect(x: result.x,
                                 y: rect.y + (rect.height - height) / 2,
                                 width: width, height: height)
            }
            let height = max(2, result.height)
            let width = max(2, Int((Double(height) * aspect).rounded()))
            return PixelRect(x: rect.x + (rect.width - width) / 2,
                             y: result.y,
                             width: width, height: height)
        }

        // Take whichever axis the pointer moved further on, so a diagonal drag
        // feels like it is following the hand rather than one chosen axis.
        let width: Int
        let height: Int
        if abs(dx) >= abs(dy) {
            width = max(2, result.width)
            height = max(2, Int((Double(width) / aspect).rounded()))
        } else {
            height = max(2, result.height)
            width = max(2, Int((Double(height) * aspect).rounded()))
        }
        // Re-anchor: the far edges stay where they were.
        let anchorX = movesLeftEdge ? rect.x + rect.width : rect.x
        let anchorY = movesTopEdge ? rect.y + rect.height : rect.y
        return PixelRect(x: movesLeftEdge ? anchorX - width : anchorX,
                         y: movesTopEdge ? anchorY - height : anchorY,
                         width: width, height: height)
    }

    var movesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottomEdge: Bool {
        self == .bottomLeft || self == .bottom || self == .bottomRight
    }
}

extension View {
    /// Set a cursor for as long as the pointer is over this view.
    ///
    /// `NSCursor.push()`/`pop()` keeps a stack, and SwiftUI's hover callbacks
    /// are not guaranteed to pair up when a view is removed mid-hover — an
    /// unbalanced stack leaves the wrong cursor on screen for the rest of the
    /// session. Setting outright cannot get out of step.
    func pointingCursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.set() } else { NSCursor.arrow.set() }
        }
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
