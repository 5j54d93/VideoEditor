//
//  VideoEditorApp.swift
//  VideoEditor
//
//  Created by 莊智凱 on 2026/7/14.
//

import SwiftUI

@main
struct VideoEditorApp: App {
    @State private var model = EditorModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .commands {
            // The library's header and its empty state both offer this; the
            // key lives here, once, where the menu bar shows it. Like the
            // header's button, it is out of reach under a sheet.
            CommandGroup(after: .newItem) {
                Button("加入素材…") { model.pickAndImport() }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(model.isSheetPresented)
            }
            // Own the Edit menu's undo/redo so ⌘Z drives the project history
            // (the default responder-chain items would swallow the shortcut).
            // While a time/frame field has focus the items disable themselves,
            // letting the field's own text editing keep the keystroke.
            CommandGroup(replacing: .undoRedo) {
                Button("還原") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(model.isTextEditing || !model.canUndo)
                Button("重做") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(model.isTextEditing || !model.canRedo)
            }
            // The stock "全部選取" only reaches the first responder, and the
            // timeline isn't one — so ⌘A dies there. Own a second select-all
            // right after it: AppKit skips the stock item while it is disabled
            // and lands on this one, yet a focused text field still keeps ⌘A
            // for its own text (this item disables itself while typing).
            CommandGroup(after: .pasteboard) {
                Button("全選") { model.selectAllInFocusedPane() }
                    .keyboardShortcut("a", modifiers: .command)
                    .disabled(model.isTextEditing)
            }
            // Every edit with its key, where the menu bar shows it. A key with
            // no ⌘ or ⌃ reaches the window first, whose hidden buttons take it
            // (or the field being typed in does), so for those the menu is the
            // list and the fallback; ⌃= ⌃− ⌃⇧S reach the menu first. Either way
            // a press lands on the same model call. An item greys out wherever
            // its key has nothing to act on: while a field takes typing, under
            // a sheet (the menu bar stays live there), and for the timeline's
            // edits while reframing.
            //
            // ↑ ↓ are left off. The arrows reach the menu first, and an item
            // still takes its key while greyed out, so listed here they would
            // stop nudging the crop, moving the caret in a field and browsing
            // the Open panel.
            CommandMenu("剪輯") {
                let blocked = model.isTextEditing || model.isSheetPresented
                let timelineBlocked = blocked || model.isGeometryEditing
                Button("分割") { onTimeline { model.splitAtPlayhead() } }
                    .keyboardShortcut("s", modifiers: [])
                    .disabled(timelineBlocked || !model.canSplitAtPlayhead)
                Button("刪除左側") { onTimeline { model.deleteBeforePlayhead() } }
                    .keyboardShortcut("q", modifiers: [])
                    .disabled(timelineBlocked || !model.canDeleteBeforePlayhead)
                Button("刪除右側") { onTimeline { model.deleteAfterPlayhead() } }
                    .keyboardShortcut("w", modifiers: [])
                    .disabled(timelineBlocked || !model.canDeleteAfterPlayhead)
                Button("刪除") { onTimeline { model.deleteSelection() } }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(timelineBlocked || !model.canDeleteSelection)
                Divider()
                // These two stay live while reframing: C closes the workspace,
                // R turns the clip in it.
                Button(model.isGeometryEditing ? "完成裁切" : "裁切…") {
                    unlessBusy { model.toggleGeometryEditing() }
                }
                .keyboardShortcut("c", modifiers: [])
                .disabled(blocked || (model.activeItem == nil && !model.isGeometryEditing))
                Button("向右旋轉 90°") { unlessBusy { model.rotate(by: 1) } }
                    .keyboardShortcut("r", modifiers: [])
                    .disabled(blocked || model.rotationTargets.isEmpty)
                Button("向左旋轉 90°") { unlessBusy { model.rotate(by: -1) } }
                    .keyboardShortcut("r", modifiers: .shift)
                    .disabled(blocked || model.rotationTargets.isEmpty)
                Divider()
                Button(model.soundTargetsAreQuiet ? "取消靜音" : "靜音") {
                    onTimeline { model.toggleMuteForSoundTargets() }
                }
                .keyboardShortcut("m", modifiers: [])
                .disabled(timelineBlocked || !model.canShapeSoundTargets)
                Button("音量 +5%") { onTimeline { model.nudgeGainForSoundTargets(by: 0.05) } }
                    .keyboardShortcut("=", modifiers: .control)
                    .disabled(timelineBlocked || !model.canShapeSoundTargets)
                Button("音量 −5%") { onTimeline { model.nudgeGainForSoundTargets(by: -0.05) } }
                    .keyboardShortcut("-", modifiers: .control)
                    .disabled(timelineBlocked || !model.canShapeSoundTargets)
                Button("分離原音") { onTimeline { model.detachSoundTarget() } }
                    .keyboardShortcut("s", modifiers: [.control, .shift])
                    .disabled(timelineBlocked || !model.canDetachSoundTarget)
                Divider()
                Button("符合視窗") { onTimeline { model.requestTimelineAutoFit() } }
                    .keyboardShortcut("z", modifiers: .shift)
                    .disabled(timelineBlocked || !model.hasProject)
            }
        }
    }

    /// An item is only as current as the last time SwiftUI updated its menu,
    /// and a key can reach it before the next update; so each action checks
    /// again as it runs. Nothing happens while a field takes typing, or while
    /// a sheet or a panel such as Open stands over the editor.
    private func unlessBusy(_ action: () -> Void) {
        guard !model.isTextEditing, !model.isSheetPresented, NSApp.modalWindow == nil else { return }
        action()
    }

    /// The same, and timeline edits also stand aside while the preview is a
    /// reframing surface, as they do on the window's keys.
    private func onTimeline(_ action: () -> Void) {
        unlessBusy { if !model.isGeometryEditing { action() } }
    }
}
