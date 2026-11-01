import Foundation
import Testing

@testable import ModeDockCore

private actor RecordingSender: TelemetrySender {
    var reports: [TelemetryReport] = []
    var succeeds = true

    func setSucceeds(_ value: Bool) { succeeds = value }

    func send(_ report: TelemetryReport, to url: URL) async -> Bool {
        reports.append(report)
        return succeeds
    }
}

@MainActor
struct TelemetryTests {
    private let context = TelemetryContext(
        appVersion: "0.1.0", osVersion: "26.1", language: "en")
    private let endpoint = URL(string: "https://example.com/telemetry")!

    private func makeDefaults() -> UserDefaults {
        let name = "TelemetryTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func recordsNothingUntilTurnedOn() {
        let telemetry = Telemetry(defaults: makeDefaults(), sender: RecordingSender())
        telemetry.record(.panelOpened)
        #expect(telemetry.preview(context: context) == nil)
    }

    @Test func countsEachFeaturePerDay() {
        var date = Date(timeIntervalSince1970: 1_763_200_000)  // 2025-11-15 UTC
        let telemetry = Telemetry(defaults: makeDefaults(), sender: RecordingSender(), now: { date })
        telemetry.setEnabled(true)
        telemetry.record(.panelOpened)
        telemetry.record(.panelOpened)
        telemetry.record(.captureArea)
        date += 86_400
        telemetry.record(.panelOpened)

        let report = telemetry.preview(context: context)
        #expect(report?.days["2025-11-15"] == ["panel.opened": 2, "capture.area": 1])
        #expect(report?.days["2025-11-16"] == ["panel.opened": 1])
    }

    @Test func optingOutDeletesEverything() {
        let defaults = makeDefaults()
        let telemetry = Telemetry(defaults: defaults, sender: RecordingSender())
        telemetry.setEnabled(true)
        let first = telemetry.preview(context: context)?.install
        telemetry.record(.panelOpened)

        telemetry.setEnabled(false)
        telemetry.setEnabled(true)

        #expect(telemetry.preview(context: context)?.days.isEmpty == true)
        // A new install ID, so the earlier reports can't be linked to the new ones.
        #expect(telemetry.preview(context: context)?.install != first)
    }

    @Test func sendsOnlyCompleteDaysAndForgetsThem() async {
        var date = Date(timeIntervalSince1970: 1_763_200_000)
        let sender = RecordingSender()
        let telemetry = Telemetry(defaults: makeDefaults(), sender: sender, endpoint: endpoint, now: { date })
        telemetry.setEnabled(true)
        telemetry.record(.profileApplied)
        date += 86_400
        telemetry.record(.panelOpened)

        #expect(await telemetry.sendIfDue(context: context))
        let reports = await sender.reports
        #expect(reports.count == 1)
        #expect(reports.first?.days == ["2025-11-15": ["profile.applied": 1]])
        #expect(reports.first?.context == context)
        // Today's count stays for a later report.
        #expect(telemetry.preview(context: context)?.days == ["2025-11-16": ["panel.opened": 1]])
    }

    @Test func keepsDaysWhenSendingFailsAndWaitsBeforeTryingAgain() async {
        var date = Date(timeIntervalSince1970: 1_763_200_000)
        let sender = RecordingSender()
        await sender.setSucceeds(false)
        let telemetry = Telemetry(defaults: makeDefaults(), sender: sender, endpoint: endpoint, now: { date })
        telemetry.setEnabled(true)
        telemetry.record(.profileApplied)
        date += 86_400

        #expect(await !telemetry.sendIfDue(context: context))
        #expect(telemetry.preview(context: context)?.days["2025-11-15"] == ["profile.applied": 1])
        #expect(await !telemetry.sendIfDue(context: context))
        #expect(await sender.reports.count == 1)
    }

    @Test func sendsNothingWithoutAnEndpoint() async {
        var date = Date(timeIntervalSince1970: 1_763_200_000)
        let sender = RecordingSender()
        let telemetry = Telemetry(defaults: makeDefaults(), sender: sender, now: { date })
        telemetry.setEnabled(true)
        telemetry.record(.profileApplied)
        date += 86_400

        #expect(await !telemetry.sendIfDue(context: context))
        #expect(await sender.reports.isEmpty)
    }

    @Test func theReportHoldsOnlyCountsAndBroadFacts() throws {
        let telemetry = Telemetry(defaults: makeDefaults(), sender: RecordingSender())
        telemetry.setEnabled(true)
        telemetry.record(.screenToggled)
        let json = try JSONEncoder().encode(telemetry.preview(context: context))
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(Set(object?.keys ?? [:].keys) == ["schema", "install", "context", "days"])
        let contextKeys = (object?["context"] as? [String: Any])?.keys.sorted()
        #expect(contextKeys == ["appVersion", "language", "osVersion"])
    }

    @Test func countsTheEventWithItsDetail() {
        let date = Date(timeIntervalSince1970: 1_763_200_000)
        let telemetry = Telemetry(defaults: makeDefaults(), sender: RecordingSender(), now: { date })
        telemetry.setEnabled(true)
        telemetry.record(.panelTab, detail: "screens")
        telemetry.record(.panelTab, detail: "power")
        #expect(
            telemetry.preview(context: context)?.days["2025-11-15"]
                == ["panel.tab.screens": 1, "panel.tab.power": 1])
    }

    @Test func bucketsTheTimeSinceOptingIn() {
        var date = Date(timeIntervalSince1970: 1_763_200_000)
        let telemetry = Telemetry(defaults: makeDefaults(), sender: RecordingSender(), now: { date })
        #expect(telemetry.optedInBucket == "")
        telemetry.setEnabled(true)
        #expect(telemetry.optedInBucket == "0-7")
        date += 20 * 86_400
        #expect(telemetry.optedInBucket == "8-30")
        date += 100 * 86_400
        #expect(telemetry.optedInBucket == "90+")
    }

    @Test func sendsTheSetupWithTheCounts() async {
        var date = Date(timeIntervalSince1970: 1_763_200_000)
        let sender = RecordingSender()
        let telemetry = Telemetry(defaults: makeDefaults(), sender: sender, endpoint: endpoint, now: { date })
        telemetry.setEnabled(true)
        telemetry.record(.panelOpened)
        date += 86_400
        var setup = TelemetrySetup()
        setup.profiles = 3
        setup.hiddenSections = ["utilities"]

        await telemetry.sendIfDue(context: context, setup: setup)

        #expect(await sender.reports.first?.setup == setup)
    }
}
