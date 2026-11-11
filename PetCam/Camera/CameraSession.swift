import AVKit
import Network
import Observation
import SwiftUI

enum ConnectionState: Equatable {
    case idle
    case connecting
    case searching
    case live
    case offline(String)
    case wrongPassword
    case locked
}

struct CameraFeatures: Equatable {
    var nightVision: NightVisionMode?
    var tracking: Bool?
    var privacy: Bool?
    var flip: Bool?
    var mirror: Bool?
}

struct DeviceInfo: Equatable {
    var model = ""
    var firmware = ""
    var serial = ""
}

/// The app's single source of truth: connection, live stream, controls and camera settings.
@MainActor
@Observable
final class CameraSession {
    // MARK: Observed state

    private(set) var settings = CameraSettings.load()
    private(set) var state: ConnectionState = .idle
    private(set) var hasVideo = false
    private(set) var videoAspect: CGFloat = 16 / 9
    private(set) var features = CameraFeatures()
    private(set) var device = DeviceInfo()
    private(set) var isCellular = false
    private(set) var activeStream: StreamType = .main

    var soundOn = true {
        didSet { audio.setMuted(!soundOn) }
    }
    private(set) var isTalking = false
    private(set) var talkLocked = false
    private(set) var recordingSince: Date?
    private(set) var isPiPActive = false
    private(set) var toast: String?

    // MARK: Plumbing

    let videoView = VideoLayerView()
    private let audio = AudioController()
    @ObservationIgnored private var control: DVRIPClient?
    @ObservationIgnored private var media: DVRIPClient?
    @ObservationIgnored private var talkClient: DVRIPClient?
    @ObservationIgnored private var pipeline: LivePipeline?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isForeground = true
    private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var pipController: AVPictureInPictureController?
    @ObservationIgnored private var pipDelegate: PiPDelegate?

    @ObservationIgnored private var cameraParam: [String: Any]?
    @ObservationIgnored private var trackConfig: [String: Any]?
    @ObservationIgnored private var maskConfig: [String: Any]?

    @ObservationIgnored private var ptzDesired: PTZDirection?
    @ObservationIgnored private var ptzCurrent: PTZDirection?
    @ObservationIgnored private var ptzWorker: Task<Void, Never>?

    init() {
        soundOn = settings.soundOnLaunch
        audio.setMuted(!soundOn)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(expensive: expensive, online: online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "petcam.path"))
        setUpPictureInPicture()
    }

    // MARK: Connection

    func connect() {
        guard settings.isConfigured else { return }
        retryTask?.cancel()
        connectTask?.cancel()
        connectTask = Task { await runConnect(allowSearch: true) }
    }

    func disconnect() {
        connectTask?.cancel()
        retryTask?.cancel()
        teardown()
        state = .idle
    }

    private func runConnect(allowSearch: Bool) async {
        teardown()
        generation += 1
        let gen = generation
        state = .connecting
        let password = Keychain.password

        let client: DVRIPClient
        do {
            client = try await DVRIPClient.connect(
                host: settings.host,
                username: settings.username,
                password: password,
                onClose: { @Sendable [weak self] error in
                    Task { @MainActor in self?.connectionDropped(generation: gen, error: error) }
                }
            )
        } catch let error as DVRIPError where error == .wrongPassword {
            state = .wrongPassword
            return
        } catch let error as DVRIPError where error == .accountLocked {
            state = .locked
            return
        } catch {
            guard !Task.isCancelled, gen == generation else { return }
            if allowSearch, await relocateCamera(password: password) {
                await runConnect(allowSearch: false)
                return
            }
            state = .offline("Camera is offline. It may be unplugged, or Tailscale may be off on this iPhone.")
            scheduleRetry(after: 10)
            return
        }

        guard !Task.isCancelled, gen == generation else {
            client.close()
            return
        }
        control = client

        if let info = try? await client.systemInfo() {
            device = DeviceInfo(
                model: info["HardWare"] as? String ?? "",
                firmware: info["SoftWareVersion"] as? String ?? "",
                serial: info["SerialNo"] as? String ?? ""
            )
            if settings.serial.isEmpty, !device.serial.isEmpty {
                updateSettings { $0.serial = self.device.serial }
            }
        }

        do {
            try await startMedia(generation: gen, password: password)
        } catch {
            guard gen == generation else { return }
            teardown()
            state = .offline("Couldn't start the video: \(error.localizedDescription)")
            scheduleRetry(after: 5)
            return
        }

        state = .live
        await loadFeatures()
    }

    private func startMedia(generation gen: Int, password: String) async throws {
        audio.startListening()
        audio.setMuted(!soundOn)

        let pipeline = LivePipeline(videoView: videoView, audio: audio)
        pipeline.onVideoSize = { [weak self] size in
            guard let self, size.height > 0 else { return }
            self.videoAspect = size.width / size.height
            self.hasVideo = true
        }
        self.pipeline = pipeline

        let stream = desiredStream
        let client = try await DVRIPClient.connect(
            host: settings.host,
            username: settings.username,
            password: password,
            onMedia: { @Sendable [pipeline] data in pipeline.handle(data) },
            onClose: { @Sendable [weak self] error in
                Task { @MainActor in self?.connectionDropped(generation: gen, error: error) }
            }
        )
        guard gen == generation else {
            client.close()
            throw CancellationError()
        }
        media = client
        try await client.startMonitor(stream)
        activeStream = stream
    }

    private func restartMedia() {
        guard state == .live else { return }
        if recordingSince != nil { stopRecording() }
        let gen = generation
        media?.connection.onClose = nil
        media?.close()
        media = nil
        Task {
            do {
                try await startMedia(generation: gen, password: Keychain.password)
            } catch {
                connectionDropped(generation: gen, error: error)
            }
        }
    }

    private func connectionDropped(generation gen: Int, error: Error?) {
        guard gen == generation else { return }
        teardown()
        state = .offline("Lost the connection to the camera.")
        scheduleRetry(after: 3)
    }

    private func teardown() {
        if isTalking { endTalkInternal() }
        if recordingSince != nil { stopRecording() }
        ptzWorker?.cancel()
        ptzWorker = nil
        ptzDesired = nil
        ptzCurrent = nil

        for client in [control, media, talkClient].compactMap({ $0 }) {
            client.connection.onClose = nil
            client.close()
        }
        control = nil
        media = nil
        talkClient = nil
        pipeline = nil
        hasVideo = false
    }

    private func scheduleRetry(after seconds: Double) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isForeground || self.isPiPActive else { return }
            self.connect()
        }
    }

    /// The camera may have a new IP after being unplugged. Look for it by serial number.
    private func relocateCamera(password: String) async -> Bool {
        guard !settings.serial.isEmpty else { return false }
        state = .searching
        let found = await CameraDiscovery.locate(
            near: settings.host,
            serial: settings.serial,
            username: settings.username,
            password: password
        )
        guard let match = found.first, match.host != settings.host else { return false }
        updateSettings { $0.host = match.host }
        return true
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            if settings.isConfigured, state != .live, state != .connecting, state != .searching {
                connect()
            }
        case .background:
            isForeground = false
            if !isPiPActive {
                ptzStop()
                disconnect()
                audio.stop()
            }
        default:
            break
        }
    }

    private func networkChanged(expensive: Bool, online: Bool) {
        let changed = expensive != isCellular
        isCellular = expensive
        if changed, settings.quality == .auto, state == .live, desiredStream != activeStream {
            restartMedia()
        }
        if online, case .offline = state, isForeground {
            connect()
        }
    }

    private var desiredStream: StreamType {
        switch settings.quality {
        case .hd: .main
        case .sd: .sub
        case .auto: isCellular ? .sub : .main
        }
    }

    // MARK: Settings

    private func updateSettings(_ change: (inout CameraSettings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
        settings.save()
    }

    func setQuality(_ quality: StreamQuality) {
        updateSettings { $0.quality = quality }
        if desiredStream != activeStream { restartMedia() }
    }

    func setPTZSpeed(_ speed: Int) { updateSettings { $0.ptzSpeed = speed } }
    func setInvertPan(_ value: Bool) { updateSettings { $0.invertPan = value } }
    func setInvertTilt(_ value: Bool) { updateSettings { $0.invertTilt = value } }
    func setSoundOnLaunch(_ value: Bool) { updateSettings { $0.soundOnLaunch = value } }

    /// Saves connection details and reconnects.
    func saveConnection(host: String, username: String, password: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostChanged = trimmedHost != settings.host
        updateSettings {
            $0.host = trimmedHost
            $0.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            if hostChanged { $0.serial = "" }
        }
        Keychain.password = password
        connect()
    }

    func forgetCamera() {
        disconnect()
        Keychain.deletePassword()
        CameraSettings.clear()
        settings = CameraSettings()
        device = DeviceInfo()
        features = CameraFeatures()
    }

    // MARK: Camera options

    private func loadFeatures() async {
        guard let control else { return }
        var found = CameraFeatures()
        if let param = try? await control.getConfig("Camera.Param.[0]") {
            cameraParam = param
            if let value = param.int("DayNightColor") { found.nightVision = NightVisionMode(rawValue: value) ?? .auto }
            if let value = param.int("PictureFlip") { found.flip = value != 0 }
            if let value = param.int("PictureMirror") { found.mirror = value != 0 }
        }
        if let track = try? await control.getConfig("Detect.DetectTrack.[0]"), let enabled = track.bool("Enable") {
            trackConfig = track
            found.tracking = enabled
        }
        if let mask = try? await control.getConfig("General.OneKeyMaskVideo.[0]"), let enabled = mask.bool("Enable") {
            maskConfig = mask
            found.privacy = enabled
        }
        features = found
    }

    func setNightVision(_ mode: NightVisionMode) {
        guard var param = cameraParam else { return }
        HexInt.set(&param, "DayNightColor", mode.rawValue)
        features.nightVision = mode
        applyConfig("Camera.Param.[0]", param) { $0.cameraParam = param }
    }

    func setFlip(_ on: Bool) {
        guard var param = cameraParam else { return }
        HexInt.set(&param, "PictureFlip", on ? 1 : 0)
        features.flip = on
        applyConfig("Camera.Param.[0]", param) { $0.cameraParam = param }
    }

    func setMirror(_ on: Bool) {
        guard var param = cameraParam else { return }
        HexInt.set(&param, "PictureMirror", on ? 1 : 0)
        features.mirror = on
        applyConfig("Camera.Param.[0]", param) { $0.cameraParam = param }
    }

    func setTracking(_ on: Bool) {
        guard var config = trackConfig else { return }
        config["Enable"] = on
        features.tracking = on
        applyConfig("Detect.DetectTrack.[0]", config) { $0.trackConfig = config }
    }

    func setPrivacy(_ on: Bool) {
        guard var config = maskConfig else { return }
        config["Enable"] = on
        features.privacy = on
        applyConfig("General.OneKeyMaskVideo.[0]", config) { $0.maskConfig = config }
    }

    private func applyConfig(_ name: String, _ value: [String: Any], onSuccess: @escaping (CameraSession) -> Void) {
        guard let control else { return }
        Task {
            do {
                try await control.setConfig(name, value)
                onSuccess(self)
            } catch {
                showToast("Couldn't change that setting: \(error.localizedDescription)")
                await loadFeatures()
            }
        }
    }

    // MARK: Pan / tilt

    /// Call with a direction while the user is steering, and nil when they let go.
    func ptz(_ direction: PTZDirection?) {
        let adjusted = direction?.adjusted(invertPan: settings.invertPan, invertTilt: settings.invertTilt)
        ptzDesired = adjusted
        guard ptzWorker == nil else { return }
        ptzWorker = Task { await runPTZ() }
    }

    func ptzStop() { ptz(nil) }

    /// Sends start/stop commands one at a time, always catching up to the latest wish.
    private func runPTZ() async {
        defer { ptzWorker = nil }
        while !Task.isCancelled, let control, ptzDesired != ptzCurrent {
            let target = ptzDesired
            if let current = ptzCurrent {
                try? await control.ptz(current, moving: false, speed: settings.ptzSpeed)
                ptzCurrent = nil
                if target == nil {
                    // Repeat the stop once: a lost stop would leave the camera turning.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    try? await control.ptz(current, moving: false, speed: settings.ptzSpeed)
                }
            }
            if let target {
                try? await control.ptz(target, moving: true, speed: settings.ptzSpeed)
                ptzCurrent = target
            }
        }
    }

    // MARK: Talk

    func talkBegin() {
        guard !isTalking, state == .live else { return }
        isTalking = true
        talkLocked = false
        let gen = generation
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                isTalking = false
                showToast("Microphone access is off. Turn it on in Settings → PetCam.")
                return
            }
            do {
                let client = try await DVRIPClient.connect(
                    host: settings.host,
                    username: settings.username,
                    password: Keychain.password
                )
                guard isTalking, gen == generation else {
                    client.close()
                    return
                }
                try await client.startTalk()
                talkClient = client
                try audio.startTalking { @Sendable [weak client] chunk in
                    client?.sendTalkAudio(chunk)
                }
            } catch {
                endTalkInternal()
                showToast("Couldn't start talking: \(error.localizedDescription)")
            }
        }
    }

    func talkLock() {
        guard isTalking else { return }
        talkLocked = true
    }

    func talkEnd() {
        guard isTalking else { return }
        endTalkInternal()
    }

    private func endTalkInternal() {
        isTalking = false
        talkLocked = false
        audio.stopTalking()
        if let client = talkClient {
            client.stopTalk()
            client.close()
        }
        talkClient = nil
    }

    // MARK: Snapshot & recording

    func takeSnapshot() {
        guard let image = pipeline?.snapshot() else {
            showToast("No picture yet")
            return
        }
        Task {
            do {
                try await PhotoSaver.save(image: image)
                showToast("Snapshot saved to Photos")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func toggleRecording() {
        if recordingSince != nil {
            stopRecording()
        } else {
            guard let pipeline, state == .live else { return }
            _ = pipeline.startRecording()
            recordingSince = Date()
        }
    }

    private func stopRecording() {
        recordingSince = nil
        guard let recorder = pipeline?.stopRecording() else { return }
        Task {
            guard let url = await recorder.finish() else {
                showToast("The clip was too short to save")
                return
            }
            do {
                try await PhotoSaver.save(videoAt: url)
                showToast("Clip saved to Photos")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    // MARK: Picture in Picture

    private func setUpPictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let delegate = PiPDelegate()
        delegate.onActiveChange = { [weak self] active in self?.isPiPActive = active }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: videoView.displayLayer,
            playbackDelegate: delegate
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = delegate
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipDelegate = delegate
        pipController = controller
    }

    func startPictureInPicture() {
        pipController?.startPictureInPicture()
    }
}

/// Live-stream PiP: no timeline, never paused.
final class PiPDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    var onActiveChange: ((Bool) -> Void)?

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onActiveChange?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onActiveChange?(false)
    }
}
