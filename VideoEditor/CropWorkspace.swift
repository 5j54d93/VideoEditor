//
//  CropWorkspace.swift
//  VideoEditor
//
//  Reframing used to be a swap inside the preview pane, which left the picture
//  being judged as the smallest thing on screen — squeezed between the library,
//  the inspector and the timeline — while most of the surrounding UI was quietly
//  inert: the transport keys were suppressed, the arrows belonged to the crop,
//  and clicking another clip dropped the mode entirely. Modal behaviour wearing
//  a non-modal face.
//
//  This takes the whole window instead, and puts back the only two things the
//  timeline was still being consulted for: which clip, and which frame. What it
//  deliberately does not put back is everything else — the library, the lanes,
//  the ruler, the tail marks. None of them answer a question a crop asks.
//

import SwiftUI
import AppKit

struct CropWorkspace<Picture: View>: View {
    let model: EditorModel
    let item: ClipItem
    @Binding var viewport: StageViewport
    /// The stage's picture layer, supplied by the caller so the workspace does
    /// not need to know about players, thumbnailers or image decoding.
    @ViewBuilder var picture: (_ pointsPerSourcePixel: CGFloat) -> Picture

    @AppStorage("showsCropNumbers") private var showsNumbers = true

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                stage
                if showsNumbers {
                    Divider().opacity(0.5)
                    CropNumbersRail(model: model, item: item)
                        .frame(width: 246)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            frameScrubber
            if model.items.count > 1 {
                Divider().opacity(0.5)
                clipRail
            }
        }
        .background(Color(white: 0.13))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "crop").foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.url.lastPathComponent)
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                if let position = clipPosition {
                    Text(position).font(.caption2).foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 12)

            Button { showsNumbers.toggle() } label: {
                Image(systemName: showsNumbers ? "sidebar.right" : "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("裁剪設定（⌥⌘I）")

            // The key equivalents belong to these two visible buttons rather
            // than to hidden ones elsewhere in the window: a real button in the
            // front-most view is what actually claims Esc and Return.
            Button { model.cancelGeometryEditing() } label: {
                HStack(spacing: 5) {
                    Text("取消")
                    KeyCapHint("esc")
                }
            }
            .keyboardShortcut(.cancelAction)
            Button { model.endGeometryEditing() } label: {
                HStack(spacing: 5) {
                    Text("完成")
                    KeyCapHint("↩", prominent: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(white: 0.17))
    }

    private var clipPosition: String? {
        guard let index = model.items.firstIndex(where: { $0.id == item.id }) else { return nil }
        // The picture on the stage, which is the turned one.
        let picture = item.orientedPixelSize
        return "片段 \(index + 1)／\(model.items.count) · \(picture.width)×\(picture.height)"
    }

    // MARK: Stage

    private var stage: some View {
        WorkspaceStage(model: model, item: item, viewport: $viewport, picture: picture)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Frame scrubber

    private var frameScrubber: some View {
        HStack(spacing: 10) {
            // The arrows themselves are spoken for by the crop rectangle, so
            // stepping frames lives on ⌥ — and on two buttons that say so.
            Button { model.stepGeometryFrame(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(item.isImage)
                .help("上一格（⌥←）")
            CropFrameScrubber(model: model, item: item)
                .frame(height: 40)
            Button { model.stepGeometryFrame(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(item.isImage)
                .help("下一格（⌥→）")
            Text(frameReadout)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 132, alignment: .trailing)
        }
        .buttonStyle(.link)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(white: 0.155))
    }

    private var frameReadout: String {
        guard !item.isImage else { return "靜態圖片" }
        let seconds = max(0, model.currentTime)
        return String(format: "f%d · %d:%02d.%03d", model.currentFrameIndex,
                      Int(seconds) / 60, Int(seconds) % 60,
                      Int((seconds - floor(seconds)) * 1000))
    }

    // MARK: Clip rail

    /// The tiles *are* the control. A pair of 上一段／下一段 buttons used to sit at
    /// the right of this rail, offering a slower way to reach a clip that was
    /// already on screen and asking the eye to leave the pictures to use it.
    private var clipRail: some View {
        ScrollViewReader { rail in
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(model.items) { clip in
                        CropClipTile(model: model, clip: clip, isActive: clip.id == item.id) {
                            model.retargetGeometryEditing(to: clip.id)
                        }
                        .id(clip.id)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            // With no buttons to walk the rail, the rail has to walk itself:
            // the clip being reframed must stay visible whether it was reached
            // by a key, by the timeline, or by entering the mode part-way in.
            .onAppear { rail.scrollTo(item.id, anchor: .center) }
            .onChange(of: item.id) { _, id in
                withAnimation(.snappy(duration: 0.2)) { rail.scrollTo(id, anchor: .center) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(white: 0.10))
        // [ and ] survive the buttons that used to carry them: a key equivalent
        // costs nothing on screen, and a hand already on the keyboard for ⌥←
        // should not have to reach for the mouse to change clip.
        .background {
            ZStack {
                Button("上一段") { model.stepGeometryTarget(by: -1) }
                    .keyboardShortcut("[", modifiers: [])
                Button("下一段") { model.stepGeometryTarget(by: 1) }
                    .keyboardShortcut("]", modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Stage

/// The stage, kept apart from the workspace around it because it is the part
/// that redraws for every step of a drag. It reads the draft the drag is
/// proposing; the title bar, frame strip and clip rail read only what is
/// stored, and so sit still until the drag lands.
private struct WorkspaceStage<Picture: View>: View {
    let model: EditorModel
    let item: ClipItem
    @Binding var viewport: StageViewport
    let picture: (_ pointsPerSourcePixel: CGFloat) -> Picture

    var body: some View {
        // The live canvas, not the stored one: for the clip that sets the
        // output size the two are the same rectangle, and a stored canvas
        // trailing the drag would read as a letterbox opening up mid-gesture.
        let canvas = model.displayedCanvas
        // The turned picture: the window is drawn on it, and the picture
        // layer turns the decoded frame to match.
        CropStage(source: item.orientedPixelSize,
                  window: model.displayedWindow(for: item),
                  canvasAspect: Double(canvas.width) / Double(max(1, canvas.height)),
                  lockedAspect: model.lockedAspect(for: item),
                  viewport: $viewport,
                  onChange: { model.previewFraming($0, for: item.id) },
                  onGestureBegin: { model.beginGeometryGesture(for: item.id) },
                  onGestureEnd: { model.endGeometryGesture() },
                  upscaleNote: upscaleNote,
                  content: picture)
    }

    /// Magnifying past the source's own pixels is allowed but worth saying out
    /// loud — it is the one framing choice that costs picture quality, and it is
    /// made during the drag, not afterwards in a pane.
    private var upscaleNote: String? {
        guard let placement = model.displayedPlacement(for: item) else { return nil }
        let window = model.displayedWindow(for: item)
        guard window.width > 0, placement.scaledSize.width > window.width else { return nil }
        let percent = Int((Double(placement.scaledSize.width) / Double(window.width) * 100).rounded())
        return "放大 \(percent)%，畫面會糊"
    }
}

// MARK: - Numbers rail

/// The exact-value half of reframing. It lives here as well as in the 版面
/// inspector because the inspector is a *project* pane the user may well have
/// closed: entering the workspace used to mean losing the only way to type a
/// number, and opening the pane first was a step nobody remembered to take.
private struct CropNumbersRail: View {
    let model: EditorModel
    let item: ClipItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CropRotationSection(model: model, item: item)
                Divider().opacity(0.4)
                CropRatioSection(model: model, item: item)
                Divider().opacity(0.4)
                windowSection
                Divider().opacity(0.4)
                outputSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(white: 0.155))
    }

    /// The numbers follow a drag as it happens, so these read the draft.
    private var windowSection: some View {
        let source = item.orientedPixelSize
        let window = model.displayedWindow(for: item)
        return VStack(alignment: .leading, spacing: 7) {
            RailLabel("畫面範圍（來源像素）")
            if source.isUsable {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        field("寬", window.width, 2...(source.width * 4)) {
                            var updated = window; updated.width = $0; return updated
                        }
                        field("高", window.height, 2...(source.height * 4)) {
                            var updated = window; updated.height = $0; return updated
                        }
                    }
                    GridRow {
                        // The window may start outside the frame; that is how a
                        // deliberate letterbox is expressed.
                        field("X", window.x, -source.width...source.width) {
                            var updated = window; updated.x = $0; return updated
                        }
                        field("Y", window.y, -source.height...source.height) {
                            var updated = window; updated.y = $0; return updated
                        }
                    }
                }
                // Turned, the numbers above are in the turned picture's pixels
                // — say so, or a 1080-wide source reads as cropped to 1920.
                Text(verbatim: item.geometry.rotation == .upright
                     ? "來源 \(source.width)×\(source.height)"
                     : "來源轉 \(item.geometry.rotation.degrees)° 後 \(source.width)×\(source.height)")
                    .font(.caption).foregroundStyle(.white.opacity(0.4)).monospacedDigit()
            } else {
                Text("這個素材沒有回報畫面尺寸，無法調整構圖")
                    .font(.caption).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func field(_ label: String, _ value: Int, _ range: ClosedRange<Int>,
                       _ change: @escaping (Int) -> PixelRect) -> some View {
        PixelField(label: label, value: value, range: range) { entered in
            model.setFraming(.window(change(entered)), for: item.id)
            guard let updated = model.items.first(where: { $0.id == item.id }) else { return value }
            let window = model.window(for: updated)
            switch label {
            case "寬": return window.width
            case "高": return window.height
            case "X": return window.x
            default: return window.y
            }
        } onFocusChange: { model.isTextEditing = $0 }
    }

    /// What the file will be. For the clip that sets the output size this is
    /// the rectangle above, restated — which is the point: there is nothing
    /// between the crop and the result to reason about.
    private var outputSection: some View {
        let output = model.displayedCanvas
        let window = model.displayedWindow(for: item)
        let setsOutput = model.itemDefiningOutputSize?.id == item.id
        let size = "\(output.width)×\(output.height)"
        return VStack(alignment: .leading, spacing: 7) {
            RailLabel("成品")
            // The one number in the workspace that changes while a drag is in
            // flight and is meant to be *read* rather than glanced at. Rolling
            // the digits keeps the eye on it: a value that redraws instantly
            // reads as a flicker, and the reflex is to look away until it settles.
            Text(verbatim: size)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: size)
            if setsOutput {
                RailNote("這一段決定成品尺寸")
            } else if window.width != output.width || window.height != output.height {
                // A file has one resolution. Anything cropped to a different
                // shape than the first clip has to be fitted into it.
                RailNote("成品尺寸由第 1 段決定，這段會縮放後放進去")
            }
            if output.hasOddDimension {
                RailNote("奇數尺寸以 4:4:4 輸出，檔案較大且不走硬體解碼")
            }
            if model.items.count > 1 {
                PresetRow(title: "套用到全部 \(model.items.count) 段",
                          detail: item.geometry.rotation == .upright
                              ? "把這塊裁切範圍複製到每一段"
                              : "把這段的旋轉和裁切範圍複製到每一段") {
                    model.applyGeometryToAllItems(from: item.id)
                }
            }
            // Only the crop: a turned clip stays turned. Turning it back is
            // what the two buttons at the top are for.
            PresetRow(title: "回到整張畫面", detail: "取消這段的裁切",
                      disabled: !item.geometry.isCropped) {
                model.resetGeometry(for: item.id)
            }
        }
    }
}

/// Quarter turns. First in the rail because it comes first in the picture:
/// the crop is drawn on whatever this leaves standing, and goes round with it.
/// Its own view for the same reason as the ratio section below.
private struct CropRotationSection: View {
    let model: EditorModel
    let item: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                RailLabel("旋轉")
                Text(verbatim: "\(item.geometry.rotation.degrees)°")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 6) {
                RailButton(title: "向左", systemImage: "rotate.left", key: "⇧R") {
                    model.rotateItems([item.id], by: -1)
                }
                .help("向左旋轉 90°（⇧R）")
                RailButton(title: "向右", systemImage: "rotate.right", key: "R") {
                    model.rotateItems([item.id], by: 1)
                }
                .help("向右旋轉 90°（R）")
            }
            if item.geometry.isCropped {
                RailNote("裁切範圍會跟著畫面一起轉")
            }
        }
    }
}

/// Its own view so a drag can leave it alone: the rail around it redraws for
/// every step of one, and nothing here depends on where the rectangle is.
private struct CropRatioSection: View {
    let model: EditorModel
    let item: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RailLabel("裁剪比例")
            Picker("裁剪比例", selection: Binding(
                get: { item.geometry.aspectLock },
                set: { model.setAspectLock($0, for: item.id) }
            )) {
                Text("自由").tag(AspectLock.free)
                Text("跟著原片").tag(AspectLock.source)
                Divider()
                Text("16:9").tag(AspectLock.ratio(width: 16, height: 9))
                Text("9:16").tag(AspectLock.ratio(width: 9, height: 16))
                Text("1:1").tag(AspectLock.ratio(width: 1, height: 1))
                Text("4:3").tag(AspectLock.ratio(width: 4, height: 3))
                // A quarter turn swaps a lock with the rectangle it describes,
                // so every ratio here needs its turned twin to land on.
                Text("3:4").tag(AspectLock.ratio(width: 3, height: 4))
            }
            .labelsHidden()
            RailNote(item.geometry.aspectLock == .free
                     ? "四邊都能自由拉動"
                     : "拖動時會固定成這個比例")
        }
    }
}

private struct RailLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RailNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.35))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A compact action in the rail, its shortcut beside it: two of these share a
/// row where a `PresetRow` would take one each.
private struct RailButton: View {
    let title: String
    let systemImage: String
    let key: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title).font(.callout)
                Spacer(minLength: 4)
                KeyCapHint(key)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(hovering ? 0.10 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A full-width row that names what it does and, underneath, what that means
/// for the picture.
private struct PresetRow: View {
    let title: String
    let detail: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(hovering && !disabled ? 0.10 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
    }
}

// MARK: - Frame scrubber

/// The clip's own frames, and nothing else. The timeline's strip carries lanes,
/// tails, trims and neighbours; none of that is being decided here, and all of
/// it would compete with the picture above for attention.
private struct CropFrameScrubber: View {
    let model: EditorModel
    let item: ClipItem

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                strip(width: geo.size.width, height: geo.size.height)
                playhead(in: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { seek(to: $0.location.x, width: geo.size.width) }
            )
        }
    }

    @ViewBuilder
    private func strip(width: CGFloat, height: CGFloat) -> some View {
        if item.isImage {
            ZStack {
                Color.white.opacity(0.06)
                Text("靜態圖片沒有影格可選")
                    .font(.caption2).foregroundStyle(.white.opacity(0.35))
            }
        } else {
            FilmstripStrip(source: item.orientedPixelSize,
                           rotation: item.geometry.rotation,
                           crop: model.visibleSourceRegion(for: item),
                           sourceRevision: model.videoSourceRevision(for: item.url),
                           thumbnailer: model.thumbnailer(for: item.url),
                           grid: item.grid,
                           start: item.inPoint, end: item.outPoint,
                           width: width, height: height)
        }
    }

    @ViewBuilder
    private func playhead(in size: CGSize) -> some View {
        if !item.isImage, let fraction = progress {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: size.height)
                .offset(x: (size.width - 2) * fraction)
                .allowsHitTesting(false)
        }
    }

    private var progress: CGFloat? {
        let span = item.outPoint - item.inPoint
        guard span > 0 else { return nil }
        return CGFloat(min(max(0, (model.currentTime - item.inPoint) / span), 1))
    }

    private func seek(to x: CGFloat, width: CGFloat) {
        guard !item.isImage, width > 0 else { return }
        let span = item.outPoint - item.inPoint
        guard span > 0 else { return }
        let target = item.inPoint + Double(min(max(0, x / width), 1)) * span
        // Land on a real frame: the crop is judged against a decoded picture,
        // and a time between two frames would decode the wrong one of them.
        model.seekGeometryFrame(to: target)
    }
}

// MARK: - Clip rail tile

private struct CropClipTile: View {
    let model: EditorModel
    let clip: ClipItem
    let isActive: Bool
    let select: () -> Void

    @State private var hovering = false

    private static let size = CGSize(width: 82, height: 48)

    var body: some View {
        // A real button rather than a tap gesture: the tile is now the only way
        // to change clip with the mouse, so it owes the pointer a lit edge on
        // hover and VoiceOver a control it can actually press.
        Button(action: select) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(border, lineWidth: isActive ? 1.5 : 1)
                    }
                // Which clips have already been reframed is the whole question
                // when walking a project, and it is exactly what `isIdentity`
                // answers.
                if !clip.geometry.isIdentity {
                    Circle().fill(.white).frame(width: 5, height: 5).padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(clip.url.lastPathComponent)
        .accessibilityLabel("\(clip.url.lastPathComponent)"
                            + (clip.geometry.isIdentity ? "" : "，已調整構圖"))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
    }

    private var border: Color {
        isActive ? .white : .white.opacity(hovering ? 0.5 : 0.12)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if clip.isImage {
            CropClipImageTile(url: clip.url,
                              source: clip.orientedPixelSize,
                              rotation: clip.geometry.rotation,
                              crop: model.visibleSourceRegion(for: clip))
        } else {
            FilmstripStrip(source: clip.orientedPixelSize,
                           rotation: clip.geometry.rotation,
                           crop: model.visibleSourceRegion(for: clip),
                           sourceRevision: model.videoSourceRevision(for: clip.url),
                           thumbnailer: model.thumbnailer(for: clip.url),
                           grid: clip.grid,
                           start: clip.inPoint, end: clip.outPoint,
                           width: Self.size.width, height: Self.size.height)
        }
    }
}

private struct CropClipImageTile: View {
    let url: URL
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
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}

/// An integer field that commits on Return or on losing focus, never per
/// keystroke: "1080" would otherwise pass through 1, 10 and 108 on the way, and
/// each of those is a clamped, undoable edit.
private struct PixelField: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    /// Applies the submitted value and returns the model's canonical value after
    /// clamping/snapping. Reading it back is necessary even for a model no-op,
    /// where SwiftUI emits no value-change notification.
    let onCommit: (Int) -> Int
    let onFocusChange: (Bool) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.callout, design: .monospaced))
                .focused($focused)
                .onSubmit(commit)
        }
        .onAppear { text = String(value) }
        // The model only changes after a commit, so adopting its value cannot
        // fight an in-progress keystroke. It *can* reflect a further model snap
        // (for example a 1001px canvas becoming the required even 1002px).
        .onChange(of: value) { _, new in
            text = String(new)
        }
        .onChange(of: focused) { _, isFocused in
            onFocusChange(isFocused)
            if !isFocused { commit() }
        }
    }

    private func commit() {
        guard let parsed = Int(text.trimmingCharacters(in: .whitespaces)) else {
            text = String(value)     // unparseable: put the real value back
            return
        }
        let clamped = min(max(range.lowerBound, parsed), range.upperBound)
        text = String(onCommit(clamped))
    }
}
