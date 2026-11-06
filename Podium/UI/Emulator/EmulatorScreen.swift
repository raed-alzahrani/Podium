import SwiftUI
import UIKit

struct EmulatorScreen: View {
    @Environment(FirmwareLibrary.self) private var firmwareLibrary
    @Environment(EmulatorCore.self) private var emulatorCore

    private var firmware: ImportedFirmware? {
        firmwareLibrary.activeFirmware
    }

    /// The live display once iOS has reached its lock screen; until then
    /// the boot screen, with its progress bar.
    @ViewBuilder
    private var screen: some View {
        if emulatorCore.bootStage == .running, let source = emulatorCore.framebufferSource {
            ZStack {
                GuestFramebufferView(source: source) { event in
                    emulatorCore.sendInput(event)
                }
                DigitizerTouchSurface { message in
                    emulatorCore.log(message)
                } onTouch: { event in
                    emulatorCore.sendInput(event)
                }
            }
            .contentShape(Rectangle())
        } else {
            BootProgressView(stage: emulatorCore.bootStage, instructionsPerSecond: emulatorCore.instructionsPerSecond, kernelDetail: emulatorCore.jitStatus)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 12)

                GeometryReader { displayProxy in
                    let displayHeight = min(displayProxy.size.height, displayProxy.size.width * 1.5)
                    let displayWidth = displayHeight / 1.5

                    screen
                        .frame(width: displayWidth, height: displayHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: min(geometry.size.height * 0.68, 610))

                deviceDescription
                    .padding(.top, 18)

                Spacer(minLength: 20)

                EmulatorControlBar { event in
                    if case .powerButton(pressed: true) = event, !emulatorCore.isPoweredOn, emulatorCore.bootStage == nil, let firmware {
                        powerOn(firmware)
                    } else {
                        emulatorCore.sendInput(event)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }
                .padding(.bottom, max(geometry.safeAreaInsets.bottom == 0 ? 18 : 8, 8))
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .ignoresSafeArea(edges: .bottom)
        }
        .navigationBarTitleDisplayMode(.inline)
        .background(EmulatorPopGestureLock())
        .alert("JIT", isPresented: Binding(
            get: { emulatorCore.jitAlert != nil },
            set: { if !$0 { emulatorCore.jitAlert = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(emulatorCore.jitAlert ?? "")
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Podium").font(.headline)
                    Text(emulatorCore.status.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if emulatorCore.isPoweredOn || emulatorCore.storageFlushFailure != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        emulatorCore.powerOff()
                    } label: {
                        Label(emulatorCore.isPoweredOn ? "Power Off" : "Retry Power Off", systemImage: "power.circle")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deviceDescription: some View {
        VStack(spacing: 7) {
            Text(firmware.map { "\($0.displayName) · iOS \($0.metadata.productVersion)" } ?? "No firmware selected")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if case .error(let message) = emulatorCore.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if !emulatorCore.isPoweredOn, emulatorCore.bootStage == nil,
               !emulatorCore.isBusy, let firmware, firmware.compatibility.isCompatible {
                Button {
                    powerOn(firmware)
                } label: {
                    Label("Power On", systemImage: "power")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
            }
            if emulatorCore.hasStorageFlushFailure {
                Button("Retry Storage Flush", systemImage: "arrow.clockwise") {
                    emulatorCore.retryStorageFlush()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
    }

    private func powerOn(_ firmware: ImportedFirmware) {
        Task {
            await emulatorCore.powerOn(firmware: firmware, storedAt: firmwareLibrary.fileURL(for: firmware))
        }
    }

}

/// Owns the emulator screen for UIKit. SwiftUI's `NavigationStack` keeps
/// `interactivePopGestureRecognizer` enabled, and a hidden background view
/// never saw that controller, so an edge swipe popped the screen and
/// cancelled the digitizer's touches. This controller is in the hosting
/// hierarchy, so `viewWillAppear` / `viewDidAppear` can reach the real
/// navigation controller, and `viewWillDisappear` puts the gesture back.
private struct EmulatorPopGestureLock: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.relock()
    }

    final class Controller: UIViewController {
        private var holding = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            holding = true
            relock()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            holding = true
            relock()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            relock()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            holding = false
            NavigationPopGestureBlocker.shared.restore(from: self)
        }

        /// SwiftUI turns the recognizer back on after appear. Layout runs
        /// again on those updates, so the recognizer cannot stay armed.
        func relock() {
            guard holding else { return }
            NavigationPopGestureBlocker.shared.lock(from: self)
        }
    }
}

/// Refuses the navigation pop gesture while the emulator screen is up.
/// One instance, because the recognizer's delegate is a single object.
final class NavigationPopGestureBlocker: NSObject, UIGestureRecognizerDelegate {
    static let shared = NavigationPopGestureBlocker()

    private struct Saved {
        weak var recognizer: UIGestureRecognizer?
        weak var delegate: UIGestureRecognizerDelegate?
    }
    private var saved: [ObjectIdentifier: Saved] = [:]

    func lock(from controller: UIViewController) {
        guard let navigation = Self.navigationController(from: controller) else { return }
        lock(navigation)
    }

    func lock(from view: UIView) {
        guard let navigation = Self.navigationController(from: view) else { return }
        lock(navigation)
    }

    func restore(from controller: UIViewController) {
        guard let navigation = Self.navigationController(from: controller) else { return }
        for recognizer in popRecognizers(on: navigation) {
            let key = ObjectIdentifier(recognizer)
            guard let previous = saved.removeValue(forKey: key) else { continue }
            recognizer.isEnabled = true
            if recognizer.delegate === self {
                recognizer.delegate = previous.delegate
            }
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { false }

    private func lock(_ navigation: UINavigationController) {
        for recognizer in popRecognizers(on: navigation) {
            let key = ObjectIdentifier(recognizer)
            if saved[key] == nil {
                saved[key] = Saved(recognizer: recognizer, delegate: recognizer.delegate)
            }
            recognizer.delegate = self
            recognizer.isEnabled = false
        }
    }

    private func popRecognizers(on navigation: UINavigationController) -> [UIGestureRecognizer] {
        var recognizers: [UIGestureRecognizer] = []
        if let pop = navigation.interactivePopGestureRecognizer { recognizers.append(pop) }
        let contentPop = Selector(("interactiveContentPopGestureRecognizer"))
        if navigation.responds(to: contentPop), let extra = navigation.value(forKey: "interactiveContentPopGestureRecognizer") as? UIGestureRecognizer {
            recognizers.append(extra)
        }
        return recognizers
    }

    private static func navigationController(from controller: UIViewController) -> UINavigationController? {
        var current: UIViewController? = controller
        while let next = current {
            if let navigation = next as? UINavigationController { return navigation }
            if let navigation = next.navigationController { return navigation }
            current = next.parent
        }
        return navigationController(from: controller.view)
    }

    private static func navigationController(from view: UIView) -> UINavigationController? {
        var responder: UIResponder? = view
        while let next = responder {
            if let navigation = next as? UINavigationController { return navigation }
            if let host = next as? UIViewController, let navigation = host.navigationController { return navigation }
            responder = next.next
        }
        return nil
    }
}

#Preview {
    NavigationStack {
        EmulatorScreen()
    }
    .environment(FirmwareLibrary())
    .environment(EmulatorCore())
}
