import SwiftUI

struct SettingsView: View {
    @Environment(CameraSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false

    private var featuresUnknown: Bool { session.features == CameraFeatures() }

    var body: some View {
        NavigationStack {
            Form {
                videoSection
                movementSection
                if let privacy = session.features.privacy {
                    Section {
                        Toggle("Privacy Mode", isOn: Binding(get: { privacy }, set: { session.setPrivacy($0) }))
                    } footer: {
                        Text("Asks the camera to stop showing a picture. Unplugging it is the only way to be certain it isn't recording.")
                    }
                }
                Section("Sound") {
                    Toggle("Sound On When Opening", isOn: Binding(
                        get: { session.settings.soundOnLaunch },
                        set: { session.setSoundOnLaunch($0) }
                    ))
                }
                cameraSection
                Section {
                    Button("Forget This Camera", role: .destructive) { confirmForget = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Forget this camera?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget Camera", role: .destructive) {
                    session.forgetCamera()
                    dismiss()
                }
            } message: {
                Text("PetCam removes the camera's address and password from this iPhone. The camera itself isn't changed.")
            }
        }
    }

    private var videoSection: some View {
        Section {
            Picker("Quality", selection: Binding(
                get: { session.settings.quality },
                set: { session.setQuality($0) }
            )) {
                ForEach(StreamQuality.allCases) { quality in
                    VStack(alignment: .leading) {
                        Text(quality.label)
                        Text(quality.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(quality)
                }
            }
            .pickerStyle(.navigationLink)

            if let mode = session.features.nightVision {
                Picker("Night Vision", selection: Binding(get: { mode }, set: { session.setNightVision($0) })) {
                    ForEach(NightVisionMode.allCases) { Text($0.label).tag($0) }
                }
            }
            if let flip = session.features.flip {
                Toggle("Flip Upside Down", isOn: Binding(get: { flip }, set: { session.setFlip($0) }))
            }
            if let mirror = session.features.mirror {
                Toggle("Mirror Picture", isOn: Binding(get: { mirror }, set: { session.setMirror($0) }))
            }
        } header: {
            Text("Video")
        } footer: {
            if featuresUnknown {
                Text(session.state == .live
                     ? "This camera didn't report any adjustable picture settings."
                     : "Connect to the camera to see its night vision and picture settings.")
            }
        }
    }

    private var movementSection: some View {
        Section {
            VStack(alignment: .leading) {
                LabeledContent("Speed", value: "\(session.settings.ptzSpeed)")
                Slider(
                    value: Binding(
                        get: { Double(session.settings.ptzSpeed) },
                        set: { session.setPTZSpeed(Int($0.rounded())) }
                    ),
                    in: 1...8,
                    step: 1
                ) {
                    Text("Speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise.fill")
                } maximumValueLabel: {
                    Image(systemName: "hare.fill")
                }
            }
            Toggle("Reverse Left/Right", isOn: Binding(get: { session.settings.invertPan }, set: { session.setInvertPan($0) }))
            Toggle("Reverse Up/Down", isOn: Binding(get: { session.settings.invertTilt }, set: { session.setInvertTilt($0) }))
            if let tracking = session.features.tracking {
                Toggle("Auto-Tracking", isOn: Binding(get: { tracking }, set: { session.setTracking($0) }))
            }
        } header: {
            Text("Movement")
        } footer: {
            Text("Drag the joystick to turn the camera, or swipe on the picture to drag the view. Use Reverse if the camera turns the wrong way, for example when it's mounted upside down.")
        }
    }

    private var cameraSection: some View {
        Section {
            NavigationLink("Connection") {
                ConnectionForm(
                    host: session.settings.host,
                    username: session.settings.username,
                    password: Keychain.password,
                    buttonTitle: "Save and Reconnect"
                ) {
                    dismiss()
                }
                .navigationTitle("Connection")
            }
            LabeledContent("Address", value: session.settings.host)
            if !session.device.model.isEmpty { LabeledContent("Model", value: session.device.model) }
            if !session.device.firmware.isEmpty { LabeledContent("Firmware", value: session.device.firmware) }
            if !session.device.serial.isEmpty { LabeledContent("Serial Number", value: session.device.serial) }
        } header: {
            Text("Camera")
        } footer: {
            Text("Away from home, PetCam reaches the camera through Tailscale. Keep the Tailscale app connected on this iPhone.")
        }
    }
}

/// Address + login form, used on first launch and in Settings.
struct ConnectionForm: View {
    @Environment(CameraSession.self) private var session

    @State var host: String
    @State var username: String
    @State var password: String
    var buttonTitle = "Connect"
    var onSaved: () -> Void = {}

    @State private var scanning = false
    @State private var scanned = false
    @State private var found: [CameraDiscovery.Found] = []

    var body: some View {
        Form {
            Section {
                TextField("192.168.1.2", text: $host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Camera Address")
            }

            Section {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Device password", text: $password)
            } header: {
                Text("Camera Login")
            } footer: {
                Text("This is the camera's own device password, which you set in Tris Home under the device's settings. It isn't your Tris Home account password. PetCam keeps it only in this iPhone's Keychain.")
            }

            Section {
                Button {
                    Task { await scan() }
                } label: {
                    HStack {
                        Label("Find Camera on Network", systemImage: "dot.radiowaves.left.and.right")
                        Spacer()
                        if scanning { ProgressView() }
                    }
                }
                .disabled(scanning)

                ForEach(found) { camera in
                    Button {
                        host = camera.host
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(camera.host).foregroundStyle(.primary)
                                if !camera.model.isEmpty || !camera.serial.isEmpty {
                                    Text([camera.model, camera.serial].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if camera.host == host {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
                if scanned, found.isEmpty, !scanning {
                    Text("No camera found. Check that it's plugged in and that this iPhone is on the home Wi-Fi or connected to Tailscale.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Searches \(CameraDiscovery.prefix(of: host)).1 to .254 for a camera.")
            }

            Section {
                Button(buttonTitle) {
                    session.saveConnection(host: host, username: username, password: password)
                    onSaved()
                }
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || username.isEmpty)
            }
        }
    }

    private func scan() async {
        scanning = true
        found = []
        found = await CameraDiscovery.locate(near: host, serial: "", username: username, password: password)
        scanning = false
        scanned = true
        if found.count == 1, let only = found.first { host = only.host }
    }
}

struct OnboardingView: View {
    var body: some View {
        NavigationStack {
            ConnectionForm(host: "192.168.1.2", username: "admin", password: "")
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 10) {
                        Image(systemName: "pawprint.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                            .symbolRenderingMode(.hierarchical)
                        Text("Welcome to PetCam")
                            .font(.title.bold())
                        Text("Connect to your pet camera. At home it works over Wi-Fi; away from home it works through Tailscale.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGroupedBackground))
                }
        }
    }
}
