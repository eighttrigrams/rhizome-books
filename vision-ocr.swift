// Apple Vision OCR witness for the hybrid transcription pipeline.
// Usage: swift vision-ocr.swift <image> [<image> ...]
// Prints recognized text of each image to stdout (images separated by \f when
// more than one). Exits non-zero on any failure — no silent empty output.
import Foundation
import Vision
import AppKit

func ocr(_ path: String) throws -> String {
    guard let img = NSImage(contentsOfFile: path),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cg = rep.cgImage else {
        throw NSError(domain: "vision-ocr", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "cannot read image: \(path)"])
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try handler.perform([request])
    guard let observations = request.results else {
        throw NSError(domain: "vision-ocr", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "no results for: \(path)"])
    }
    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
    if lines.isEmpty {
        throw NSError(domain: "vision-ocr", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "zero text lines recognized in: \(path)"])
    }
    return lines.joined(separator: "\n")
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    FileHandle.standardError.write("usage: vision-ocr.swift <image> [<image> ...]\n".data(using: .utf8)!)
    exit(1)
}
do {
    var first = true
    for path in args {
        if !first { print("\u{0C}") }
        first = false
        print(try ocr(path))
    }
} catch {
    FileHandle.standardError.write("vision-ocr: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
