import SwiftUI
import PulsHealthSync

/// Measures pure read+encode+compress throughput against the real HealthKit store
/// using a throwaway engine (separate anchors, discarding transport), so the real
/// sync state is untouched. This isolates device-side throughput from network and
/// server performance for tuning batch size / concurrency.
struct BenchmarkView: View {
    @Environment(AppModel.self) private var model
    @State private var running = false
    @State private var results: [TypeSyncStatus] = []
    @State private var elapsed: TimeInterval?
    @State private var benchmarkTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Text("Reads all enabled types from your start date through a discarding transport. Uses temporary anchors — your real sync state is not modified.")
                    .font(.caption).foregroundStyle(.secondary)
                if running {
                    Button("Stop", role: .destructive) { benchmarkTask?.cancel() }
                } else {
                    Button("Start Benchmark") { run() }
                        .disabled(model.config.enabledTypes.isEmpty)
                }
            }

            if running {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading from HealthKit…").foregroundStyle(.secondary)
                    }
                }
            }

            if !results.isEmpty {
                Section("Results\(elapsed.map { " — total \($0.shortDuration)" } ?? "")") {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.descriptor.displayName)
                            HStack(spacing: 12) {
                                Text("\(result.state.totalSamplesExported.compactString) samples")
                                Text(result.state.totalBytesUploaded.byteString + " gzip")
                                if let rate = throughput(result) {
                                    Text("\(Int(rate))/s").bold().monospacedDigit()
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let total = totalRate {
                        LabeledContent("Aggregate throughput", value: "\(Int(total)) samples/s")
                    }
                }
            }
        }
        .navigationTitle("Benchmark")
        .onDisappear { benchmarkTask?.cancel() }
    }

    private func throughput(_ status: TypeSyncStatus) -> Double? {
        guard let elapsed, elapsed > 0 else { return nil }
        return Double(status.state.totalSamplesExported) / elapsed
    }

    private var totalRate: Double? {
        guard let elapsed, elapsed > 0 else { return nil }
        let total = results.reduce(0) { $0 + $1.state.totalSamplesExported }
        return Double(total) / elapsed
    }

    private func run() {
        running = true
        results = []
        elapsed = nil
        let config = model.config
        benchmarkTask = Task {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("puls-benchmark-\(UUID())", isDirectory: true)
            // Throwaway state: an in-memory token store keeps the benchmark's
            // engine away from the app's Keychain item.
            // No recent-window pass: it would send a month twice and the
            // throughput figure would count only the second time.
            let engine = HealthSyncEngine(
                store: SyncStateStore(directory: tmp, tokenStore: InMemoryTokenStore()),
                eventLog: SyncEventLog(directory: tmp),
                recentWindowFirst: false
            )
            var benchConfig = config
            benchConfig.serverURL = nil
            await engine.configure(benchConfig)
            await engine.setTransport(DryRunTransport())

            let clock = ContinuousClock()
            let duration = await clock.measure {
                await engine.syncAllEnabled(reason: .manual)
            }
            let snapshot = await engine.snapshot()
            await MainActor.run {
                results = snapshot.sorted {
                    $0.state.totalSamplesExported > $1.state.totalSamplesExported
                }
                elapsed = TimeInterval(duration.components.seconds)
                    + TimeInterval(duration.components.attoseconds) / 1e18
                running = false
            }
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
