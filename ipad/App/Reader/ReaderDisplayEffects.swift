import Combine
import Foundation
import SwiftUI

#if os(iOS)
import OSLog
import UIKit
#endif

@MainActor
final class ReaderDisplayEffects: ObservableObject {
    @Published private(set) var brightness: Double = 0.5
    @Published private(set) var isBrightnessAvailable = false

    #if os(iOS)
    private let ownerID = UUID()
    private static let logger = Logger(subsystem: "io.legado.ipad", category: "ReaderDisplay")

    private weak var window: UIWindow?
    private weak var orientedWindow: UIWindow?
    private var probeID: UUID?
    private var isStarted = false
    private var isActive = false
    private var orientation: ReaderOrientation = .system
    private var timeout: ReaderScreenTimeout = .system
    private var preferredBrightness: Double?
    private var brightnessObservation: AnyCancellable?
    private var deadline: ContinuousClock.Instant?
    private var timeoutTask: Task<Void, Never>?

    deinit {
        timeoutTask?.cancel()
        let id = ownerID
        Task { @MainActor in
            IdleTimerOwners.remove(id)
            BrightnessOwners.remove(id)
        }
    }

    private var activeWindow: UIWindow? {
        guard isStarted, isActive, let window, window.windowScene?.activationState == .foregroundActive else {
            return nil
        }
        return window
    }
    #endif

    func start(orientation: ReaderOrientation, timeout: ReaderScreenTimeout, isActive: Bool) {
        #if os(iOS)
        self.orientation = orientation
        self.timeout = timeout
        self.isActive = isActive
        isStarted = true
        activateWindow()
        #endif
    }

    func setOrientation(_ orientation: ReaderOrientation) {
        #if os(iOS)
        self.orientation = orientation
        applyOrientation()
        #endif
    }

    func setTimeout(_ timeout: ReaderScreenTimeout) {
        #if os(iOS)
        self.timeout = timeout
        deadline = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        noteActivity()
        #endif
    }

    func setActive(_ isActive: Bool) {
        #if os(iOS)
        self.isActive = isActive
        activateWindow()
        #endif
    }

    func setBrightness(_ value: Double) {
        #if os(iOS)
        guard value.isFinite, let screen = activeWindow?.windowScene?.screen else { return }
        let level = min(max(value, 0), 1)
        preferredBrightness = level
        brightness = BrightnessOwners.set(level, on: screen, for: ownerID)
        noteActivity()
        #endif
    }

    func noteActivity() {
        #if os(iOS)
        guard activeWindow != nil, timeout != .system else {
            releaseIdleTimer()
            return
        }
        IdleTimerOwners.add(ownerID)
        guard let seconds = timeout.seconds else { return }

        let clock = ContinuousClock()
        deadline = clock.now.advanced(by: .seconds(seconds))
        guard timeoutTask == nil else { return }
        timeoutTask = Task { @MainActor [weak self] in
            while let target = self?.deadline {
                do { try await clock.sleep(until: target) } catch { return }
                guard let self else { return }
                if deadline == target {
                    releaseIdleTimer()
                    return
                }
            }
        }
        #endif
    }

    func stop() {
        #if os(iOS)
        isStarted = false
        preferredBrightness = nil
        activateWindow()
        restoreSystemOrientation()
        #endif
    }

    #if os(iOS)
    fileprivate func attach(to newWindow: UIWindow?, from probeID: UUID) {
        if newWindow == nil, self.probeID != probeID { return }
        self.probeID = newWindow == nil ? nil : probeID
        guard window !== newWindow else { return }
        restoreSystemOrientation()
        releaseIdleTimer()
        BrightnessOwners.remove(ownerID)
        window = newWindow
        activateWindow()
    }

    private func activateWindow() {
        brightnessObservation = nil
        guard let screen = activeWindow?.windowScene?.screen else {
            isBrightnessAvailable = false
            BrightnessOwners.remove(ownerID)
            releaseIdleTimer()
            return
        }
        isBrightnessAvailable = true
        if let preferredBrightness {
            brightness = BrightnessOwners.set(preferredBrightness, on: screen, for: ownerID)
        } else {
            brightness = Double(screen.brightness)
        }
        brightnessObservation = NotificationCenter.default.publisher(
            for: UIScreen.brightnessDidChangeNotification, object: screen
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let screen = activeWindow?.windowScene?.screen else { return }
                brightness = Double(screen.brightness)
            }
        }
        applyOrientation()
        noteActivity()
    }

    private func releaseIdleTimer() {
        deadline = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        IdleTimerOwners.remove(ownerID)
    }

    private func applyOrientation() {
        guard let window = activeWindow else { return }
        switch orientation {
        case .system:
            restoreSystemOrientation()
        case .portrait:
            orientedWindow = window
            request(.portrait, in: window)
        case .landscape:
            orientedWindow = window
            request(.landscape, in: window)
        }
    }

    private func restoreSystemOrientation() {
        guard let window = orientedWindow else { return }
        orientedWindow = nil
        let supported = UIApplication.shared.supportedInterfaceOrientations(for: window)
        request(supported, in: window)
    }

    private func request(_ orientations: UIInterfaceOrientationMask, in window: UIWindow) {
        guard let scene = window.windowScene, !orientations.isEmpty else { return }
        var controller = window.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            Self.logger.debug("Reading orientation request declined: \(error.localizedDescription, privacy: .private)")
        }
    }
    #endif
}

#if os(iOS)
@MainActor
struct ReaderWindowProbe: UIViewRepresentable {
    let effects: ReaderDisplayEffects

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(effects: effects)
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.update(effects)
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: ()) {
        view.detach()
    }

    final class ProbeView: UIView {
        private let probeID = UUID()
        private weak var effects: ReaderDisplayEffects?

        init(effects: ReaderDisplayEffects) {
            self.effects = effects
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            notifyWindowChange()
        }

        func update(_ effects: ReaderDisplayEffects) {
            guard self.effects !== effects else { return }
            detach()
            self.effects = effects
            notifyWindowChange()
        }

        func detach() {
            let id = probeID
            let previous = effects
            effects = nil
            Task { @MainActor [weak previous] in
                previous?.attach(to: nil, from: id)
            }
        }

        private func notifyWindowChange() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                effects?.attach(to: window, from: probeID)
            }
        }
    }
}

@MainActor
private enum IdleTimerOwners {
    private static var owners: Set<UUID> = []
    private static var originalSetting: Bool?

    static func add(_ id: UUID) {
        if owners.isEmpty {
            originalSetting = UIApplication.shared.isIdleTimerDisabled
        }
        if owners.insert(id).inserted {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    static func remove(_ id: UUID) {
        guard owners.remove(id) != nil, owners.isEmpty, let originalSetting else { return }
        UIApplication.shared.isIdleTimerDisabled = originalSetting
        self.originalSetting = nil
    }
}

@MainActor
private enum BrightnessOwners {
    private struct Setting {
        weak var screen: UIScreen?
        var originalValue: CGFloat
        var appliedValue: CGFloat?
        var requests: [(owner: UUID, value: CGFloat)] = []
    }

    private static var settings: [ObjectIdentifier: Setting] = [:]

    static func set(_ value: Double, on screen: UIScreen, for owner: UUID) -> Double {
        let key = ObjectIdentifier(screen)
        var setting = settings[key] ?? Setting(screen: screen, originalValue: screen.brightness)
        if setting.appliedValue != screen.brightness {
            setting.originalValue = screen.brightness
        }
        setting.requests.removeAll { $0.owner == owner }
        setting.requests.append((owner, CGFloat(value)))
        screen.brightness = CGFloat(value)
        setting.appliedValue = screen.brightness
        settings[key] = setting
        return Double(screen.brightness)
    }

    static func remove(_ owner: UUID) {
        for key in Array(settings.keys) {
            guard var setting = settings[key] else { continue }
            guard let screen = setting.screen else {
                settings.removeValue(forKey: key)
                continue
            }
            guard setting.requests.contains(where: { $0.owner == owner }) else { continue }
            let removedActiveRequest = setting.requests.last?.owner == owner
            setting.requests.removeAll { $0.owner == owner }
            if removedActiveRequest, setting.appliedValue == screen.brightness {
                screen.brightness = setting.requests.last?.value ?? setting.originalValue
                setting.appliedValue = screen.brightness
            }
            if setting.requests.isEmpty {
                settings.removeValue(forKey: key)
            } else {
                settings[key] = setting
            }
        }
    }
}
#else
struct ReaderWindowProbe: View {
    let effects: ReaderDisplayEffects

    var body: some View { EmptyView() }
}
#endif
