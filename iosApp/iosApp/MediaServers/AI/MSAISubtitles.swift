#if !os(macOS)
import Foundation

/// One timed subtitle line.
struct MSCue: Hashable {
    var start: Double
    var end: Double
    var text: String
}

/// Reads SRT and WebVTT text into cues.
enum MSSubtitleParser {
    static func parse(_ raw: String) -> [MSCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [MSCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0]),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            let body = lines[(timeIndex + 1)...]
                .joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(MSCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:01:02,345", "01:02.345", "1:02:03.4".
    static func seconds(_ raw: String) -> Double? {
        let clean = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let pieces = clean.split(separator: ":").map(String.init)
        guard !pieces.isEmpty, pieces.count <= 3 else { return nil }
        var total = 0.0
        for piece in pieces {
            guard let value = Double(piece) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// Translates a subtitle track with the person's AI key while it plays.
/// Lines are translated in batches, starting from where the viewer is, so
/// the first lines appear within seconds and the rest fill in ahead.
@MainActor
@Observable
final class MSAISubtitleTranslation {
    enum Phase: Equatable {
        case idle
        case loading
        case translating(done: Int, total: Int)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var source: MSSubtitleRef?
    private var cues: [MSCue] = []
    private var translated: [Int: String] = [:]
    private var task: Task<Void, Never>?

    private static let batchSize = 40

    var isActive: Bool { source != nil }

    func start(_ ref: MSSubtitleRef, from position: Double) {
        stop()
        source = ref
        phase = .loading
        task = Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: ref.url)
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let parsed = MSSubtitleParser.parse(text)
                guard !parsed.isEmpty else { throw MSAIError.badAnswer }
                await self?.run(parsed, from: position)
            } catch is CancellationError {
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        source = nil
        cues = []
        translated = [:]
        phase = .idle
    }

    /// The translated line on screen at `time`, if any.
    func text(at time: Double) -> String? {
        guard !cues.isEmpty else { return nil }
        // Cues are sorted; a binary search keeps this cheap at 4 Hz.
        var low = 0, high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if time < cue.start { high = mid - 1 } else if time > cue.end { low = mid + 1 } else {
                return translated[mid]
            }
        }
        return nil
    }

    private func run(_ parsed: [MSCue], from position: Double) async {
        cues = parsed
        let first = parsed.firstIndex { $0.end >= position } ?? 0
        // From the viewer's place to the end, then the part before it.
        let order = Array(first..<parsed.count) + Array(0..<first)
        var done = 0
        phase = .translating(done: 0, total: parsed.count)
        var index = 0
        while index < order.count {
            if Task.isCancelled { return }
            let batch = Array(order[index..<min(index + Self.batchSize, order.count)])
            do {
                let lines = try await MSAITranslator.shared.translate(batch.map { parsed[$0].text })
                for (slot, cueIndex) in batch.enumerated() where slot < lines.count {
                    translated[cueIndex] = lines[slot]
                }
            } catch is CancellationError {
                return
            } catch {
                // One failed batch should not end the whole track.
                if translated.isEmpty {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
            index += Self.batchSize
            done = min(index, order.count)
            phase = done >= order.count ? .ready : .translating(done: done, total: order.count)
        }
    }
}
#endif
