import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section("Typing") {
                Picker("Mode", selection: $settings.mode) {
                    ForEach(Mode.allCases) { m in Text(m.title).tag(m) }
                }
                HStack {
                    Text("Hold time per letter")
                    Slider(value: Binding(
                        get: { Double(settings.stableFrames) },
                        set: { settings.stableFrames = Int($0.rounded()) }
                    ), in: 3...15, step: 1)
                    Text("\(settings.stableFrames) frames ≈ \(String(format: "%.1f", Double(settings.stableFrames) / 15)) s")
                        .foregroundColor(.secondary)
                        .frame(width: 150, alignment: .trailing)
                }
                HStack {
                    Text("Auto-stop after no hand for")
                    Slider(value: $settings.autoStopSeconds, in: 2...15, step: 1)
                    Text("\(Int(settings.autoStopSeconds)) s")
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Section("Gemma 4 (cloud, optional)") {
                SecureField("Gemini API key", text: $settings.gemmaApiKey)
                TextField("Model", text: $settings.gemmaModel)
                Text("Used by “Batch via Gemma 4” (the whole session is sent when you stop) and by “Hybrid” (only the frames of a motion sign that none of your taught words matched are sent, with the text so far as context). Models: gemma-4-26b-a4b-it (faster) or gemma-4-31b-it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Permissions") {
                Text(Permissions.summary)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Button("Accessibility…") { Permissions.requestAccessibility(); Permissions.openSystemSettings(pane: "Privacy_Accessibility") }
                    Button("Input Monitoring…") { Permissions.requestInputMonitoring(); Permissions.openSystemSettings(pane: "Privacy_ListenEvent") }
                    Button("Camera…") { Permissions.openSystemSettings(pane: "Privacy_Camera") }
                }
                Text("Also set System Settings ▸ Keyboard ▸ “Press 🌐 key to” → Do Nothing, otherwise macOS starts Dictation on a double tap.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }
}
