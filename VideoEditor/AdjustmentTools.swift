//
//  AdjustmentTools.swift
//  VideoEditor
//
//  The toolbar's six adjustments — 裁切, 旋轉, 聲音, 片長, 尾端, 資訊 — and the
//  panels they open. They act on what R and M act on: the selection, or the
//  clip under the playhead when nothing is selected.
//

import AppKit
import SwiftUI

extension EditorModel.Adjustment {
    var title: String {
        switch self {
        case .crop: "裁切"
        case .rotate: "旋轉"
        case .sound: "聲音"
        case .length: "片長"
        case .tail: "尾端"
        case .info: "資訊"
        }
    }

    var systemImage: String {
        switch self {
        case .crop: "crop"
        case .rotate: "rotate.right"
        case .sound: "speaker.wave.2"
        case .length: "timer"
        case .tail: "waveform.badge.exclamationmark"
        case .info: "info.circle"
        }
    }

    /// Why a greyed-out tool has nothing to act on.
    var unavailableHelp: String {
        switch self {
        case .crop: "選一段影片或圖片"
        case .rotate: "選影片或圖片"
        case .sound: "選有聲音的影片或音訊"
        case .length: "只有圖片有片長"
        case .tail: "這段沒有尾端差異"
        case .info: "選一段影片、圖片或音訊"
        }
    }
}

// MARK: - The tools

/// One of the six: an icon that opens its panel under itself. A second click
/// on it closes the panel, and so do esc and a click anywhere else.
struct AdjustmentToolButton: View {
    let model: EditorModel
    let tool: EditorModel.Adjustment
    /// Where the button sits in the window, for centring the six over the picture.
    var onPlaced: (CGRect) -> Void = { _ in }

    /// A click on the tool whose panel is open closes the panel first — the
    /// popover goes on the mouse going down outside it — and reaches the
    /// button after, on the mouse coming up. Without this, that click would
    /// open the panel straight back up.
    private static var lastClosed: (tool: EditorModel.Adjustment, at: Date)?

    var body: some View {
        let available = model.canAdjust(tool)
        Button {
            if let closed = Self.lastClosed, closed.tool == tool,
               Date().timeIntervalSince(closed.at) < 0.4 {
                Self.lastClosed = nil
                return
            }
            model.openAdjustment = model.openAdjustment == tool ? nil : tool
        } label: {
            Label(tool.title, systemImage: tool.systemImage)
                .labelStyle(.iconOnly)
                .background(WindowFrameReader(onChange: onPlaced))
        }
        .disabled(!available)
        .help(available ? tool.title : "\(tool.title)：\(tool.unavailableHelp)")
        .popover(isPresented: Binding(
            get: { model.openAdjustment == tool },
            set: { shown in
                guard !shown, model.openAdjustment == tool else { return }
                Self.lastClosed = (tool, Date())
                model.openAdjustment = nil
            }), arrowEdge: .bottom) {
            AdjustmentPanel(model: model, tool: tool)
        }
    }
}

/// Where the tools go: their middle over the preview's. The toolbar can only
/// centre an item on the window, and the library pushes the picture off that
/// centre, so the six stand in the trailing group instead, with an empty item
/// after them whose width is found by looking where they landed. The group is
/// laid from the right, so every point of that width moves it a point left.
enum AdjustmentAlignment {
    static func gap(current: CGFloat, groupMidX: CGFloat, targetMidX: CGFloat) -> CGFloat {
        let error = groupMidX - targetMidX
        guard abs(error) >= 1 else { return current }
        return max(0, (current + error).rounded())
    }
}

/// Reports where it sits in its window, in window points, whenever that may
/// have changed — including when something above it moves, the way a toolbar
/// moves its items without telling them.
struct WindowFrameReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
        probe.scheduleReport()
    }

    final class Probe: NSView {
        var onChange: ((CGRect) -> Void)?
        private var last: CGRect?
        private var pending = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            var view = superview
            while let ancestor = view {
                ancestor.postsFrameChangedNotifications = true
                center.addObserver(self, selector: #selector(moved),
                                   name: NSView.frameDidChangeNotification, object: ancestor)
                view = ancestor.superview
            }
            center.addObserver(self, selector: #selector(moved),
                               name: NSWindow.didResizeNotification, object: window)
            scheduleReport()
        }

        override func layout() {
            super.layout()
            scheduleReport()
        }

        @objc private func moved(_ note: Notification) { scheduleReport() }

        /// After the layout pass in progress, never inside it.
        func scheduleReport() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pending = false
                guard window != nil else { return }
                let frame = convert(bounds, to: nil)
                guard frame != last else { return }
                last = frame
                onChange?(frame)
            }
        }
    }
}

// MARK: - The panels

/// What a tool's panel shows. Each one opens on the name of what it acts on.
struct AdjustmentPanel: View {
    let model: EditorModel
    let tool: EditorModel.Adjustment

    var body: some View {
        switch tool {
        case .crop: CropAdjustment(model: model)
        case .rotate: RotateAdjustment(model: model)
        case .sound: SoundAdjustment(model: model)
        case .length: LengthAdjustment(model: model)
        case .tail: TailAdjustment(model: model)
        case .info: InfoAdjustment(model: model)
        }
    }
}

/// A panel's first line: the tool, and what it is acting on — marked when
/// that is only the clip the playhead happens to be in.
struct AdjustmentHeader<Trailing: View>: View {
    let tool: EditorModel.Adjustment
    let subject: String
    var isUnderPlayhead = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tool.title).font(.headline)
            Text(subject)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if isUnderPlayhead {
                Text("（播放頭所在）")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension AdjustmentHeader where Trailing == EmptyView {
    init(tool: EditorModel.Adjustment, subject: String, isUnderPlayhead: Bool = false) {
        self.init(tool: tool, subject: subject, isUnderPlayhead: isUnderPlayhead) { EmptyView() }
    }
}

extension View {
    /// Every panel's size and spacing, so the six read as one family.
    func adjustmentPanelFrame() -> some View {
        controlSize(.small)
            .padding(14)
            .frame(width: 300, alignment: .leading)
    }
}

/// A button's words with its key beside them, as the row over the timeline
/// shows its edits.
private struct KeyedLabel: View {
    let title: String
    var systemImage: String? = nil
    let key: String

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
            KeyCapHint(key)
        }
    }
}

private struct CropAdjustment: View {
    let model: EditorModel

    var body: some View {
        if let item = model.adjustedClip {
            VStack(alignment: .leading, spacing: 10) {
                AdjustmentHeader(tool: .crop, subject: item.name,
                                 isUnderPlayhead: model.adjustmentSubject.isUnderPlayhead)
                HStack(spacing: 8) {
                    Button { model.beginGeometryEditing(on: item.id) } label: {
                        KeyedLabel(title: "進入裁切", key: "C")
                    }
                    Button("回到整張畫面") { model.resetGeometry(for: item.id) }
                        .disabled(!item.geometry.isCropped)
                }
                Text(summary(item))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .adjustmentPanelFrame()
        }
    }

    private func summary(_ item: ClipItem) -> String {
        let canvas = model.canvas
        var text = "輸出 \(canvas.width)×\(canvas.height)"
        if item.geometry.isCropped {
            let window = model.window(for: item)
            text += " · 裁切 \(window.width)×\(window.height)"
        } else {
            text += " · 沒有裁切"
        }
        return text
    }
}

private struct RotateAdjustment: View {
    let model: EditorModel

    var body: some View {
        let subject = model.adjustmentSubject
        let clips = model.items.filter { subject.clips.contains($0.id) }
        if !clips.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                AdjustmentHeader(tool: .rotate,
                                 subject: clips.count == 1 ? clips[0].name : "\(clips.count) 段",
                                 isUnderPlayhead: subject.isUnderPlayhead)
                HStack(spacing: 8) {
                    Button { model.rotateItems(Set(subject.clips), by: -1) } label: {
                        KeyedLabel(title: "向左", systemImage: "rotate.left", key: "⇧R")
                    }
                    Button { model.rotateItems(Set(subject.clips), by: 1) } label: {
                        KeyedLabel(title: "向右", systemImage: "rotate.right", key: "R")
                    }
                    Spacer(minLength: 0)
                    Text(angle(clips))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .adjustmentPanelFrame()
        }
    }

    private func angle(_ clips: [ClipItem]) -> String {
        let turns = Set(clips.map(\.geometry.rotation))
        guard turns.count == 1, let turn = turns.first else { return "角度不一" }
        return "目前 \(turn.degrees)°"
    }
}

/// One sound gets the exact sliders; several get what applies to all of them
/// at once — quiet, and a level nudge.
private struct SoundAdjustment: View {
    let model: EditorModel

    var body: some View {
        let subject = model.adjustmentSubject
        let clips = model.adjustedSoundClips
        if subject.pieces.count + clips.count == 1 {
            if let piece = subject.pieces.first {
                SoundShapingPanel(model: model, target: .piece(piece))
            } else {
                SoundShapingPanel(model: model, target: .original(clips[0]),
                                  isUnderPlayhead: subject.isUnderPlayhead)
            }
        } else if subject.pieces.count + clips.count > 1 {
            SeveralSounds(model: model, pieces: Set(subject.pieces), clips: Set(clips))
        }
    }
}

private struct SeveralSounds: View {
    let model: EditorModel
    let pieces: Set<AudioClip.ID>
    let clips: Set<ClipItem.ID>

    private var sounding: Bool {
        model.audioClips.contains { pieces.contains($0.id) && !$0.isMuted }
            || model.items.contains { clips.contains($0.id) && !$0.isAudioMuted }
    }

    var body: some View {
        let sounding = sounding
        VStack(alignment: .leading, spacing: 10) {
            AdjustmentHeader(tool: .sound, subject: "\(pieces.count + clips.count) 段聲音") {
                Button { model.setSoundMuted(sounding, pieces: pieces, clips: clips) } label: {
                    Image(systemName: sounding ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .frame(width: 16)
                }
                .help(sounding ? "全部靜音" : "全部取消靜音")
            }
            HStack(spacing: 8) {
                Text("音量").font(.callout).foregroundStyle(.secondary)
                Button { model.nudgeSoundGain(by: -0.05, pieces: pieces, clips: clips) } label: {
                    KeyedLabel(title: "−5%", key: "⌃−")
                }
                Button { model.nudgeSoundGain(by: 0.05, pieces: pieces, clips: clips) } label: {
                    KeyedLabel(title: "+5%", key: "⌃=")
                }
            }
            .disabled(!sounding)
            Text("一次調整所有選取的聲音。要精確的數字，選一段就好。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .adjustmentPanelFrame()
    }
}

/// A still's display time. It used to be a row that came and went above the
/// timeline, which jumped whenever it did.
private struct LengthAdjustment: View {
    let model: EditorModel

    var body: some View {
        if let item = model.adjustedClip, item.isImage {
            VStack(alignment: .leading, spacing: 10) {
                AdjustmentHeader(tool: .length, subject: item.name,
                                 isUnderPlayhead: model.adjustmentSubject.isUnderPlayhead)
                HStack(spacing: 8) {
                    Text("顯示").font(.callout).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { item.displayDuration },
                                          set: { model.setImageDuration($0, for: item.id) }),
                           in: 0.2...20,
                           onEditingChanged: { editing in
                               if editing {
                                   model.beginImageDurationEditing(for: item.id)
                               } else {
                                   model.endImageDurationEditing(for: item.id)
                               }
                           })
                    Text(String(format: "%.1f 秒", item.displayDuration))
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }
            }
            .adjustmentPanelFrame()
        }
    }
}

private struct TailAdjustment: View {
    let model: EditorModel

    var body: some View {
        if let item = model.adjustedClip, item.trailingOverhangDuration > 1e-9 {
            VStack(alignment: .leading, spacing: 10) {
                AdjustmentHeader(tool: .tail, subject: item.name,
                                 isUnderPlayhead: model.adjustmentSubject.isUnderPlayhead)
                Label("\(item.tailSourceName)比最後一格影像多 \(item.tailAmountText)",
                      systemImage: "waveform.badge.exclamationmark")
                    .foregroundStyle(Color.orange)
                Text("輸出會切齊最後一格影像；忽略只會讓提示消失。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("忽略") { model.dismissTrailingOverhang(for: item.id) }
                        .help("輸出本來就會切齊影像尾端，這只會讓提示消失")
                    if item.videoPadCandidate >= EditorModel.minimumWorthwhilePad {
                        Button("延長影像") { model.extendVideoToAudioTail(for: item.id) }
                            .help("在尾端補上真正的黑畫面，讓這段原音留在成品裡")
                    }
                    Button("放大到尾端") { model.zoomToTail(for: item.id) }
                        .help("放大時間軸，直到這個尾端有真實長度可看")
                }
            }
            .adjustmentPanelFrame()
        }
    }
}

private struct InfoAdjustment: View {
    let model: EditorModel

    var body: some View {
        if let piece = model.adjustedPiece {
            panel(subject: piece.name, isUnderPlayhead: false) {
                row("種類", "音檔")
                row("長度", seconds(piece.duration))
                row("位置", "從 \(clock(piece.timelineStart)) 起")
            }
        } else if let item = model.adjustedClip {
            panel(subject: item.name, isUnderPlayhead: model.adjustmentSubject.isUnderPlayhead) {
                row("種類", item.isImage ? "圖片" : "影片")
                row("解析度", "\(item.naturalWidth)×\(item.naturalHeight)")
                if !item.isImage {
                    row("影格率", fps(item.fps))
                }
                row("長度", seconds(item.displayDuration))
                if !item.isImage {
                    row("原音", !item.hasAudio ? "沒有" : item.isAudioMuted ? "已靜音" : "有")
                }
            }
        }
    }

    private func panel<Rows: View>(subject: String, isUnderPlayhead: Bool,
                                   @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AdjustmentHeader(tool: .info, subject: subject, isUnderPlayhead: isUnderPlayhead)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                rows()
            }
            .font(.callout)
        }
        .adjustmentPanelFrame()
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func seconds(_ value: Double) -> String { String(format: "%.2f 秒", value) }

    private func fps(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f fps", value) : String(format: "%.3f fps", value)
    }

    private func clock(_ value: Double) -> String {
        let x = max(0, value)
        return String(format: "%d:%02d.%03d", Int(x) / 60, Int(x) % 60, Int((x - floor(x)) * 1000))
    }
}

extension ClipItem {
    /// What runs past the last frame, as the tail's chip and panel name it.
    var tailSourceName: String { tailSource == .container ? "容器" : "原音" }

    /// How far it runs past, to the millisecond or a tenth of one.
    var tailAmountText: String {
        let ms = trailingOverhangDuration * 1_000
        return ms >= 100 ? String(format: "%.0f ms", ms) : String(format: "%.1f ms", ms)
    }
}
