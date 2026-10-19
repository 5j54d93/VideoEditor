//
//  CanvasStage.swift
//  VideoEditor
//
//  The preview's picture of the output frame. Until now the preview simply
//  filled its pane with whichever clip was selected, so there was nothing on
//  screen standing for the canvas — the thing every clip is actually composited
//  into. This draws it, and places the clip inside it exactly where export will.
//

import SwiftUI
import AppKit

/// The preview's half of the geometry: turning an export `Placement` back into
/// a rectangle on screen. Kept separate from the view so the invariant that
/// matters — the picture the preview draws is the picture the file gets — can be
/// asserted without a running window.
enum CanvasStageLayout {

    /// The canvas at the largest size that fits, aspect preserved.
    /// Shared so a drag can translate pane points back into canvas pixels using
    /// the very scale the canvas was drawn at.
    static func displaySize(canvas: CanvasSpec, in available: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0,
              available.width > 0, available.height > 0 else { return available }
        let scale = min(available.width / CGFloat(canvas.width),
                        available.height / CGFloat(canvas.height))
        // Preserve one common scale on both axes. Flooring each dimension
        // independently changes the aspect ratio; with a very tall custom
        // canvas, a nominal one-point width used to leave a sizeable strip at
        // the bottom that represented no output pixels at all.
        return CGSize(width: CGFloat(canvas.width) * scale,
                      height: CGFloat(canvas.height) * scale)
    }

    /// Display points per canvas pixel for a pane of this size.
    static func pointsPerCanvasPixel(canvas: CanvasSpec, in available: CGSize) -> CGFloat {
        displaySize(canvas: canvas, in: available).width / CGFloat(max(1, canvas.width))
    }

    /// The window on the canvas that the clip's kept pixels fill, in display
    /// points relative to the canvas's top-left.
    ///
    /// Content has to be clipped to *this*, not merely to the canvas. A crop
    /// makes the source frame wider than the region it keeps, and the discarded
    /// part lands inside the canvas where the canvas edge cannot cut it away.
    static func cropWindow(placement: Placement, pointsPerCanvasPixel scale: CGFloat) -> CGRect {
        CGRect(x: CGFloat(placement.origin.x) * scale,
               y: CGFloat(placement.origin.y) * scale,
               width: CGFloat(placement.scaledSize.width) * scale,
               height: CGFloat(placement.scaledSize.height) * scale)
    }

    /// Frame for the *whole* source picture, in display points relative to the
    /// canvas's top-left. Larger than the canvas whenever the clip is cropped:
    /// the caller clips, and what survives is the exported frame.
    ///
    /// `nil` when there is nothing to draw — no usable source size, or a
    /// placement that misses the canvas completely.
    static func sourceFrame(placement: Placement,
                            sourceSize: PixelSize,
                            pointsPerCanvasPixel scale: CGFloat) -> CGRect? {
        guard sourceSize.isUsable, !placement.isFullyOffCanvas, scale > 0 else { return nil }
        let crop = placement.sourceCrop ?? PixelRect(x: 0, y: 0,
                                                     width: sourceSize.width,
                                                     height: sourceSize.height)
        guard crop.width > 0, crop.height > 0 else { return nil }

        // Width and height round independently — `cover` can land them a pixel
        // apart — so each axis keeps its own factor rather than sharing one and
        // drifting from the exported frame.
        let zoomX = CGFloat(placement.scaledSize.width) / CGFloat(crop.width)
        let zoomY = CGFloat(placement.scaledSize.height) / CGFloat(crop.height)
        return CGRect(
            x: (CGFloat(placement.origin.x) - CGFloat(crop.x) * zoomX) * scale,
            y: (CGFloat(placement.origin.y) - CGFloat(crop.y) * zoomY) * scale,
            width: CGFloat(sourceSize.width) * zoomX * scale,
            height: CGFloat(sourceSize.height) * zoomY * scale)
    }
}

extension View {
    /// Pin a fixed-size layer at `origin` inside a `bounds`-sized slot without
    /// letting its own size inflate the stack around it.
    ///
    /// A `ZStack` takes the union of its children, so a child `.frame` wider
    /// than the stack — which is exactly what a zoomed or cropped picture is —
    /// grows the stack and silently re-centres every sibling's coordinate space,
    /// including the `Canvas` layers that draw on top. Reporting the slot size
    /// here keeps the stack the size the caller meant while `offset` still moves
    /// the content freely, and overflow is the caller's to clip.
    func placed(at origin: CGPoint, in bounds: CGSize) -> some View {
        offset(x: origin.x, y: origin.y)
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }

    /// Show only the part of a source frame that a crop keeps, filling `size`.
    /// The receiver must draw the *whole* source frame at whatever size it gets.
    ///
    /// Used by the timeline: the strip is the output's index, so pixels a crop
    /// removes should not survive there either. Placement on the canvas —
    /// letterboxing, offset, scale — deliberately does *not* show up here; a
    /// 70pt tile spent on black bars tells you less than one filled with
    /// picture, and the strip's job is to let you find a moment.
    ///
    /// With no crop the result is exactly `scaledToFill` plus centring, so an
    /// unreframed clip's strip is unchanged.
    func showingSourceRegion(_ crop: PixelRect?, of source: PixelSize,
                             filling size: CGSize) -> some View {
        Group {
            if let frame = SourceRegionLayout.wholeSourceFrame(crop: crop, source: source,
                                                               filling: size) {
                self.frame(width: frame.width, height: frame.height)
                    .placed(at: frame.origin, in: size)
            } else {
                scaledToFill()
            }
        }
        .clipped()
    }
}

// MARK: - Turned pictures

/// Every picture surface draws the source unturned — players, decoders and
/// `NSImage` all hand back the frame as the file plays it — while every frame
/// the geometry gives them is the turned shape. These put the turn in between,
/// exactly: a quarter turn is a matrix of zeros and ones, never a sine that
/// lands a hair off the axis and has the renderer resample what should only
/// have moved.
extension ClipRotation {
    /// The same turn, as SwiftUI draws a bitmap with it. The cheapest of the
    /// three: no extra view at all, which matters in a filmstrip.
    var imageOrientation: Image.Orientation {
        switch self {
        case .upright: .up
        case .clockwise: .right
        case .upsideDown: .down
        case .counterclockwise: .left
        }
    }

    /// Takes a box of `size` — the picture *before* the turn, top-left at the
    /// origin, y pointing down as SwiftUI's does — onto the turned box, also
    /// with its top-left at the origin.
    func placingTransform(for size: CGSize) -> CGAffineTransform {
        let w = size.width, h = size.height
        switch self {
        case .upright: return .identity
        case .clockwise: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .upsideDown: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .counterclockwise: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        }
    }
}

extension View {
    /// The receiver drawn turned, filling exactly the frame it is given. For
    /// SwiftUI content only: a SwiftUI transform is not guaranteed to reach an
    /// AppKit view inside it, so the players turn their own layers instead —
    /// see `CALayer.fill(_:turnedBy:)`.
    @ViewBuilder
    func turned(_ rotation: ClipRotation) -> some View {
        if rotation == .upright {
            self
        } else {
            TurnedLayout(swapsAxes: rotation.swapsAxes) {
                modifier(QuarterTurnEffect(rotation: rotation))
            }
        }
    }
}

/// Lays its one child out in the shape it has before the turn, at the top-left
/// of the turned bounds; `QuarterTurnEffect` then carries it onto them.
private struct TurnedLayout: Layout {
    let swapsAxes: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(unturned(proposal))
        return swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: unturned(ProposedViewSize(bounds.size)))
    }

    private func unturned(_ proposal: ProposedViewSize) -> ProposedViewSize {
        swapsAxes ? ProposedViewSize(width: proposal.height, height: proposal.width) : proposal
    }
}

private struct QuarterTurnEffect: GeometryEffect {
    let rotation: ClipRotation

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(rotation.placingTransform(for: size))
    }
}

extension CALayer {
    /// Cover `bounds` with this layer turned by `rotation`: sized to the
    /// unturned picture, centred, and turned about its middle. Through bounds
    /// and position rather than `frame`, which stops meaning anything once the
    /// transform is not the identity. Upright, it is exactly `frame = bounds`.
    ///
    /// `flipped` is whether the hosting view's y points down. Clockwise on
    /// screen is a negative angle in AppKit's default upward y, and the
    /// matrices are written out so that it stays exact either way.
    func fill(_ bounds: CGRect, turnedBy rotation: ClipRotation, flipped: Bool = false) {
        let size = rotation.swapsAxes
            ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        setAffineTransform(.identity)
        self.bounds = CGRect(origin: .zero, size: size)
        position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Clockwise quarter turns as an upward y sees them, which is how the
        // matrices below count; in a flipped view the same matrix turns the
        // other way, so the count is mirrored.
        let turns = flipped ? (4 - rotation.rawValue) % 4 : rotation.rawValue
        let turn: CGAffineTransform
        switch turns {
        case 1: turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        case 2: turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 3: turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        default: turn = .identity
        }
        setAffineTransform(turn)
    }
}

/// Where the whole source frame sits so that the kept region fills a tile.
/// Separated from the view so the property that matters can be asserted: with
/// no crop this has to reduce to exactly what the strip did before — fill and
/// centre — or every unreframed project's timeline shifts.
enum SourceRegionLayout {
    static func wholeSourceFrame(crop: PixelRect?, source: PixelSize,
                                 filling size: CGSize) -> CGRect? {
        let region = crop ?? PixelRect(x: 0, y: 0, width: source.width, height: source.height)
        guard source.isUsable, region.width > 0, region.height > 0,
              size.width > 0, size.height > 0 else { return nil }
        let scale = max(size.width / CGFloat(region.width),
                        size.height / CGFloat(region.height))
        return CGRect(
            x: (size.width - CGFloat(region.width) * scale) / 2 - CGFloat(region.x) * scale,
            y: (size.height - CGFloat(region.height) * scale) / 2 - CGFloat(region.y) * scale,
            width: CGFloat(source.width) * scale,
            height: CGFloat(source.height) * scale)
    }
}

/// A canvas-shaped frame with one clip's picture placed inside it.
///
/// The arithmetic comes from `FFTools.resolve`, the same function that writes
/// the ffmpeg arguments, so the preview cannot drift from the file. Everything
/// here is plain layout: `content` is sized to the *whole* scaled source frame
/// and offset so its cropped region lands where the placement says, and the
/// canvas clips whatever hangs over the edge. Sizing the content to the crop
/// and shifting the picture inside it would mean `contentsRect`, which is not
/// reliable on `AVPlayerLayer`.
struct CanvasStage<Content: View>: View {
    let canvas: CanvasSpec
    /// `nil` when the clip's pixel size never came back from probing. The
    /// content then just fills the canvas, matching what export falls back to.
    let placement: Placement?
    let sourceSize: PixelSize
    /// Outline the picture's placed extent, including the part the canvas cuts
    /// off. While dragging a clip around, the part that is *not* visible is
    /// exactly what needs judging.
    var showsPictureBounds = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let display = CanvasStageLayout.displaySize(canvas: canvas, in: geo.size)
            let scale = display.width / CGFloat(max(1, canvas.width))
            ZStack {
                if showsPictureBounds, let placement, !placement.isFullyOffCanvas {
                    pictureBounds(placement, display: display, scale: scale)
                }
                ZStack(alignment: .topLeading) {
                    Color.black
                    picture(scale: scale, display: display)
                }
                .frame(width: display.width, height: display.height)
                .clipped()
                // A hairline keeps the canvas readable as an object even when
                // the clip inside it is letterboxed to nothing but black.
                .overlay {
                    Rectangle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Drawn outside the clip, so it extends past the canvas edge.
    private func pictureBounds(_ placement: Placement,
                               display: CGSize, scale: CGFloat) -> some View {
        Rectangle()
            .stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: CGFloat(placement.scaledSize.width) * scale,
                   height: CGFloat(placement.scaledSize.height) * scale)
            .placed(at: CGPoint(x: CGFloat(placement.origin.x) * scale,
                                y: CGFloat(placement.origin.y) * scale),
                    in: display)
            .allowsHitTesting(false)
    }

    /// `scale` is display points per canvas pixel.
    ///
    /// Two nested clips, not one. The inner window is the region the crop keeps;
    /// the source frame around it is discarded there. The canvas then clips
    /// whatever of that window a nudge or a zoom pushed over its own edge.
    @ViewBuilder
    private func picture(scale: CGFloat, display: CGSize) -> some View {
        if let placement, let frame = CanvasStageLayout.sourceFrame(
            placement: placement, sourceSize: sourceSize, pointsPerCanvasPixel: scale) {
            let window = CanvasStageLayout.cropWindow(placement: placement,
                                                      pointsPerCanvasPixel: scale)
            content()
                .frame(width: frame.width, height: frame.height)
                .placed(at: CGPoint(x: frame.minX - window.minX,
                                    y: frame.minY - window.minY),
                        in: window.size)
                .clipped()
                .placed(at: window.origin, in: display)
        } else if placement == nil {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A fully off-canvas placement draws nothing: the black behind it is
        // exactly what the exported segment contains.
    }
}
