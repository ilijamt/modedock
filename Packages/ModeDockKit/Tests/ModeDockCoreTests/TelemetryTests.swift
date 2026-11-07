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

private struct HookSender: TelemetrySender {
    let during: @MainActor @Sendable () async -> Void

    func send(_ report: TelemetryReport, to url: URL) async -> Bool {
        await during()
        return true
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
        telemetry.record(.panelOpen)
        #expect(telemetry.preview(context: context) == nil)
    }

    @Test func countsEachFeatureAndEachDayItRan() {
        var date = Date(timeIntervalSince1970: 1_763_200_000)
        let telemetry = Telemetry(defaults: makeDefaults(), sender: RecordingSender(), now: { date })
        telemetry.setEnabled(true)
        telemetry.record(.panelOpen)
        telemetry.record(.panelOpen)
        telemetry.record(.captureArea)
        telemetry.markActive()
        date += 86_400
        telemetry.record(.panelOpen)

        #expect(
            telemetry.preview(context: context)?.counts
                == ["panel.open": 3, "capture.area": 1, "app.active": 2])
    }

    @Test func countsADayWithNothingUsed() {
        var date = Date(timeIntervalSince1970: 1_763_200_000)
        let telemetry = Telemetry(defaults: makeDefaults(), sender: RecordingSender(), now: { date })
        telemetry.setEnabled(true)
        telemetry.markActive()
        telemetry.markActive()
        date += 86_400
        telemetry.markActive()
        #expect(telemetry.preview(context: context)?.counts == ["app.active": 2])
    }

    @Test func optingOutDeletesEverything() {
        let defaults = makeDefaults()
        let telemetry = Telemetry(defaults: defaults, sender: RecordingSender())
        telemetry.setEnabled(true)
        let first = telemetry.preview(context: context)?.install
        telemetry.record(.panelOpen)

        telemetry.setEnabled(false)
        telemetry.setEnabled(true)

        #expect(telemetry.preview(context: context)?.counts.isEmpty == true)
        // A new install ID, so the earlier reports can't be linked to the new ones.
        #expect(telemetry.preview(context: context)?.install != first)
    }

    @Test func sendsTheCountsSinceTheLastReportAndStartsAgain() async {
        var date = Date(timeIntervalSince1970: 1_763_200_000)
        let sender = RecordingSender()
        let telemetry = Telemetry(defaults: makeDefaults(), sender: sender, endpoint: endpoint, now: { date })
        telemetry.setEnabled(true)
        telemetry.record(.profileApply)

        #expect(await telemetry.sendIfDue(context: context))
        #expect(telemetry.preview(context: context)?.counts.isEmpty == true)

        date += 86_400
        telemetry.record(.panelOpen)
        #expect(await telemetry.sendIfDue(context: context))

        let reports = await sender.reports
        #expect(
            reports.map(\.counts) == [
                ["profile.apply": 1, "app.active": 1], ["panel.open": 1, "app.active": 1],
            ])
        #expect(reports.first?.context == context)
        #expect(reports[0].report != reports[1].report)
    }

    @Test func keepsCountingWhenSendingFailsAndResendsUnderTheSameID() async {
        var date = Date(timeIntervalSince1970: 1_763_200_000)
        let sender = RecordingSender()
        await sender.setSucceeds(false)
        let telemetry = Telemetry(defaults: makeDefaults(), sender: sender, endpoint: endpoint, now: { date })
        telemetry.setEnabled(true)
        telemetry.record(.profileApply)

        #expect(await !telemetry.sendIfDue(context: context))
        #expect(await !telemetry.sendIfDue(context: context))
        #expect(await sender.reports.count == 1)

        date += 86_400
        telemetry.record(.profileApply)
        await sender.setSucceeds(true)
        #expect(await telemetry.sendIfDue(context: context))

        let reports = await sender.reports
        #expect(reports.count == 2)
        #expect(reports[1].counts == ["profile.apply": 2, "app.active": 2])
        #expect(reports[0].report == reports[1].report)
    }

    @Test func sendNowDoesNotWait() async {
        let sender = RecordingSender()
        let telemetry = Telemetry(
            defaults: makeDefaults(), sender: sender, endpoint: endpoint,
            now: { Date(timeIntervalSince1970: 1_763_200_000) })
        telemetry.setEnabled(true)
        telemetry.record(.panelOpen)
        #expect(await telemetry.sendNow(context: context))
        telemetry.record(.panelOpen)
        #expect(await !telemetry.sendIfDue(context: context))
        #expect(await telemetry.sendNow(context: context))
        #expect(await sender.reports.count == 2)
    }

    @Test func keepsWhatWasCountedWhileSendingAndNeverSendsTwiceAtOnce() async {
        var telemetry: Telemetry!
        var overlapping: Bool?
        let sender = HookSender {
            telemetry.record(.panelOpen)
            overlapping = await telemetry.sendNow(context: context)
        }
        telemetry = Telemetry(defaults: makeDefaults(), sender: sender, endpoint: endpoint)
        telemetry.setEnabled(true)
        telemetry.record(.captureArea)

        #expect(await telemetry.sendNow(context: context))
        #expect(overlapping == false)
        #expect(telemetry.preview(context: context)?.counts == ["panel.open": 1])
    }

    @Test func takesNothingOffWhenTurnedOffAndOnWhileSending() async {
        var telemetry: Telemetry!
        let sender = HookSender {
            telemetry.setEnabled(false)
            telemetry.setEnabled(true)
            telemetry.record(.panelOpen)
        }
        telemetry = Telemetry(defaults: makeDefaults(), sender: sender, endpoint: endpoint)
        telemetry.setEnabled(true)
        telemetry.record(.panelOpen)

        #expect(await !telemetry.sendNow(context: context))
        #expect(telemetry.preview(context: context)?.counts == ["panel.open": 1, "app.active": 1])
    }

    @Test func asksOnANewInstallAndNotAfterAnAnswer() {
        let defaults = makeDefaults()
        let telemetry = Telemetry(defaults: defaults, sender: RecordingSender())
        #expect(telemetry.shouldAsk)
        telemetry.setEnabled(false)
        #expect(!telemetry.shouldAsk)
        // Opting out deletes the data, not the answer.
        #expect(!Telemetry(defaults: defaults, sender: RecordingSender()).shouldAsk)
    }

    @Test func asksAgainWhenTheConsentVersionGoesUp() {
        let defaults = makeDefaults()
        defaults.set(Telemetry.consentVersion - 1, forKey: "telemetry.askedVersion")
        #expect(Telemetry(defaults: defaults, sender: RecordingSender()).shouldAsk)
    }

    @Test func sendsNothingWithoutAnEndpoint() async {
        let sender = RecordingSender()
        let telemetry = Telemetry(defaults: makeDefaults(), sender: sender, endpoint: nil)
        telemetry.setEnabled(true)
        telemetry.record(.profileApply)

        #expect(await !telemetry.sendIfDue(context: context))
        #expect(await sender.reports.isEmpty)
    }

    @Test func theReportHoldsOnlyCountsAndBroadFacts() throws {
        let telemetry = Telemetry(defaults: makeDefaults(), sender: RecordingSender())
        telemetry.setEnabled(true)
        telemetry.record(.screenToggle)
        let json = try JSONEncoder().encode(telemetry.preview(context: context))
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(Set(object?.keys ?? [:].keys) == ["schema", "install", "report", "context", "counts"])
        let contextKeys = (object?["context"] as? [String: Any])?.keys.sorted()
        #expect(contextKeys == ["appVersion", "architecture", "language", "osVersion"])
    }

    @Test func countsTheEventWithItsDetail() {
        let telemetry = Telemetry(defaults: makeDefaults(), sender: RecordingSender())
        telemetry.setEnabled(true)
        telemetry.record(.panelTab, detail: "screens")
        telemetry.recordShortcut("captureArea")
        #expect(
            telemetry.preview(context: context)?.counts
                == [
                    "panel.tab.screens": 1, "source.shortcut": 1, "source.shortcut.captureArea": 1,
                    "app.active": 1,
                ])
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
        let sender = RecordingSender()
        let telemetry = Telemetry(defaults: makeDefaults(), sender: sender, endpoint: endpoint)
        telemetry.setEnabled(true)
        telemetry.record(.panelOpen)
        var setup = TelemetrySetup()
        setup.profiles = 3
        setup.hiddenSections = ["utilities"]

        await telemetry.sendIfDue(context: context, setup: setup)

        #expect(await sender.reports.first?.setup == setup)
    }
}
