import AppKit
import QuartzCore
import SwiftUI

/// Records your own samples for each letter so the kNN layer can override the generic rules.
final class TeachModel: ObservableObject {
    static let letters = "ABCDEFGHIKLMNOPQRSTUVWXY".map { String($0) }

    @Published var selected = "A"
    @Published var counts: [String: Int] = [:]
    @Published var livePrediction = "–"
    @Published var ruleTop = ""
    @Published var recording = false
    @Published var handVisible = false
    @Published var lastRecorded = 0

    private var recordUntil: CFTimeInterval = 0
    private var recordedThisRun = 0
    let controller: SessionController

    init(controller: SessionController) {
        self.controller = controller
        counts = controller.knn.sampleCounts
    }

    /// Main thread, every processed frame.
    func ingest(features: HandFeatures?, prediction: Prediction?) {
        handVisible = features != nil
        livePrediction = prediction.map { "\($0.label)  \(Int($0.confidence * 100))%" } ?? "–"
        if let f = features {
            ruleTop = controller.rules.scores(f).prefix(3)
                .map { "\($0.0) \(Int($0.1 * 100))" }
                .joined(separator: "   ")
        }
        guard recording else { return }
        if let f = features {
            controller.knn.add(label: selected, vector: f.vector)
            recordedThisRun += 1
        }
        if CACurrentMediaTime() >= recordUntil {
            recording = false
            lastRecorded = recordedThisRun
            controller.knn.save()
            counts = controller.knn.sampleCounts
        }
    }

    func record() {
        recordedThisRun = 0
        recordUntil = CACurrentMediaTime() + 2.0
        recording = true
    }

    func clearSelected() {
        controller.knn.clear(label: selected)
        controller.knn.save()
        counts = controller.knn.sampleCounts
    }

    func clearAll() {
        controller.knn.clearAll()
        controller.knn.save()
        counts = controller.knn.sampleCounts
    }
}

struct TeachView: View {
    @ObservedObject var model: TeachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Teach SignType your hand").font(.title2.bold())
            Text("Pick a letter, hold the sign in front of the camera (watch the floating preview), then press Record. Two seconds of samples are captured. Two or three recordings per letter from slightly different angles work best. Taught letters override the built-in rules.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Picker("Letter", selection: $model.selected) {
                    ForEach(TeachModel.letters, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 120)
                Text("Samples for \(model.selected): \(model.counts[model.selected] ?? 0)")
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 12) {
                Button(model.recording ? "Recording…" : "Record 2 s") { model.record() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.recording || !model.handVisible)
                Button("Clear \(model.selected)") { model.clearSelected() }
                Button("Reset all") { model.clearAll() }
                Spacer()
                Text(model.handVisible ? "Hand: ✅" : "Hand: not visible")
                    .foregroundColor(.secondary)
            }

            GroupBox("Live") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prediction: \(model.livePrediction)").font(.system(.body, design: .monospaced))
                    Text("Rules top-3: \(model.ruleTop)").font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                    if model.lastRecorded > 0 {
                        Text("Last recording captured \(model.lastRecorded) samples.").font(.caption).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                ForEach(TeachModel.letters, id: \.self) { l in
                    VStack(spacing: 2) {
                        Text(l).font(.headline)
                        Text("\(model.counts[l] ?? 0)").font(.caption2).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(l == model.selected ? Color.accentColor.opacity(0.25) : Color.clear))
                    .onTapGesture { model.selected = l }
                }
            }

            Text("J and Z need motion and are not recognised yet. Samples live in ~/Library/Application Support/SignType/templates.json.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 520)
    }
}
