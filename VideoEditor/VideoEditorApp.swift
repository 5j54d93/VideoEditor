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
        }
    }
}
