import Foundation
import Vision
import ImageIO
var results: [String: [String]] = [:]
for file in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: file)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    do {
        try VNImageRequestHandler(url: url).perform([request])
        results[url.lastPathComponent] = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    } catch { results[url.lastPathComponent] = ["ERROR: \(error)"] }
}
let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
