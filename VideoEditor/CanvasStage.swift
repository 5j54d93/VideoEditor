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
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let display = displaySize(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                picture(scale: display.width / CGFloat(max(1, canvas.width)))
            }
            .frame(width: display.width, height: display.height)
            .clipped()
            // A hairline keeps the canvas readable as an object even when the
            // clip inside it is letterboxed to nothing but black.
            .overlay {
                Rectangle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// `scale` is display points per canvas pixel.
    @ViewBuilder
    private func picture(scale: CGFloat) -> some View {
        if let placement, let frame = CanvasStageLayout.sourceFrame(
            placement: placement, sourceSize: sourceSize, pointsPerCanvasPixel: scale) {
            content()
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        } else if placement == nil {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A fully off-canvas placement draws nothing: the black behind it is
        // exactly what the exported segment contains.
    }

    /// The canvas at the largest whole-point size that fits, aspect preserved.
    private func displaySize(in available: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0,
              available.width > 0, available.height > 0 else { return available }
        let scale = min(available.width / CGFloat(canvas.width),
                        available.height / CGFloat(canvas.height))
        return CGSize(width: max(1, (CGFloat(canvas.width) * scale).rounded(.down)),
                      height: max(1, (CGFloat(canvas.height) * scale).rounded(.down)))
    }
}
