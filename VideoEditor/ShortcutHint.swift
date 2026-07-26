//
//  ShortcutHint.swift
//  VideoEditor
//
//  A quiet text-only shortcut hint placed to the right of a button's label,
//  so every visible action also teaches its keyboard shortcut.
//

import SwiftUI

struct KeyCapHint: View {
    let key: String
    /// On filled (borderedProminent) buttons the secondary gray would vanish
    /// into the accent color, so it switches to translucent white.
    var prominent: Bool = false
    /// The compact default suits toolbar-sized buttons; larger labels pass
    /// their own font so the hint matches the text it sits next to.
    var font: Font = .system(size: 9, weight: .medium, design: .rounded)

    init(_ key: String, prominent: Bool = false,
         font: Font = .system(size: 9, weight: .medium, design: .rounded)) {
        self.key = key
        self.prominent = prominent
        self.font = font
    }

    var body: some View {
        Text(key)
            .font(font)
            .foregroundStyle(prominent ? AnyShapeStyle(.white.opacity(0.85))
                                       : AnyShapeStyle(.secondary))
            .accessibilityHidden(true)   // the shortcut itself already announces
    }
}
