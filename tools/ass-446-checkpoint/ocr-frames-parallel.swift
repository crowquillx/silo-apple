import Foundation
import Vision
import ImageIO
final class Results: @unchecked Sendable {
    let lock = NSLock()
    var values: [String: [String]] = [:]
    func add(_ key: String, _ value: [String]) {
        lock.lock(); defer { lock.unlock() }; values[key] = value
    }
}
let results = Results()
let files = Array(CommandLine.arguments.dropFirst())
let workers = min(4, files.count)
if workers > 0 {
    DispatchQueue.concurrentPerform(iterations: workers) { worker in
        for index in stride(from: worker, to: files.count, by: workers) {
            autoreleasepool {
                let url = URL(fileURLWithPath: files[index])
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]
                do {
                    try VNImageRequestHandler(url: url).perform([request])
                    results.add(url.lastPathComponent, request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])
                } catch { results.add(url.lastPathComponent, ["ERROR: \(error)"]) }
            }
        }
    }
}
let data = try JSONSerialization.data(withJSONObject: results.values, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
