import SwiftUI
import UIKit

/// Secondary, hidden-by-default screen (Section 13 of the project spec).
/// Everything here is either a real static fact, a copy of CPU state taken
/// on the emulation thread, or Podium's real activity log — never sample or
/// placeholder data. The screen does not read the live CPU: that object is
/// owned by the emulation thread.
struct DeveloperSettingsScreen: View {
    @Environment(EmulatorCore.self) private var emulatorCore
    @State private var stikDebugUnavailable = false

    /// True once the session attached `DBTEngine`, which only happens after
    /// the JIT region is mapped.
    private var jitActive: Bool {
        emulatorCore.jitAvailable || emulatorCore.cpuSample?.dbtAttached == true
    }

    var body: some View {
        List {
            Section("CPU") {
                LabeledContent("Target Architecture", value: "ARMv7 (Apple A4)")
                if let sample = emulatorCore.cpuSample {
                    LabeledContent("Status", value: sample.dbtAttached ? "DBT" : "Interpreter")
                    LabeledContent("Speed", value: speedText)
                    LabeledContent("PC", value: hex(sample.registers[Registers.pcIndex]))
                    LabeledContent("CPSR Flags", value: cpsrSummary(CPSR(rawValue: sample.cpsr)))
                    if let error = sample.lastError {
                        LabeledContent("Halted", value: describe(error))
                            .foregroundStyle(.red)
                    }
                } else {
                    LabeledContent("Status", value: "Not active")
                }
            }

            if let sample = emulatorCore.cpuSample {
                Section("Registers") {
                    ForEach(0..<16, id: \.self) { index in
                        LabeledContent(registerName(index), value: hex(sample.registers[index]))
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            Section {
                Button("Open StikDebug") {
                    openStikDebug()
                }
                LabeledContent("Status", value: jitActive ? "Active" : "Not active")
                if !emulatorCore.jitStatus.isEmpty {
                    Text(emulatorCore.jitStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let sample = emulatorCore.cpuSample, sample.dbtAttached {
                    LabeledContent("Engine", value: "DBT")
                    LabeledContent("Blocks translated", value: sample.blocksTranslated.formatted())
                    LabeledContent("Entries", value: sample.entries.formatted())
                    LabeledContent("Guest instructions translated", value: sample.guestInstructionsTranslated.formatted())
                    LabeledContent("Deopts", value: sample.deopts.formatted())
                    LabeledContent("Interpreted inside a block", value: sample.interpretedInPlace.formatted())
                    LabeledContent("Not translated", value: "ARM \(sample.notTranslatedARM.formatted()), Thumb \(sample.notTranslatedThumb.formatted())")
                }
            } header: {
                Text("JIT")
            } footer: {
                Text("Translated execution is DBTEngine, attached when the JIT region exists. Counters refresh about twice a second from the emulation thread. A high “Interpreted inside a block” count means translated code is still handing instructions back to the interpreter.")
            }

            Section("Memory") {
                LabeledContent("Target RAM", value: Int64(EmulatorCore.physicalMemorySize).formattedByteCount)
                LabeledContent("Status", value: emulatorCore.isPoweredOn ? "Mapped at 0x\(GuestMemoryLayout.ramPhysicalBase.hexString8)" : "Not active")
            }

            Section("Boot Arguments") {
                Text("Not yet supported.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Copy Logs") {
                    UIPasteboard.general.string = emulatorCore.fullLogText
                }
                Button("Share Logs") {
                    shareLogs()
                }
                if emulatorCore.log.isEmpty {
                    Text("No activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(emulatorCore.log.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.formattedTime)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Emulator Log")
            }

            Section {
                Text("Development Version - JIT Enabled Build")
                    .fontWeight(.bold)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .alert("StikDebug isn't available", isPresented: $stikDebugUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Install StikDebug, then try Open StikDebug again.")
        }
    }

    /// The persisted log, shared as plain text.
    private func shareLogs() {
        let controller = UIActivityViewController(activityItems: [emulatorCore.fullLogText], applicationActivities: nil)
        guard let presenter = Self.topViewController() else { return }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 1, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
            ?? scenes.first?.windows.first?.rootViewController
        var presenter = root
        while let presented = presenter?.presentedViewController { presenter = presented }
        return presenter
    }

    private func openStikDebug() {
        guard let url = URL(string: "stikdebug://") else { return }
        UIApplication.shared.open(url) { accepted in
            if !accepted {
                Task { @MainActor in
                    stikDebugUnavailable = true
                }
            }
        }
    }

    private var speedText: String {
        let rate = emulatorCore.instructionsPerSecond
        guard rate > 0 else { return "—" }
        return String(format: "%.1f M/s", rate / 1_000_000)
    }

    private func hex(_ value: UInt32) -> String {
        "0x" + value.hexString8
    }

    private func registerName(_ index: Int) -> String {
        switch index {
        case Registers.pcIndex: return "r15 (pc)"
        case Registers.lrIndex: return "r14 (lr)"
        case Registers.spIndex: return "r13 (sp)"
        default: return "r\(index)"
        }
    }

    private func cpsrSummary(_ cpsr: CPSR) -> String {
        (cpsr.negative ? "N" : "-")
            + (cpsr.zero ? "Z" : "-")
            + (cpsr.carry ? "C" : "-")
            + (cpsr.overflow ? "V" : "-")
    }

    private func describe(_ error: CPUError) -> String {
        switch error {
        case .unsupportedInstruction(let word, let address):
            return "Unsupported instruction \(hex(word)) at \(hex(address))"
        case .undefinedInstruction(let word, let address):
            return "Undefined instruction \(hex(word)) at \(hex(address))"
        case .memoryFault(let fault, let address):
            return "Memory fault at \(hex(address)): \(fault)"
        case .unimplementedHardwareFeature(let description, let address):
            return "\(description), at \(hex(address))"
        }
    }
}

#Preview {
    NavigationStack {
        DeveloperSettingsScreen()
    }
    .environment(EmulatorCore())
}
