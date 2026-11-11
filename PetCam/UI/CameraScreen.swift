import SwiftUI
import UIKit

enum Orientation {
    @MainActor
    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

struct CameraScreen: View {
    @Environment(CameraSession.self) private var session
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var showSettings = false
    @State private var overlayVisible = true
    @State private var flash = false
    @State private var snapshotCount = 0

    private var isLandscape: Bool { verticalSizeClass == .compact }
    private var isLive: Bool { session.state == .live }

    var body: some View {
        Group {
            if isLandscape { landscape } else { portrait }
        }
        .overlay(alignment: .top) {
            if let message = session.toast {
                ToastView(message: message)
                    .padding(.top, isLandscape ? 12 : 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if flash {
                Color.white.ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.35), value: session.toast)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .statusBarHidden(isLandscape)
        .persistentSystemOverlays(isLandscape ? .hidden : .automatic)
        .sensoryFeedback(.impact(weight: .light), trigger: snapshotCount)
        .onChange(of: isLandscape) { overlayVisible = true }
    }

    // MARK: Portrait

    private var portrait: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)

            videoStage(showBadges: true)
                .aspectRatio(session.videoAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 12)

            PTZJoystick(diameter: 184) { session.ptz($0) }
                .disabled(!isLive)
                .opacity(isLive ? 1 : 0.45)

            Spacer(minLength: 12)

            controlBar(axis: .horizontal)
                .padding(.bottom, 10)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PetCam")
                    .font(.largeTitle.bold())
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    GlassIconButton(systemImage: "pip.enter", size: 44, accessibilityLabel: "Picture in Picture") {
                        session.startPictureInPicture()
                    }
                    .disabled(!session.hasVideo)
                    GlassIconButton(systemImage: "arrow.up.left.and.arrow.down.right", size: 44, accessibilityLabel: "Full screen") {
                        Orientation.request(.landscapeRight)
                    }
                    GlassIconButton(systemImage: "gearshape.fill", size: 44, accessibilityLabel: "Settings") {
                        showSettings = true
                    }
                }
            }
        }
    }

    private var statusLine: String {
        switch session.state {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .searching: "Looking for your camera…"
        case .live: "Live · \(session.activeStream == .main ? "HD" : "SD") · \(session.isCellular ? "Cellular" : "Wi-Fi")"
        case .offline: "Offline"
        case .wrongPassword: "Password needed"
        case .locked: "Account locked"
        }
    }

    // MARK: Landscape

    private var landscape: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoStage(showBadges: false)
                .ignoresSafeArea()
            if overlayVisible {
                landscapeOverlay
                    .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var landscapeOverlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                GlassIconButton(systemImage: "arrow.down.right.and.arrow.up.left", size: 44, accessibilityLabel: "Exit full screen") {
                    Orientation.request(.portrait)
                }
                Spacer()
                badges
                Spacer()
                GlassIconButton(systemImage: "gearshape.fill", size: 44, accessibilityLabel: "Settings") {
                    showSettings = true
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                controlBar(axis: .vertical)
                Spacer()
                PTZJoystick(diameter: 150) { session.ptz($0) }
                    .disabled(!isLive)
                    .opacity(isLive ? 1 : 0.45)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }

    // MARK: Video

    private func videoStage(showBadges: Bool) -> some View {
        ZStack {
            Color.black
            ZoomableVideoView(
                videoView: session.videoView,
                onSteer: { session.ptz($0) },
                onTap: {
                    guard isLandscape else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { overlayVisible.toggle() }
                }
            )
            .opacity(session.hasVideo ? 1 : 0)
            stateOverlay
        }
        .overlay(alignment: .topLeading) {
            if showBadges {
                badges.padding(10)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if isLive, session.hasVideo {
                StatusPill(text: "LIVE", color: .green)
            }
            if let since = session.recordingSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    StatusPill(text: Self.duration(context.date.timeIntervalSince(since)), color: .red)
                }
            }
            if session.isTalking {
                StatusPill(text: session.talkLocked ? "Talking (locked)" : "Talking", color: .orange)
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        Group {
            switch session.state {
            case .live:
                if !session.hasVideo { ProgressView().controlSize(.large) }
            case .idle, .connecting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Connecting to your camera…")
                }
            case .searching:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Looking for your camera on the network…")
                }
            case .offline(let message):
                VStack(spacing: 14) {
                    Image(systemName: "video.slash.fill").font(.system(size: 34))
                    Text(message).multilineTextAlignment(.center)
                    Button("Try Again") { session.connect() }
                        .buttonStyle(.glass)
                }
            case .wrongPassword:
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill").font(.system(size: 34))
                    Text("The camera didn't accept the password.")
                    Button("Update Password") { showSettings = true }
                        .buttonStyle(.glass)
                }
            case .locked:
                VStack(spacing: 14) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill").font(.system(size: 34))
                    Text(DVRIPError.accountLocked.errorDescription ?? "").multilineTextAlignment(.center)
                    Button("Try Again") { session.connect() }
                        .buttonStyle(.glass)
                }
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .tint(.white)
        .padding(24)
    }

    // MARK: Controls

    private func controlBar(axis: Axis) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 14))
            : AnyLayout(VStackLayout(spacing: 12))
        let size: CGFloat = axis == .horizontal ? 54 : 48
        let recording = session.recordingSince != nil

        return GlassEffectContainer(spacing: 14) {
            layout {
                GlassIconButton(
                    systemImage: session.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    size: size,
                    accessibilityLabel: session.soundOn ? "Mute camera sound" : "Play camera sound"
                ) {
                    session.soundOn.toggle()
                }

                GlassIconButton(systemImage: "camera.fill", size: size, accessibilityLabel: "Take snapshot") {
                    snapshot()
                }

                TalkButton(
                    size: axis == .horizontal ? 76 : 60,
                    isTalking: session.isTalking,
                    isLocked: session.talkLocked,
                    onBegin: { session.talkBegin() },
                    onLock: { session.talkLock() },
                    onEnd: { session.talkEnd() }
                )

                GlassIconButton(
                    systemImage: recording ? "stop.fill" : "record.circle",
                    size: size,
                    tint: recording ? .red : nil,
                    accessibilityLabel: recording ? "Stop recording" : "Record clip"
                ) {
                    session.toggleRecording()
                }

                qualityMenu(size: size)
            }
        }
        .disabled(!isLive)
        .opacity(isLive ? 1 : 0.5)
    }

    private func qualityMenu(size: CGFloat) -> some View {
        Menu {
            Picker("Quality", selection: Binding(
                get: { session.settings.quality },
                set: { session.setQuality($0) }
            )) {
                ForEach(StreamQuality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }
        } label: {
            VStack(spacing: 0) {
                Text(session.activeStream == .main ? "HD" : "SD")
                    .font(.system(size: size * 0.3, weight: .heavy))
                if session.settings.quality == .auto {
                    Text("AUTO")
                        .font(.system(size: size * 0.15, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Video quality")
    }

    private func snapshot() {
        snapshotCount += 1
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.easeOut(duration: 0.35)) { flash = false }
        }
        session.takeSnapshot()
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
