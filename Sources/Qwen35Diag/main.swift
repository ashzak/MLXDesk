// Standalone CLI harness for diagnosing the Qwen3.5 hybrid-attention generation stall
// reported against MLX Desk's native runtime (see MLXService.swift / Qwen35.swift timing
// instrumentation). Deliberately has zero AppKit/GUI surface -- this exercises the exact
// same load + ChatSession.streamResponse path the app uses, from the command line, so it
// can be run and timed directly without any screen automation.
//
// Usage: Qwen35Diag <path-to-local-model-directory> ["prompt text"]

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("Usage: Qwen35Diag <path-to-local-model-directory> [\"prompt text\"]")
    exit(1)
}
let modelPath = arguments[1]
let prompt = arguments.count >= 3 ? arguments[2] : "Say hello in exactly three words."

let modelURL = URL(fileURLWithPath: modelPath)
print("[DIAG] Loading model from \(modelURL.path)")

let clock = ContinuousClock()
let loadStart = clock.now

let configuration = ModelConfiguration(directory: modelURL)

Task {
    do {
        let container = try await #huggingFaceLoadModelContainer(
            configuration: configuration
        ) { progress in
            print("[DIAG] load progress: \(progress.fractionCompleted)")
        }
        print("[DIAG] Model loaded in \(clock.now - loadStart)")

        let session = ChatSession(
            container,
            instructions: "You are a helpful assistant.",
            generateParameters: .init(maxTokens: 64, temperature: 0.2)
        )

        print("[DIAG] Sending prompt: \(prompt)")
        let genStart = clock.now
        var tokenCount = 0
        var firstTokenAt: ContinuousClock.Instant?
        for try await chunk in session.streamResponse(to: prompt) {
            if firstTokenAt == nil {
                firstTokenAt = clock.now
                print("[DIAG] First chunk after \(clock.now - genStart)")
            }
            tokenCount += 1
            print(chunk, terminator: "")
            fflush(stdout)
        }
        print("")
        print("[DIAG] Generation finished. Total: \(clock.now - genStart), chunks: \(tokenCount)")
        exit(0)
    } catch {
        print("[DIAG] FAILED: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
