//
//  GeometryInspector.swift
//  VideoEditor
//
//  The 版面 pane: canvas size for the project, framing for the selected clip.
//  Numeric entry only — dragging the picture around in the preview comes later,
//  and the numbers stay the way to commit an exact value regardless.
//

import SwiftUI

struct GeometryInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                canvasSection

                if let item = model.activeItem {
                    Divider()
                    reframeButton(item)
                    fitSection(item)
                    cropSection(item)
                    placementSection(item)
                    Divider()
                    footer(item)
                } else {
                    Divider()
                    Text("選取時間軸上的片段以調整它的裁剪與位置")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
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

            if case .fixed(let size) = model.canvasSizing, !isPreset(size) {
                HStack(spacing: 6) {
                    PixelField(label: "寬", value: size.width, range: 16...7680) {
                        model.setCanvasSizing(.fixed(PixelSize(width: $0, height: size.height)))
                    } onFocusChange: { model.isTextEditing = $0 }
                    PixelField(label: "高", value: size.height, range: 16...7680) {
                        model.setCanvasSizing(.fixed(PixelSize(width: size.width, height: $0)))
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
                model.setCanvasSizing(.fixed(PixelSize(width: canvas.width,
                                                       height: canvas.height)))
            }
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
        .help("在預覽區直接拖曳裁剪框與畫面位置（C）")
    }

    private func fitSection(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("縮放方式")
            Picker("縮放方式", selection: Binding(
                get: { item.geometry.fit },
                set: { model.setFitMode($0, for: item.id) }
            )) {
                Text("完整放入").tag(FitMode.contain)
                Text("填滿").tag(FitMode.cover)
                Text("原尺寸").tag(FitMode.actual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func cropSection(_ item: ClipItem) -> some View {
        let source = item.sourcePixelSize
        let crop = item.geometry.sourceCrop
            ?? PixelRect(x: 0, y: 0, width: source.width, height: source.height)
        return VStack(alignment: .leading, spacing: 7) {
            SectionLabel("裁剪來源（像素）")
            if source.isUsable {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        PixelField(label: "寬", value: crop.width, range: 2...source.width) {
                            var updated = crop; updated.width = $0
                            model.setSourceCrop(updated, for: item.id)
                        } onFocusChange: { model.isTextEditing = $0 }
                        PixelField(label: "高", value: crop.height, range: 2...source.height) {
                            var updated = crop; updated.height = $0
                            model.setSourceCrop(updated, for: item.id)
                        } onFocusChange: { model.isTextEditing = $0 }
                    }
                    GridRow {
                        PixelField(label: "X", value: crop.x, range: 0...max(0, source.width - 2)) {
                            var updated = crop; updated.x = $0
                            model.setSourceCrop(updated, for: item.id)
                        } onFocusChange: { model.isTextEditing = $0 }
                        PixelField(label: "Y", value: crop.y, range: 0...max(0, source.height - 2)) {
                            var updated = crop; updated.y = $0
                            model.setSourceCrop(updated, for: item.id)
                        } onFocusChange: { model.isTextEditing = $0 }
                    }
                }
                Text(verbatim: "來源 \(source.width)×\(source.height)．座標吸附偶數")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            } else {
                Text("這個素材沒有回報畫面尺寸，無法裁剪")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func placementSection(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("畫布位置")
            HStack(spacing: 6) {
                PixelField(label: "位移 X", value: item.geometry.offset.x,
                           range: -model.canvas.width...model.canvas.width) {
                    model.setGeometryOffset(PixelOffset(x: $0, y: item.geometry.offset.y),
                                            for: item.id)
                } onFocusChange: { model.isTextEditing = $0 }
                PixelField(label: "位移 Y", value: item.geometry.offset.y,
                           range: -model.canvas.height...model.canvas.height) {
                    model.setGeometryOffset(PixelOffset(x: item.geometry.offset.x, y: $0),
                                            for: item.id)
                } onFocusChange: { model.isTextEditing = $0 }
            }

            SectionLabel("畫面縮放（輸出，非檢視）")
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { item.geometry.scale },
                    set: { model.setGeometryScale($0, for: item.id) }
                ), in: 0.05...4)
                Text(String(format: "%.0f%%", item.geometry.scale * 100))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            if let note = upscaleNote(item) {
                Text(note).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// Magnifying past the source's own pixels is allowed but worth saying out
    /// loud — it is the one framing choice that costs picture quality.
    private func upscaleNote(_ item: ClipItem) -> String? {
        guard let placement = model.placement(for: item) else { return nil }
        let source = item.geometry.sourceCrop?.size ?? item.sourcePixelSize
        guard source.isUsable, placement.scaledSize.width > source.width else { return nil }
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
    let onCommit: (Int) -> Void
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
        // While the field has focus the model's value is the one being typed
        // over; adopting it would fight the cursor.
        .onChange(of: value) { _, new in if !focused { text = String(new) } }
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
        onCommit(clamped)
        // The model may snap further (even alignment, bounds); show what it did
        // rather than what was typed.
        text = String(clamped)
    }
}
