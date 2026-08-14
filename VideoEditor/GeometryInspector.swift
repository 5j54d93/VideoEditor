//
//  GeometryInspector.swift
//  VideoEditor
//
//  The 版面 pane: canvas size for the project, framing for the selected clip.
//  The framing is one rectangle — which part of the source the canvas shows —
//  so this is four numbers rather than the four separate concepts it replaced.
//  Dragging happens in the preview; the numbers remain how an exact value gets
//  committed.
//

import SwiftUI

struct GeometryInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        // The footer sits outside the scroll view. It carries the two actions
        // people reach for most, and inside it they were the first thing to fall
        // off the bottom edge — a warning appearing higher up was enough to push
        // them out of reach.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    canvasSection

                    if let item = model.activeItem {
                        Divider()
                        reframeButton(item)
                        framingSection(item)
                        windowSection(item)
                    } else {
                        Divider()
                        Text("選取時間軸上的片段以調整它的裁剪與位置")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let item = model.activeItem {
                Divider()
                footer(item)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    // MARK: Canvas

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("畫布")
            Picker("畫布尺寸", selection: canvasChoice) {
                Text("自動（依素材）").tag(CanvasChoice.automatic)
                ForEach(Array(EditorModel.canvasPresets.enumerated()), id: \.offset) { index, preset in
                    Text(preset.label).tag(CanvasChoice.preset(index))
                }
                Text("自訂…").tag(CanvasChoice.custom)
            }
            .labelsHidden()

            if let size = editableCanvasSize {
                HStack(spacing: 6) {
                    PixelField(label: "寬", value: size.width, range: 16...7680) {
                        model.setCanvasSizing(.custom(PixelSize(width: $0, height: size.height)))
                        return model.canvas.width
                    } onFocusChange: { model.isTextEditing = $0 }
                    PixelField(label: "高", value: size.height, range: 16...7680) {
                        model.setCanvasSizing(.custom(PixelSize(width: size.width, height: $0)))
                        return model.canvas.height
                    } onFocusChange: { model.isTextEditing = $0 }
                }
            }

            let canvas = model.canvas
            Text(verbatim: "輸出 \(canvas.width)×\(canvas.height) @ \(frameRateText(canvas.fpsValue))fps")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// The picker's selection is derived rather than stored: the canvas can also
    /// change through undo, and a stored selection would fall out of step.
    private var canvasChoice: Binding<CanvasChoice> {
        Binding {
            switch model.canvasSizing {
            case .automatic:
                return .automatic
            case .fixed(let size):
                return EditorModel.canvasPresets.firstIndex { $0.size == size }
                    .map { CanvasChoice.preset($0) } ?? .custom
            case .custom:
                return .custom
            }
        } set: { choice in
            switch choice {
            case .automatic:
                model.setCanvasSizing(.automatic)
            case .preset(let index):
                guard let preset = EditorModel.canvasPresets[safe: index] else { return }
                model.setCanvasSizing(.fixed(preset.size))
            case .custom:
                // Seed the custom fields with whatever is on screen, so picking
                // 自訂 never moves the canvas by itself.
                let canvas = model.canvas
                model.setCanvasSizing(.custom(PixelSize(width: canvas.width,
                                                        height: canvas.height)))
            }
        }
    }

    /// A legacy/programmatic fixed size that is not one of our named presets is
    /// also editable. Once changed it becomes an explicit custom selection.
    private var editableCanvasSize: PixelSize? {
        switch model.canvasSizing {
        case .custom(let size):
            return size
        case .fixed(let size) where !isPreset(size):
            return size
        case .automatic, .fixed:
            return nil
        }
    }

    private func isPreset(_ size: PixelSize) -> Bool {
        EditorModel.canvasPresets.contains { $0.size == size }
    }

    // MARK: Per-clip framing

    private func reframeButton(_ item: ClipItem) -> some View {
        Button {
            model.isGeometryEditing ? model.endGeometryEditing() : model.beginGeometryEditing()
        } label: {
            Label(model.isGeometryEditing ? "結束調整" : "在預覽中調整",
                  systemImage: model.isGeometryEditing ? "checkmark" : "crop")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .help("在預覽區直接拖曳畫面範圍（C）")
    }

    private func framingSection(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("構圖")
            // Presets set the rectangle rather than switching on a mode. Only
            // fit and fill stay live, because only they have anything worth
            // re-deriving when the canvas changes shape.
            HStack(spacing: 6) {
                Button("完整放入") { model.setFraming(.automatic(.fit), for: item.id) }
                Button("填滿") { model.setFraming(.automatic(.fill), for: item.id) }
                Button("原尺寸") { model.setActualSizeFraming(for: item.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            SectionLabel("比例")
            Picker("比例", selection: Binding(
                get: { item.geometry.aspectLock },
                set: { model.setAspectLock($0, for: item.id) }
            )) {
                Text("畫布比例").tag(AspectLock.canvas)
                Text("9:16").tag(AspectLock.ratio(width: 9, height: 16))
                Text("1:1").tag(AspectLock.ratio(width: 1, height: 1))
                Text("4:3").tag(AspectLock.ratio(width: 4, height: 3))
                Text("16:9").tag(AspectLock.ratio(width: 16, height: 9))
                Text("原始比例").tag(AspectLock.source)
                Text("自由").tag(AspectLock.free)
            }
            .labelsHidden()
        }
    }

    /// One rectangle: which part of the source the canvas shows. It replaced a
    /// crop, a fit mode, a magnification and an offset, which were all
    /// describing this rectangle's position and size.
    private func windowSection(_ item: ClipItem) -> some View {
        let source = item.sourcePixelSize
        let window = model.window(for: item)
        return VStack(alignment: .leading, spacing: 7) {
            SectionLabel("畫面範圍（來源像素）")
            if source.isUsable {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        PixelField(label: "寬", value: window.width, range: 2...(source.width * 4)) {
                            var updated = window; updated.width = $0
                            model.setFraming(.window(updated), for: item.id)
                            return model.items.first { $0.id == item.id }
                                .map { model.window(for: $0).width } ?? window.width
                        } onFocusChange: { model.isTextEditing = $0 }
                        PixelField(label: "高", value: window.height, range: 2...(source.height * 4)) {
                            var updated = window; updated.height = $0
                            model.setFraming(.window(updated), for: item.id)
                            return model.items.first { $0.id == item.id }
                                .map { model.window(for: $0).height } ?? window.height
                        } onFocusChange: { model.isTextEditing = $0 }
                    }
                    GridRow {
                        // The window may start outside the frame; that is how a
                        // deliberate letterbox is expressed.
                        PixelField(label: "X", value: window.x,
                                   range: -source.width...source.width) {
                            var updated = window; updated.x = $0
                            model.setFraming(.window(updated), for: item.id)
                            return model.items.first { $0.id == item.id }
                                .map { model.window(for: $0).x } ?? window.x
                        } onFocusChange: { model.isTextEditing = $0 }
                        PixelField(label: "Y", value: window.y,
                                   range: -source.height...source.height) {
                            var updated = window; updated.y = $0
                            model.setFraming(.window(updated), for: item.id)
                            return model.items.first { $0.id == item.id }
                                .map { model.window(for: $0).y } ?? window.y
                        } onFocusChange: { model.isTextEditing = $0 }
                    }
                }
                Text(verbatim: "來源 \(source.width)×\(source.height)")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                if let note = upscaleNote(item) {
                    Text(note).font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                Text("這個素材沒有回報畫面尺寸，無法調整構圖")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// Magnifying past the source's own pixels is allowed but worth saying out
    /// loud — it is the one framing choice that costs picture quality.
    private func upscaleNote(_ item: ClipItem) -> String? {
        guard let placement = model.placement(for: item) else { return nil }
        let window = model.window(for: item)
        guard window.width > 0, placement.scaledSize.width > window.width else { return nil }
        return "放大到來源像素之上，畫面會變糊"
    }

    private func footer(_ item: ClipItem) -> some View {
        HStack {
            Button("套用到全部片段") { model.applyGeometryToAllItems(from: item.id) }
                .disabled(model.items.count < 2)
            Spacer()
            Button("重設") { model.resetGeometry(for: item.id) }
                .disabled(item.geometry.isIdentity)
        }
        .font(.callout)
        .buttonStyle(.link)
    }

}

private func frameRateText(_ fps: Double) -> String {
    fps == fps.rounded() ? String(format: "%.0f", fps) : String(format: "%.3f", fps)
}

private enum CanvasChoice: Hashable {
    case automatic
    case preset(Int)
    case custom
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
