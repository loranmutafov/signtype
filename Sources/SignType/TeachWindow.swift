import AppKit
import QuartzCore
import SwiftUI

/// Records your own samples: still handshapes for letters (kNN) and motion templates for
/// whole-word signs (DTW). Both override the generic behaviour.
final class TeachModel: ObservableObject {
    static let letters = "ABCDEFGHIKLMNOPQRSTUVWXY".map { String($0) }

    enum Tab: String, CaseIterable, Identifiable {
        case letters = "Letters"
        case words = "Words"
        var id: String { rawValue }
    }

    @Published var tab: Tab = .letters

    // Letters
    @Published var selected = "A"
    @Published var counts: [String: Int] = [:]
    @Published var livePrediction = "–"
    @Published var ruleTop = ""
    @Published var recording = false
    @Published var handVisible = false
    @Published var lastRecorded = 0

    // Words
    @Published var word = ""
    @Published var wordCounts: [String: Int] = [:]
    @Published var wordStatus = "Type a word, press Record, then perform the sign once."
    @Published var armed = false
    @Published var lastSegmentInfo = ""

    private var recordUntil: CFTimeInterval = 0
    private var recordedThisRun = 0
    private var armedUntil: CFTimeInterval = 0
    private var armTimer: Timer?
    let controller: SessionController

    init(controller: SessionController) {
        self.controller = controller
        counts = controller.knn.sampleCounts
        wordCounts = controller.matcher.counts
    }

    // MARK: Letters

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

    // MARK: Words

    var wordLabel: String { word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Main thread, whenever the segmenter completes a motion segment.
    func ingest(segment: MotionSegment) {
        let scores = controller.matcher.scores(segment).prefix(3)
        let ranked = scores.map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: "   ")
        lastSegmentInfo = "Last motion: \(segment.frames.count) frames, path \(String(format: "%.2f", segment.pathLength))" + (ranked.isEmpty ? "" : "  ·  nearest: \(ranked)")

        guard armed, !wordLabel.isEmpty else { return }
        controller.matcher.add(label: wordLabel, segment: segment)
        controller.matcher.save()
        wordCounts = controller.matcher.counts
        armed = false
        armTimer?.invalidate()
        wordStatus = "Captured “\(wordLabel)” (\(segment.frames.count) frames). Record it two or three times."
    }

    func recordWord() {
        guard !wordLabel.isEmpty else {
            wordStatus = "Type the word first."
            return
        }
        armed = true
        armedUntil = CACurrentMediaTime() + 6
        wordStatus = "Go: perform the sign for “\(wordLabel)” now, then hold still."
        armTimer?.invalidate()
        armTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if !self.armed {
                t.invalidate()
            } else if CACurrentMediaTime() > self.armedUntil {
                self.armed = false
                self.wordStatus = "No motion detected. Make the sign bigger and come to a clear stop at the end."
                t.invalidate()
            }
        }
    }

    func cancelWord() {
        armed = false
        armTimer?.invalidate()
        wordStatus = "Cancelled."
    }

    func removeWord(_ label: String) {
        controller.matcher.remove(label: label)
        controller.matcher.save()
        wordCounts = controller.matcher.counts
    }

    func clearAllWords() {
        controller.matcher.removeAll()
        controller.matcher.save()
        wordCounts = controller.matcher.counts
    }
}

struct TeachView: View {
    @ObservedObject var model: TeachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Teach SignType your signing").font(.title2.bold())
            Picker("", selection: $model.tab) {
                ForEach(TeachModel.Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.tab {
            case .letters: letters
            case .words: words
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    // MARK: Letters tab

    private var letters: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                Button("Reset all letters") { model.clearAll() }
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

            Text("J and Z need motion: teach them as words on the Words tab. Samples live in ~/Library/Application Support/SignType/.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Words tab

    private var words: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Whole-word signs are matched by motion: both hands relative to your shoulders and face, over time. Type the word, press Record, perform the sign once at normal speed, and come to a clear stop. Repeat two or three times. Your shoulders should be in frame.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                TextField("word, e.g. hello", text: $model.word)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .disabled(model.armed)
                if model.armed {
                    Button("Cancel") { model.cancelWord() }
                } else {
                    Button("Record sign") { model.recordWord() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.wordLabel.isEmpty)
                }
                Spacer()
                Text(model.armed ? "● Watching for motion" : "")
                    .foregroundColor(.orange)
            }

            Text(model.wordStatus)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Live") {
                Text(model.lastSegmentInfo.isEmpty ? "No motion segment yet. Move a hand and stop." : model.lastSegmentInfo)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.wordCounts.isEmpty {
                Text("No words taught yet.").foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.wordCounts.keys.sorted(), id: \.self) { w in
                            HStack {
                                Text(w).font(.headline)
                                Text("× \(model.wordCounts[w] ?? 0)").foregroundColor(.secondary)
                                Spacer()
                                Button("Remove") { model.removeWord(w) }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                HStack {
                    Spacer()
                    Button("Reset all words") { model.clearAllWords() }
                }
            }

            Text("Distances under 0.6 match. If a word keeps reading as “?”, record it again at the speed you actually sign it. Untaught signs fall back to Gemma 4 in Hybrid mode.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
