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

    /// The fades as drawn, never longer than the stretch that is heard.
    var fadeInWidth: CGFloat { min(heardWidth, CGFloat(fadeIn) * pointsPerSecond) }
    var fadeOutWidth: CGFloat { min(heardWidth, CGFloat(fadeOut) * pointsPerSecond) }

    /// The level `x` points in, where the sound is heard: the gain taken down
    /// by whichever fade `x` is inside — the straight lines `audioGain` gives,
    /// which are the ones the export draws.
    func level(at x: CGFloat) -> Double {
        audioGain(at: Double(x / pointsPerSecond),
                  duration: Double(heardWidth / pointsPerSecond),
                  gain: gain, fadeIn: fadeIn, fadeOut: fadeOut)
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

    private var cornerRadius: CGFloat { kind == .track ? 4 : 3 }
    private var sound: ClosedRange<CGFloat> { soundRange ?? 0...geometry.width }

    var body: some View {
        ZStack(alignment: .topLeading) {
            base
            waveform
            fadeShading
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

    /// The fades as shaded wedges over the ends: the sound under the wedge is
    /// the part being taken down. The fade-out leads into wherever the sound
    /// stops — the movie's end, when the bar outruns it.
    private var fadeShading: some View {
        Canvas { context, size in
            var wedges = Path()
            let fadeIn = geometry.fadeInWidth, fadeOut = geometry.fadeOutWidth
            let end = geometry.heardWidth
            if fadeIn > 0 {
                wedges.move(to: CGPoint(x: 0, y: size.height))
                wedges.addLine(to: CGPoint(x: 0, y: 0))
                wedges.addLine(to: CGPoint(x: fadeIn, y: 0))
                wedges.closeSubpath()
            }
            if fadeOut > 0 {
                wedges.move(to: CGPoint(x: end, y: size.height))
                wedges.addLine(to: CGPoint(x: end, y: 0))
                wedges.addLine(to: CGPoint(x: end - fadeOut, y: 0))
                wedges.closeSubpath()
            }
            context.fill(wedges, with: .color(.black.opacity(0.35)))
        }
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
