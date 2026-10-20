//
//  SoundBar.swift
//  VideoEditor
//
//  One bar for every piece of sound the timeline draws: a clip's own audio
//  under its picture, and each piece of the audio track. They used to be two
//  drawings of the same kind of thing — a waveform on the track, a coloured
//  span with a label under the picture — although both carry a level and a
//  pair of fades and both are heard the same way. Now both are this bar, so
//  what is true of one is visibly true of the other.
//

import AppKit
import SwiftUI

/// Where the parts of a sound bar sit, in points from its top-left corner.
/// Kept out of the view so it can be asserted without a window, the way the
/// track's lanes are.
struct SoundBarGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    /// Where the sound stops being heard: the bar's own end, or the movie's
    /// when the sound outruns the picture.
    var heardWidth: CGFloat
    var pointsPerSecond: CGFloat
    var gain: Double
    var fadeIn: Double
    var fadeOut: Double

    /// The bar's controls, in the order they win where they overlap.
    enum Zone: Hashable {
        /// The handles along the top, one at the end of each fade.
        case fadeIn, fadeOut
        /// The speaker at the bottom-left.
        case mute
        /// The ends, on a bar whose ends are its own to trim.
        case trimStart, trimEnd
        /// The level line.
        case level
        case body
    }

    /// How far the level line stays from the top and the bottom, where twice
    /// the recording and silence sit.
    static let inset: CGFloat = 4
    /// The strip along the top the fade handles live in, and how far to
    /// either side of one a pointer still takes it.
    static let handleStrip: CGFloat = 12
    static let handleReach: CGFloat = 7
    /// How far above or below the line a pointer still takes it.
    static let lineReach: CGFloat = 4
    /// How far in from either end a drag trims rather than moves.
    static let grip: CGFloat = 8
    /// How long unity holds the line as a drag goes past it.
    static let detent: CGFloat = 3
    /// Screen distance within which a handle is pulled onto a cut or the
    /// playhead — the same pull a trimmed end gets.
    static let snapReach: CGFloat = 6

    /// The fades as drawn, never longer than the stretch that is heard.
    var fadeInWidth: CGFloat { min(heardWidth, CGFloat(fadeIn) * pointsPerSecond) }
    var fadeOutWidth: CGFloat { min(heardWidth, CGFloat(fadeOut) * pointsPerSecond) }

    /// The level `x` points in, where the sound is heard: the gain taken down
    /// by whichever fade `x` is inside, each fade cut to the stretch that is
    /// heard — the straight lines the export draws with `afade`.
    func level(at x: CGFloat) -> Double {
        let heard = Double(heardWidth / pointsPerSecond)
        return audioGain(at: Double(x / pointsPerSecond), duration: heard, gain: gain,
                         fadeIn: min(fadeIn, heard), fadeOut: min(fadeOut, heard))
    }

    /// Where the line sits for a gain: silence at the bottom, the recording as
    /// it is halfway up, twice it at the top.
    func levelY(_ gain: Double) -> CGFloat {
        Self.inset + CGFloat(1 - gain / EditorModel.maximumAudioGain) * (height - 2 * Self.inset)
    }

    /// The line `x` points in: up out of silence across the fade-in, level,
    /// and down into silence across the fade-out.
    func envelopeY(at x: CGFloat) -> CGFloat {
        let silent = levelY(0)
        guard gain > 0 else { return silent }
        return silent + (levelY(gain) - silent) * CGFloat(level(at: x) / gain)
    }

    /// The line's corners, left to right: where each fade meets the level, or
    /// where the two cross when they overlap.
    var envelopeCorners: [CGPoint] {
        guard heardWidth > 0 else { return [] }
        var xs = [0, fadeInWidth, heardWidth - fadeOutWidth, heardWidth]
        if fadeInWidth > 0, fadeOutWidth > 0, fadeInWidth + fadeOutWidth > heardWidth {
            xs.append(heardWidth * fadeInWidth / (fadeInWidth + fadeOutWidth))
        }
        return xs.map { min(max(0, $0), heardWidth) }.sorted()
            .map { CGPoint(x: $0, y: envelopeY(at: $0)) }
    }

    /// Where a fade's handle sits along the top: at the end of its fade, or in
    /// its corner when there is none.
    func handleX(_ zone: Zone) -> CGFloat {
        let low = min(4, heardWidth / 2), high = max(low, heardWidth - 4)
        let x = zone == .fadeIn ? fadeInWidth : heardWidth - fadeOutWidth
        return min(max(x, low), high)
    }

    /// The speaker's target, at the bottom-left where the label begins.
    var muteRect: CGRect { CGRect(x: 6, y: height - 17, width: 16, height: 16) }

    /// The control under `point`. A muted sound keeps its fades but not its
    /// line, which has nothing to set while nothing is heard; `trims` is
    /// whether the ends are the bar's to trim, which a clip's own sound,
    /// tied to its picture, does not have.
    func zone(at point: CGPoint, isMuted: Bool, trims: Bool) -> Zone {
        if heardWidth > 10, point.y <= Self.handleStrip {
            let toIn = abs(point.x - handleX(.fadeIn)), toOut = abs(point.x - handleX(.fadeOut))
            if min(toIn, toOut) <= Self.handleReach { return toIn <= toOut ? .fadeIn : .fadeOut }
        }
        if muteRect.contains(point) { return .mute }
        if trims, point.x < Self.grip { return .trimStart }
        if trims, point.x > width - Self.grip { return .trimEnd }
        if !isMuted, point.x <= heardWidth,
           abs(point.y - envelopeY(at: max(0, point.x))) <= Self.lineReach {
            return .level
        }
        return .body
    }

    /// The gain a drag on the line leaves, `rise` points above where it began
    /// at `start`. The line keeps to the pointer, and unity holds it for a few
    /// points on the way past; `fine` moves it a percent a point instead and
    /// holds nowhere. Whole percents, which is what the label reads.
    func gain(from start: Double, rise: CGFloat, fine: Bool) -> Double {
        let maximum = EditorModel.maximumAudioGain
        let travel = Double(height - 2 * Self.inset)
        var value = start + Double(rise) * (fine ? 0.01 : maximum / travel)
        if !fine, abs(value - 1) * travel / maximum <= Double(Self.detent) { value = 1 }
        return min(max(0, (value * 100).rounded() / 100), maximum)
    }

    /// The fade a handle dragged to `x` sets, in seconds: how far the handle
    /// is from its own end, pulled onto any of `snaps` within reach, and never
    /// across the other fade. Hundredths, which is what the readout shows.
    func fade(_ zone: Zone, handleAt x: CGFloat, snaps: [CGFloat]) -> Double {
        var target = x
        if let nearest = snaps.min(by: { abs($0 - x) < abs($1 - x) }),
           abs(nearest - x) <= Self.snapReach {
            target = nearest
        }
        let points = zone == .fadeIn
            ? min(max(0, target), heardWidth - fadeOutWidth)
            : min(max(0, heardWidth - target), heardWidth - fadeInWidth)
        return (Double(max(0, points) / pointsPerSecond) * 100).rounded() / 100
    }
}

extension SoundBarGeometry {
    /// A piece of the track, heard up to its own end or the movie's,
    /// whichever comes first.
    init(piece clip: AudioClip, width: CGFloat, height: CGFloat,
         pointsPerSecond: CGFloat, movieDuration: Double) {
        let heard = CGFloat(clip.heardDuration(movieDuration: movieDuration)) * pointsPerSecond
        self.init(width: width, height: height, heardWidth: min(width, max(0, heard)),
                  pointsPerSecond: pointsPerSecond, gain: clip.gain,
                  fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
    }
}

/// A piece of sound as the timeline draws it: its loudness at the level it
/// will be heard, its fades, and what it is called.
struct SoundBar: View {
    enum Kind {
        /// A piece of the audio track, a bar of its own.
        case track
        /// A clip's own sound, the lower part of the clip.
        case original
    }

    let kind: Kind
    let geometry: SoundBarGeometry
    let isMuted: Bool
    let label: String
    let peaks: AudioPeaks?
    /// The second of `peaks` at the bar's left edge.
    let peaksOffset: Double
    /// Where the recording has sound at all, in points: a clip whose audio
    /// starts late or ends early is silent at that end. `nil` is the whole bar.
    var soundRange: ClosedRange<CGFloat>? = nil
    /// The columns on screen. A song at a wide zoom is tens of thousands of
    /// columns, most of them scrolled away.
    let visibleRange: ClosedRange<CGFloat>
    var selected = false
    /// Whether the level is drawn as a line to drag.
    var showsLevel = true
    /// The fade handles, shown while the pointer is on the bar or the bar is
    /// selected — nothing on a bar no one is reaching for.
    var showsHandles = false
    /// The control under the pointer or in hand, drawn a little stronger.
    var hot: SoundBarGeometry.Zone? = nil

    private var cornerRadius: CGFloat { kind == .track ? 4 : 3 }
    private var sound: ClosedRange<CGFloat> { soundRange ?? 0...geometry.width }

    var body: some View {
        ZStack(alignment: .topLeading) {
            base
            waveform
            envelope
            if geometry.heardWidth < geometry.width {
                // Past the last frame nothing is heard: the sound stops where
                // the picture does, and the bar says so.
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: geometry.width - geometry.heardWidth)
                    .offset(x: geometry.heardWidth)
            }
            labelView
        }
        .frame(width: geometry.width, height: geometry.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            if kind == .track {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(selected ? Color.accentColor : Color.white.opacity(0.25),
                            lineWidth: selected ? 2 : 1)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsHandles, geometry.heardWidth > 10 { handles }
        }
    }

    @ViewBuilder
    private var base: some View {
        switch kind {
        case .track:
            Rectangle().fill(isMuted ? Color.gray.opacity(0.35) : Color.teal.opacity(0.5))
        case .original:
            // Muted draws like no sound at all: the bar shows what the clip
            // itself will be heard to say.
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black.opacity(0.58))
                if !isMuted, sound.upperBound > sound.lowerBound {
                    Rectangle()
                        .fill(Color.cyan.opacity(0.34))
                        .frame(width: sound.upperBound - sound.lowerBound)
                        .offset(x: sound.lowerBound)
                }
            }
        }
    }

    /// The loudness, one column per point, at the level it will be heard: the
    /// gain and the fades, up to the bar's full height at twice the
    /// recording. A column the gain pushes past full scale has its tips marked,
    /// since that is where the sound will clip.
    private var waveform: some View {
        Canvas { context, size in
            guard let peaks else { return }
            let first = max(sound.lowerBound, visibleRange.lowerBound).rounded(.down)
            let last = min(sound.upperBound, visibleRange.upperBound, size.width).rounded(.up)
            guard last > first else { return }
            let full = size.height - 6
            let middle = size.height / 2
            let perSecond = Double(geometry.pointsPerSecond)
            var bars = Path()
            var tips = Path()
            var x = first
            while x < last {
                let from = peaksOffset + Double(x) / perSecond
                let to = peaksOffset + Double(x + 1) / perSecond
                // Past where it is heard the sound is drawn as it stands, under
                // the dimming, so there is still something to trim against.
                let level = x < geometry.heardWidth ? geometry.level(at: x + 0.5) : geometry.gain
                let loudness = CGFloat(peaks.peak(from: from, to: to)) * CGFloat(level)
                let bar = max(1, min(1, loudness) * full)
                bars.addRect(CGRect(x: x, y: middle - bar / 2, width: 1, height: bar))
                if loudness > 1, !isMuted {
                    tips.addRect(CGRect(x: x, y: middle - full / 2, width: 1, height: 2))
                    tips.addRect(CGRect(x: x, y: middle + full / 2 - 2, width: 1, height: 2))
                }
                x += 1
            }
            context.fill(bars, with: .color(.white.opacity(isMuted ? 0.3 : 0.65)))
            context.fill(tips, with: .color(.orange))
        }
        .allowsHitTesting(false)
    }

    /// The level and the fades as one line, the way the sound will be heard:
    /// up out of silence, along the level, down into wherever the sound stops
    /// — the movie's end, when the bar outruns it. Above each fade a light
    /// shade marks the part being taken down. A muted line is dashed: its
    /// level is kept, but nothing is heard at it.
    private var envelope: some View {
        Canvas { context, _ in
            let corners = geometry.envelopeCorners
            guard let first = corners.first else { return }
            let fadeIn = geometry.fadeInWidth, fadeOut = geometry.fadeOutWidth
            let end = geometry.heardWidth
            var shade = Path()
            if fadeIn > 0 {
                shade.move(to: .zero)
                shade.addLine(to: CGPoint(x: fadeIn, y: 0))
                for corner in corners.filter({ $0.x <= fadeIn }).reversed() { shade.addLine(to: corner) }
                shade.closeSubpath()
            }
            if fadeOut > 0 {
                shade.move(to: CGPoint(x: end, y: 0))
                shade.addLine(to: CGPoint(x: end - fadeOut, y: 0))
                for corner in corners.filter({ $0.x >= end - fadeOut }) { shade.addLine(to: corner) }
                shade.closeSubpath()
            }
            context.fill(shade, with: .color(.black.opacity(0.3)))
            guard showsLevel else { return }
            var line = Path()
            line.move(to: first)
            for corner in corners.dropFirst() { line.addLine(to: corner) }
            let lit = hot == .level
            let dash: [CGFloat] = isMuted ? [3, 3] : []
            // A faint dark edge keeps the line legible over a light bar and
            // over the waveform it crosses.
            context.stroke(line, with: .color(.black.opacity(0.28)),
                           style: StrokeStyle(lineWidth: lit ? 3.6 : 2.8, lineJoin: .round, dash: dash))
            context.stroke(line, with: .color(.white.opacity(isMuted ? 0.45 : lit ? 1 : 0.9)),
                           style: StrokeStyle(lineWidth: lit ? 2 : 1.2, lineJoin: .round, dash: dash))
        }
        .allowsHitTesting(false)
    }

    /// One at the end of each fade, along the top; in its corner when the
    /// fade is not there yet.
    private var handles: some View {
        ZStack(alignment: .topLeading) {
            ForEach([SoundBarGeometry.Zone.fadeIn, .fadeOut], id: \.self) { zone in
                let lit = hot == zone
                let side: CGFloat = lit ? 9 : 7
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .overlay { RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.55)) }
                    .frame(width: side, height: side)
                    .offset(x: geometry.handleX(zone) - side / 2, y: lit ? 0.5 : 1.5)
            }
        }
        .frame(width: geometry.width, height: geometry.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Bottom-left: the speaker says whether the sound is on, then what the
    /// sound is, then its level when it is not the recording's own.
    private var labelView: some View {
        HStack(spacing: 4) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 8))
                .frame(width: 11)
            Text(label).lineLimit(1).truncationMode(.middle)
            if geometry.gain != 1 {
                Text("\(Int((geometry.gain * 100).rounded()))%")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.white.opacity(isMuted ? 0.6 : 0.9))
        // Readable where the line runs through it, and on a light bar.
        .shadow(color: .black.opacity(0.45), radius: 1, y: 0.5)
        .padding(.leading, 8)
        .padding(.bottom, 4)
        .frame(width: geometry.width, height: geometry.height, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }
}

/// What a drag on a sound bar is setting, beside the pointer while it is in
/// hand: the start a move lands on, the length a trim leaves, the level, the
/// fade. The row above the timeline used to carry these numbers; this carries
/// them only while they are changing.
struct SoundReadout: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

enum SoundBarCursor {
    /// The pointer over each control says what a drag there will do.
    static func cursor(for zone: SoundBarGeometry.Zone) -> NSCursor {
        switch zone {
        case .fadeIn, .fadeOut, .trimStart, .trimEnd: .resizeLeftRight
        case .level: .resizeUpDown
        case .mute: .pointingHand
        case .body: .openHand
        }
    }
}

extension SoundBarGeometry {
    /// A clip's own sound, heard across the clip's whole span, black included:
    /// the export shapes all of it.
    init(original item: ClipItem, width: CGFloat, height: CGFloat, pointsPerSecond: CGFloat) {
        self.init(width: width, height: height, heardWidth: width,
                  pointsPerSecond: pointsPerSecond, gain: item.audioGain,
                  fadeIn: item.audioFadeIn, fadeOut: item.audioFadeOut)
    }

    /// The parts of the bar a drag shapes rather than carries: both handles,
    /// and a band along the line while there is a level to set. On a clip's
    /// own sound everywhere else picks the clip up to reorder it, so this is
    /// the shape its controls take hits in.
    func controlsShape(isMuted: Bool) -> Path {
        var handles = Path()
        if heardWidth > 10 {
            for zone in [Zone.fadeIn, .fadeOut] {
                handles.addRect(CGRect(x: handleX(zone) - Self.handleReach, y: 0,
                                       width: 2 * Self.handleReach, height: Self.handleStrip))
            }
        }
        let corners = envelopeCorners
        guard !isMuted, !corners.isEmpty else { return handles }
        var band = Path()
        band.move(to: CGPoint(x: corners[0].x, y: corners[0].y - Self.lineReach))
        for corner in corners.dropFirst() {
            band.addLine(to: CGPoint(x: corner.x, y: corner.y - Self.lineReach))
        }
        for corner in corners.reversed() {
            band.addLine(to: CGPoint(x: corner.x, y: corner.y + Self.lineReach))
        }
        band.closeSubpath()
        return handles.union(band)
    }
}

/// What VoiceOver says a piece of sound is set to.
func soundAccessibilityValue(gain: Double, isMuted: Bool, fadeIn: Double, fadeOut: Double) -> String {
    var parts = [isMuted ? "已靜音" : "音量 \(Int((gain * 100).rounded()))%"]
    if fadeIn > 0 { parts.append(String(format: "淡入 %.1f 秒", fadeIn)) }
    if fadeOut > 0 { parts.append(String(format: "淡出 %.1f 秒", fadeOut)) }
    return parts.joined(separator: "，")
}

/// The exact numbers, for when a drag is not precise enough: the toolbar's
/// 聲音 panel for one piece of the track or one clip's own sound, which a bar's
/// 音量與淡入淡出… also opens. Every slider drag is one undo step, however many
/// values it sends.
struct SoundShapingPanel: View {
    enum Target: Equatable {
        case piece(AudioClip.ID)
        case original(ClipItem.ID)
    }

    let model: EditorModel
    let target: Target
    /// Nothing is selected, so this is the sound of the clip under the playhead.
    var isUnderPlayhead = false

    private struct Values {
        let title: String
        let gain: Double
        let isMuted: Bool
        let fadeIn: Double
        let fadeOut: Double
        /// How long the fades may run between them.
        let length: Double
    }

    private var values: Values? {
        switch target {
        case .piece(let id):
            guard let clip = model.audioClips.first(where: { $0.id == id }) else { return nil }
            return Values(title: clip.name, gain: clip.gain, isMuted: clip.isMuted,
                          fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, length: clip.duration)
        case .original(let id):
            guard let item = model.items.first(where: { $0.id == id }) else { return nil }
            return Values(title: item.url.lastPathComponent, gain: item.audioGain,
                          isMuted: item.isAudioMuted, fadeIn: item.audioFadeIn,
                          fadeOut: item.audioFadeOut, length: item.displayDuration)
        }
    }

    var body: some View {
        if let values {
            VStack(alignment: .leading, spacing: 10) {
                AdjustmentHeader(tool: .sound, subject: values.title, isUnderPlayhead: isUnderPlayhead) {
                    Button { setMuted(!values.isMuted) } label: {
                        Image(systemName: values.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 16)
                    }
                    .help(values.isMuted ? "取消靜音" : "靜音")
                }
                row("音量", value: values.gain, in: 0...EditorModel.maximumAudioGain,
                    readout: "\(Int((values.gain * 100).rounded()))%", key: gainKey,
                    set: setGain)
                    .disabled(values.isMuted)
                row("淡入", value: values.fadeIn, in: 0...max(0.1, values.length),
                    readout: String(format: "%.2f 秒", values.fadeIn), key: fadeKey) { fadeIn in
                    setFades(fadeIn, values.fadeOut)
                }
                row("淡出", value: values.fadeOut, in: 0...max(0.1, values.length),
                    readout: String(format: "%.2f 秒", values.fadeOut), key: fadeKey) { fadeOut in
                    setFades(values.fadeIn, fadeOut)
                }
            }
            .adjustmentPanelFrame()
        }
    }

    /// A value and its readout. The setter is `@MainActor`, which is what lets
    /// it pass into SwiftUI's `@Sendable` binding.
    private func row(_ title: String, value: Double, in range: ClosedRange<Double>,
                     readout: String, key: String,
                     set: @escaping @MainActor (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range,
                   onEditingChanged: { editing in
                       if editing { model.beginContinuousEdit(key) } else { model.endContinuousEdit(key) }
                   })
            Text(readout)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var gainKey: String {
        switch target {
        case .piece(let id): "audio-gain:\(id)"
        case .original(let id): "original-gain:\(id)"
        }
    }

    private var fadeKey: String {
        switch target {
        case .piece(let id): "audio-fade:\(id)"
        case .original(let id): "original-fade:\(id)"
        }
    }

    @MainActor private func setGain(_ gain: Double) {
        switch target {
        case .piece(let id): model.setAudioClipGain(gain, for: id)
        case .original(let id): model.setOriginalAudioGain(gain, for: id)
        }
    }

    @MainActor private func setFades(_ fadeIn: Double, _ fadeOut: Double) {
        switch target {
        case .piece(let id): model.setAudioClipFades(in: fadeIn, out: fadeOut, for: id)
        case .original(let id): model.setOriginalAudioFades(in: fadeIn, out: fadeOut, for: id)
        }
    }

    private func setMuted(_ muted: Bool) {
        switch target {
        case .piece(let id): model.setAudioClipMuted(muted, for: id)
        case .original(let id): model.setOriginalAudioMuted(muted, for: id)
        }
    }
}
