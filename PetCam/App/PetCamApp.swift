import SwiftUI

@main
struct PetCamApp: App {
    @State private var session = CameraSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}

struct RootView: View {
    @Environment(CameraSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.settings.isConfigured {
                CameraScreen()
            } else {
                OnboardingView()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            session.scenePhaseChanged(phase)
        }
    }
}
