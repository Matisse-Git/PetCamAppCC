import SwiftUI

/// Round glass button with an SF Symbol.
struct GlassIconButton: View {
    let systemImage: String
    var size: CGFloat = 52
    var tint: Color?
    var accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint == nil ? Color.primary : Color.white)
        .glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: .circle)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Virtual joystick for pan & tilt. Reports a direction while held, nil on release.
struct PTZJoystick: View {
    var diameter: CGFloat = 176
    let onDirection: (PTZDirection?) -> Void

    @State private var knobOffset: CGSize = .zero
    @State private var direction: PTZDirection?

    var body: some View {
        let radius = diameter / 2
        let knobSize = diameter * 0.38

        ZStack {
            Circle()
                .fill(.clear)
                .frame(width: diameter, height: diameter)
                .glassEffect(.regular, in: .circle)

            ForEach(Self.arrows, id: \.direction.rawValue) { arrow in
                Image(systemName: arrow.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(direction == arrow.direction ? Color.accentColor : Color.secondary)
                    .offset(x: arrow.x * (radius - 20), y: arrow.y * (radius - 20))
            }

            Circle()
                .fill(.clear)
                .frame(width: knobSize, height: knobSize)
                .glassEffect(.regular.interactive(), in: .circle)
                .overlay {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: knobSize * 0.32))
                        .foregroundStyle(.secondary)
                }
                .offset(knobOffset)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var dx = value.location.x - radius
                    var dy = value.location.y - radius
                    let maxTravel = radius - knobSize / 2
                    let distance = hypot(dx, dy)
                    if distance > maxTravel {
                        dx *= maxTravel / distance
                        dy *= maxTravel / distance
                    }
                    knobOffset = CGSize(width: dx, height: dy)
                    let newDirection = PTZDirection.from(dx: dx, dy: dy, deadZone: radius * 0.25)
                    if newDirection != direction {
                        direction = newDirection
                        // This camera's pan commands are mirrored, so the horizontal axis is flipped
                        // to make "push right" turn the camera right (tested on the real camera).
                        onDirection(newDirection?.adjusted(invertPan: true, invertTilt: false))
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { knobOffset = .zero }
                    direction = nil
                    onDirection(nil)
                }
        )
        .sensoryFeedback(.selection, trigger: direction)
        .accessibilityElement()
        .accessibilityLabel("Pan and tilt")
        .accessibilityHint("Drag to turn the camera")
    }

    private struct Arrow {
        let direction: PTZDirection
        let symbol: String
        let x: CGFloat
        let y: CGFloat
    }

    private static let arrows: [Arrow] = [
        Arrow(direction: .up, symbol: "chevron.up", x: 0, y: -1),
        Arrow(direction: .down, symbol: "chevron.down", x: 0, y: 1),
        Arrow(direction: .left, symbol: "chevron.left", x: -1, y: 0),
        Arrow(direction: .right, symbol: "chevron.right", x: 1, y: 0),
    ]
}

/// Hold to talk; slide up while holding to lock it on; tap again to stop.
struct TalkButton: View {
    var size: CGFloat = 76
    let isTalking: Bool
    let isLocked: Bool
    let onBegin: () -> Void
    let onLock: () -> Void
    let onEnd: () -> Void

    private enum GestureMode { case hold, locked, stopTap }
    @State private var mode: GestureMode?

    var body: some View {
        ZStack {
            if mode == .hold {
                VStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                    Image(systemName: "chevron.up")
                }
                .font(.system(size: 13, weight: .bold))
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
                .glassEffect(.regular, in: .capsule)
                .offset(y: -size * 1.05)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Image(systemName: isLocked ? "lock.fill" : (isTalking ? "mic.fill" : "mic"))
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(isTalking ? Color.white : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: isTalking)
                .frame(width: size, height: size)
                .glassEffect(isTalking ? Glass.regular.tint(.red).interactive() : Glass.regular.interactive(), in: .circle)
                .scaleEffect(mode == .hold ? 1.08 : 1)
        }
        .animation(.spring(response: 0.25), value: mode)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if mode == nil {
                        if isLocked {
                            mode = .stopTap
                        } else {
                            mode = .hold
                            onBegin()
                        }
                    }
                    if mode == .hold, value.translation.height < -size * 0.9 {
                        mode = .locked
                        onLock()
                    }
                }
                .onEnded { _ in
                    switch mode {
                    case .hold, .stopTap: onEnd()
                    case .locked, nil: break
                    }
                    mode = nil
                }
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: isTalking)
        .sensoryFeedback(.success, trigger: isLocked) { _, new in new }
        .accessibilityLabel(isTalking ? "Stop talking" : "Hold to talk")
    }
}

/// Small capsule showing live status.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 24)
    }
}
