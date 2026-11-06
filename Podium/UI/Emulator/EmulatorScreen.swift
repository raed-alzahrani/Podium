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
            GuestFramebufferView(source: source) { event in
                emulatorCore.sendInput(event)
            }
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
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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

/// The slide-to-unlock drag starts at the left edge, which is also where
/// `interactivePopGestureRecognizer` claims the touch and pops this
/// screen. While the emulator is on screen the recognizer is disabled;
/// leaving the screen puts it back.
private struct EmulatorPopGestureLock: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { context.coordinator.lock(from: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.unlock(from: uiView)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var recognizer: UIGestureRecognizer?
        private weak var savedDelegate: UIGestureRecognizerDelegate?

        func lock(from view: UIView) {
            guard let recognizer = navigationController(from: view)?.interactivePopGestureRecognizer else { return }
            if self.recognizer !== recognizer {
                savedDelegate = recognizer.delegate
                recognizer.delegate = self
                self.recognizer = recognizer
            }
            recognizer.isEnabled = false
        }

        func unlock(from view: UIView) {
            let recognizer = self.recognizer ?? navigationController(from: view)?.interactivePopGestureRecognizer
            recognizer?.isEnabled = true
            if recognizer?.delegate === self {
                recognizer?.delegate = savedDelegate
            }
            self.recognizer = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { false }

        private func navigationController(from view: UIView) -> UINavigationController? {
            var responder: UIResponder? = view
            while let next = responder {
                if let controller = next as? UIViewController {
                    return controller.navigationController
                }
                responder = next.next
            }
            return nil
        }
    }
}

#Preview {
    NavigationStack {
        EmulatorScreen()
    }
    .environment(FirmwareLibrary())
    .environment(EmulatorCore())
}
