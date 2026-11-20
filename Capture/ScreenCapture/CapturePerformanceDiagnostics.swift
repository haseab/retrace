import Darwin
import Foundation
import Shared

/// Fixed vocabulary only: never accept titles, URLs, window/process IDs, or image data.
enum CapturePerformanceStage: CaseIterable, Sendable {
    case total, metadata, browserURL, urlAccessibility, urlFallback, callObservation
    case sourceSnapshots, screenshot, ocrGeometry, accessibilitySnapshot, privacy
    case faceDetection, faceRender, materialize, deduplication, queueDelay
}

enum CapturePerformanceCounter: Sendable {
    case completed, dropped, urlLookups, urlCacheHits, urlUnavailable
    case trackedWindows, visibleWindows, conferenceWindows, consentBypassed, faceWindows, faces
    case isolatedSources, desktopFallbacks, fullWindowFallbacks
    case callActive, callEnded, callUnknownAccessibility, callUnknownWindow, callUnknownIncomplete, callUnknownControls
    case pixelReused, kept, deduplicated, intervalTrigger, clickTrigger, windowTrigger
}

struct CapturePerformanceSample: Sendable {
    var durations: [CapturePerformanceStage: Double] = [:]
    var counts: [CapturePerformanceCounter: Int] = [:]
    var width = 0
    var height = 0

    mutating func record(_ stage: CapturePerformanceStage, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        durations[stage, default: 0] += milliseconds
    }

    mutating func increment(_ counter: CapturePerformanceCounter, by count: Int = 1) {
        guard count > 0 else { return }
        counts[counter, default: 0] += count
    }

    var isSlow: Bool {
        (durations[.total] ?? 0) >= 500 || (durations[.metadata] ?? 0) >= 250
            || (durations[.browserURL] ?? 0) >= 150 || (durations[.callObservation] ?? 0) >= 150
            || (durations[.faceDetection] ?? 0) >= 250 || (durations[.faceRender] ?? 0) >= 150
            || (durations[.sourceSnapshots] ?? 0) >= 100 || (durations[.screenshot] ?? 0) >= 250
            || (durations[.accessibilitySnapshot] ?? 0) >= 150 || (durations[.materialize] ?? 0) >= 150
            || (durations[.queueDelay] ?? 0) >= 500
    }
}

/// One token per capture. A short lock protects counters across actor hops; no work/logging under the lock.
final class CapturePerformanceFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var sample = CapturePerformanceSample()

    static func now() -> TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    func record(_ stage: CapturePerformanceStage, since start: TimeInterval) {
        record(stage, milliseconds: (Self.now() - start) * 1000)
    }

    func record(_ stage: CapturePerformanceStage, milliseconds: Double) {
        lock.lock()
        sample.record(stage, milliseconds: milliseconds)
        lock.unlock()
    }

    func increment(_ counter: CapturePerformanceCounter, by count: Int = 1) {
        lock.lock()
        sample.increment(counter, by: count)
        lock.unlock()
    }

    func dimensions(width: Int, height: Int) {
        lock.lock()
        sample.width = width
        sample.height = height
        lock.unlock()
    }

    func snapshot() -> CapturePerformanceSample {
        lock.lock()
        defer { lock.unlock() }
        return sample
    }
}

/// Actor-owned bounded aggregation. Sorting and log formatting happen only on emission.
struct CapturePerformanceDiagnostics {
    struct Timing: Sendable {
        let sampleCount: Int
        let p50Ms: Double
        let p95Ms: Double
        let maxMs: Double
    }

    struct Report: Sendable {
        let isSlow: Bool
        let pipeline: Bool
        let frames: Int
        let windowSeconds: Double
        let suppressedSlowFrames: Int
        let timings: [CapturePerformanceStage: Timing]
        let counts: [CapturePerformanceCounter: Int]
        let width: Int
        let height: Int

        private func p95(_ stage: CapturePerformanceStage) -> Double { (timings[stage]?.p95Ms ?? 0).rounded() }
        private func count(_ counter: CapturePerformanceCounter) -> Int { counts[counter] ?? 0 }

        var messages: [PrivacyLogMessage] {
            if pipeline {
                return ["[CapturePerf] pipeline slow=\(isSlow) frames=\(frames) window_s=\(windowSeconds.rounded()) suppressed=\(suppressedSlowFrames) cycle_p95_ms=\(p95(.total)) queue_p95_ms=\(p95(.queueDelay)) pixels_p95_ms=\(p95(.materialize)) handling_p95_ms=\(p95(.deduplication)) reused=\(count(.pixelReused)) kept=\(count(.kept)) not_kept=\(count(.deduplicated)) dropped=\(count(.dropped)) interval=\(count(.intervalTrigger)) click=\(count(.clickTrigger)) window_change=\(count(.windowTrigger))"]
            }
            if isSlow {
                return ["[CapturePerf] slow total_ms=\(p95(.total)) metadata_ms=\(p95(.metadata)) url_ms=\(p95(.browserURL)) url_ax_ms=\(p95(.urlAccessibility)) url_fallback_ms=\(p95(.urlFallback)) controls_ms=\(p95(.callObservation)) sources_ms=\(p95(.sourceSnapshots)) screenshot_ms=\(p95(.screenshot)) ax_snapshot_ms=\(p95(.accessibilitySnapshot)) privacy_ms=\(p95(.privacy)) detect_ms=\(p95(.faceDetection)) render_ms=\(p95(.faceRender)) url_calls=\(count(.urlLookups)) scan_windows=\(count(.faceWindows)) bypassed=\(count(.consentBypassed)) dropped=\(count(.dropped)) suppressed=\(suppressedSlowFrames) width=\(width) height=\(height)"]
            }
            return [
                "[CapturePerf] summary frames=\(frames) window_s=\(windowSeconds.rounded()) completed=\(count(.completed)) dropped=\(count(.dropped)) sample_n=\(timings[.total]?.sampleCount ?? 0) total_p50_ms=\((timings[.total]?.p50Ms ?? 0).rounded()) total_p95_ms=\(p95(.total)) total_max_ms=\((timings[.total]?.maxMs ?? 0).rounded()) metadata_p95_ms=\(p95(.metadata)) sources_p95_ms=\(p95(.sourceSnapshots)) screenshot_p95_ms=\(p95(.screenshot)) geometry_p95_ms=\(p95(.ocrGeometry)) ax_snapshot_p95_ms=\(p95(.accessibilitySnapshot)) privacy_p95_ms=\(p95(.privacy)) width=\(width) height=\(height)",
                "[CapturePerf] metadata url_calls=\(count(.urlLookups)) url_cache_hits=\(count(.urlCacheHits)) url_unavailable=\(count(.urlUnavailable)) url_p95_ms=\(p95(.browserURL)) url_ax_p95_ms=\(p95(.urlAccessibility)) url_fallback_p95_ms=\(p95(.urlFallback)) controls_p95_ms=\(p95(.callObservation)) active=\(count(.callActive)) ended=\(count(.callEnded)) unknown_accessibility=\(count(.callUnknownAccessibility)) unknown_window=\(count(.callUnknownWindow)) unknown_incomplete=\(count(.callUnknownIncomplete)) unknown_controls=\(count(.callUnknownControls))",
                "[CapturePerf] faces tracked_window_observations=\(count(.trackedWindows)) visible_window_observations=\(count(.visibleWindows)) conference_window_observations=\(count(.conferenceWindows)) bypassed=\(count(.consentBypassed)) scan_windows=\(count(.faceWindows)) faces=\(count(.faces)) isolated_sources=\(count(.isolatedSources)) desktop_sources=\(count(.desktopFallbacks)) full_window_fallbacks=\(count(.fullWindowFallbacks)) detect_p95_ms=\(p95(.faceDetection)) render_p95_ms=\(p95(.faceRender))"
            ]
        }
    }

    private let pipeline: Bool
    private var windowStartedAt: TimeInterval
    private var lastSlowAt: TimeInterval?
    private var suppressedSlowFrames = 0
    private var frames = 0
    private var timings: [CapturePerformanceStage: [Double]] = [:]
    private var maxima: [CapturePerformanceStage: Double] = [:]
    private var counts: [CapturePerformanceCounter: Int] = [:]
    private var width = 0
    private var height = 0
    private var processBaseline = ProcessSnapshot.capture()

    init(startedAt: TimeInterval = CapturePerformanceFrame.now(), pipeline: Bool = false) {
        windowStartedAt = startedAt
        self.pipeline = pipeline
    }

    mutating func record(_ sample: CapturePerformanceSample, at now: TimeInterval) -> [Report] {
        frames += 1
        width = sample.width
        height = sample.height
        for (stage, ms) in sample.durations {
            timings[stage, default: []].append(ms)
            if timings[stage]!.count > 256 { timings[stage]!.removeFirst() }
            maxima[stage] = max(maxima[stage] ?? 0, ms)
        }
        for (counter, value) in sample.counts { counts[counter, default: 0] += value }
        var reports: [Report] = []
        if sample.isSlow {
            if lastSlowAt.map({ now - $0 >= 30 }) ?? true {
                reports.append(makeReport(isSlow: true, frames: 1, seconds: 0,
                    timings: sample.durations.mapValues { [$0] }, maxima: sample.durations,
                    counts: sample.counts))
                lastSlowAt = now
                suppressedSlowFrames = 0
            } else { suppressedSlowFrames += 1 }
        }
        if now - windowStartedAt >= 60 { reports += flush(at: now) }
        return reports
    }

    mutating func flush(at now: TimeInterval) -> [Report] {
        guard frames > 0 else { return [] }
        let report = makeReport(isSlow: false, frames: frames, seconds: max(0, now - windowStartedAt),
            timings: timings, maxima: maxima, counts: counts)
        frames = 0
        timings.removeAll(keepingCapacity: true)
        maxima.removeAll(keepingCapacity: true)
        counts.removeAll(keepingCapacity: true)
        windowStartedAt = now
        return [report]
    }

    private func makeReport(isSlow: Bool, frames: Int, seconds: Double,
                            timings: [CapturePerformanceStage: [Double]], maxima: [CapturePerformanceStage: Double],
                            counts: [CapturePerformanceCounter: Int]) -> Report {
        let distributions = timings.mapValues { values -> Timing in
            let sorted = values.sorted()
            return Timing(sampleCount: sorted.count, p50Ms: sorted[(sorted.count - 1) / 2],
                p95Ms: sorted[Int((Double(sorted.count - 1) * 0.95).rounded(.up))], maxMs: sorted.last ?? 0)
        }.map { stage, timing in
            (stage, Timing(sampleCount: timing.sampleCount, p50Ms: timing.p50Ms, p95Ms: timing.p95Ms,
                maxMs: maxima[stage] ?? timing.maxMs))
        }
        return Report(isSlow: isSlow, pipeline: pipeline, frames: frames, windowSeconds: seconds,
            suppressedSlowFrames: suppressedSlowFrames, timings: Dictionary(uniqueKeysWithValues: distributions),
            counts: counts, width: width, height: height)
    }

    mutating func emit(_ reports: [Report]) {
        for report in reports {
            for message in report.messages { Log.info(message, category: .capture) }
        }
        guard !pipeline, !reports.isEmpty else { return }
        let current = ProcessSnapshot.capture()
        let elapsed = current.uptime - processBaseline.uptime
        let cpuPercent = elapsed > 0 ? max(0, current.cpuSeconds - processBaseline.cpuSeconds) / elapsed * 100 : 0
        let message: PrivacyLogMessage = "[CapturePerf] process window_s=\(elapsed.rounded()) cpu_one_core_pct=\(cpuPercent.rounded()) rss_mib=\(current.residentMiB.rounded()) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
        Log.info(message, category: .capture)
        processBaseline = current
    }

    private struct ProcessSnapshot {
        let uptime: Double
        let cpuSeconds: Double
        let residentMiB: Double

        static func capture() -> Self {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage) // timeval seconds, not hardware ticks.
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            var info = mach_task_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &size)
                }
            }
            return Self(uptime: CapturePerformanceFrame.now(), cpuSeconds: cpu,
                residentMiB: status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1)
        }
    }
}

struct PerformanceConferenceCallObserver: ConferenceCallObserving {
    let base: any ConferenceCallObserving
    let performance: CapturePerformanceFrame?

    func observe(_ target: ConferenceCallObservationTarget) -> ConferenceCallObservation {
        let start = CapturePerformanceFrame.now()
        let observation = base.observe(target)
        performance?.record(.callObservation, since: start)
        let counter: CapturePerformanceCounter
        switch observation {
        case .active: counter = .callActive
        case .ended: counter = .callEnded
        case .unknown(.accessibilityUnavailable): counter = .callUnknownAccessibility
        case .unknown(.windowUnavailable): counter = .callUnknownWindow
        case .unknown(.traversalIncomplete): counter = .callUnknownIncomplete
        case .unknown(.controlNotFound): counter = .callUnknownControls
        }
        performance?.increment(counter)
        return observation
    }
}
