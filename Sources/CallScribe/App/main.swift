import AppKit
import CallScribeCore

// Debug: `CallScribe --analyze <session-folder>` prints the leak-aware speech regions for the Me stream.
if let index = CommandLine.arguments.firstIndex(of: "--analyze"), index + 1 < CommandLine.arguments.count {
    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    do {
        let me = try WAVRepair.readSamples(url: directory.appendingPathComponent("me.wav"))
        let others = try WAVRepair.readSamples(url: directory.appendingPathComponent("others.wav"))
        let result = LeakAwareVAD.analyze(me: me, others: others)
        print(String(format: "Noise floor %.0f dB, coupling %@, leak ignored %.1f s",
                     result.noiseFloorDB, result.couplingDB.map { String(format: "%.1f dB", $0) } ?? "none", result.leakSeconds))
        for region in result.regions {
            print(String(format: "Me speech %7.2f – %7.2f s", region.start, region.end))
        }
        exit(0)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
