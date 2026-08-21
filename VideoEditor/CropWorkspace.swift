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
        return "片段 \(index + 1)／\(model.items.count) · "
            + "\(item.sourcePixelSize.width)×\(item.sourcePixelSize.height)"
    }

    // MARK: Stage

    private var stage: some View {
        CropStage(source: item.sourcePixelSize,
                  window: model.window(for: item),
                  canvasAspect: Double(model.canvas.width) / Double(max(1, model.canvas.height)),
                  lockedAspect: model.lockedAspect(for: item),
                  viewport: $viewport,
                  onChange: { model.setFraming(.window($0), for: item.id) },
                  onGestureBegin: { model.beginGeometryGesture(for: item.id) },
                  onGestureEnd: { model.endGeometryGesture() },
                  upscaleNote: upscaleNote,
                  content: picture)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Magnifying past the source's own pixels is allowed but worth saying out
    /// loud — it is the one framing choice that costs picture quality, and it is
    /// made during the drag, not afterwards in a pane.
    private var upscaleNote: String? {
        guard let placement = model.placement(for: item) else { return nil }
        let window = model.window(for: item)
        guard window.width > 0, placement.scaledSize.width > window.width else { return nil }
        let percent = Int((Double(placement.scaledSize.width) / Double(window.width) * 100).rounded())
        return "放大 \(percent)%，畫面會糊"
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

    private var clipRail: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(model.items) { clip in
                        CropClipTile(model: model, clip: clip, isActive: clip.id == item.id)
                            .onTapGesture { model.retargetGeometryEditing(to: clip.id) }
                            .id(clip.id)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)

            Divider().frame(height: 22)
            Button { model.stepGeometryTarget(by: -1) } label: {
                HStack(spacing: 4) { Text("上一段"); KeyCapHint("[") }
            }
            .keyboardShortcut("[", modifiers: [])
            .disabled(model.geometryNeighbour(-1) == nil)
            Button { model.stepGeometryTarget(by: 1) } label: {
                HStack(spacing: 4) { Text("下一段"); KeyCapHint("]") }
            }
            .keyboardShortcut("]", modifiers: [])
            .disabled(model.geometryNeighbour(1) == nil)
        }
        .font(.caption)
        .buttonStyle(.link)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(white: 0.10))
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
                ratioSection
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

    // MARK: Ratio

    private var ratioSection: some View {
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
            }
            .labelsHidden()
            RailNote(item.geometry.aspectLock == .free
                     ? "四邊都能自由拉動"
                     : "拖動時會固定成這個比例")
        }
    }


    private var windowSection: some View {
        let source = item.sourcePixelSize
        let window = model.window(for: item)
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
                Text(verbatim: "來源 \(source.width)×\(source.height)")
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
        let output = model.canvas
        let window = model.window(for: item)
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
                          detail: "把這塊裁切範圍複製到每一段") {
                    model.applyGeometryToAllItems(from: item.id)
                }
            }
            PresetRow(title: "回到整張畫面", detail: "取消這段的裁切",
                      disabled: item.geometry.isIdentity) {
                model.resetGeometry(for: item.id)
            }
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
            FilmstripStrip(source: item.sourcePixelSize,
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

    private static let size = CGSize(width: 82, height: 48)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnail
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isActive ? .white : .white.opacity(0.12),
                                lineWidth: isActive ? 1.5 : 1)
                }
            // Which clips have already been reframed is the whole question when
            // walking a project, and it is exactly what `isIdentity` answers.
            if !clip.geometry.isIdentity {
                Circle().fill(.white).frame(width: 5, height: 5).padding(5)
            }
        }
        .help(clip.url.lastPathComponent)
        .accessibilityLabel("\(clip.url.lastPathComponent)"
                            + (clip.geometry.isIdentity ? "" : "，已調整構圖"))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if clip.isImage {
            CropClipImageTile(url: clip.url,
                              source: clip.sourcePixelSize,
                              crop: model.visibleSourceRegion(for: clip))
        } else {
            FilmstripStrip(source: clip.sourcePixelSize,
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
    let crop: PixelRect?
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.82)
                if let image {
                    Image(nsImage: image)
                        .resizable()
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
