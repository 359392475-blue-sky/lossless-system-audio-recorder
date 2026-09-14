import XCTest
@testable import LosslessSystemAudioRecorder

@MainActor
final class MemoryReferralJournal: ReferralOperationJournaling {
    var failSave = false
    var operations: [String: ReferralOperation] = [:]
    func read() -> [ReferralOperation] { Array(operations.values) }
    func save(_ operation: ReferralOperation) throws {
        if failSave { throw CocoaError(.fileWriteOutOfSpace) }
        operations[operation.id] = operation
    }
    func remove(_ id: String) { operations.removeValue(forKey: id) }
}

@MainActor
final class RecordingReferralStub: ReferralChecking {
    var begun: [String] = []
    var completed = Set<String>()
    var cancelled = Set<String>()
    var failCompletion = false
    var denyBegin = false
    func receipt(_ id: String? = nil) -> ReferralStatus {
        ReferralStatus(schema: 1, product: "lossless-system-audio-recorder", nonce: UUID().uuidString,
                       publicKey: "test", series: "3.2", issuedAt: 0, expiresAt: 60, referralCode: "test",
                       shareURL: URL(string: "https://example.invalid/r/test")!, qualifiedCount: 0,
                       requiredCount: 2, freeLimit: 5, usedTrials: completed.count, reservedTrials: 0,
                       unlocked: false, canRecord: true, pendingOperationIDs: [], operationID: id)
    }
    func status() async throws -> ReferralStatus { receipt() }
    func claim(ticket: String) async throws -> ReferralStatus { receipt() }
    func begin(operationID: String) async throws -> ReferralStatus {
        if denyBegin { throw PolicyFailure(message: "trial_exhausted") }
        begun.append(operationID); return receipt(operationID)
    }
    func complete(operationID: String) async throws -> ReferralStatus {
        if failCompletion { throw URLError(.notConnectedToInternet) }
        completed.insert(operationID); return receipt(operationID)
    }
    func cancel(operationID: String) async throws -> ReferralStatus {
        cancelled.insert(operationID); return receipt(operationID)
    }
}

@MainActor
func recordingTestReferrals() -> ReferralCoordinator {
    ReferralCoordinator(service: RecordingReferralStub(), journal: MemoryReferralJournal())
}

@MainActor
final class ReferralCoordinatorTests: XCTestCase {
    func testTwoChecksUseOneReservationAndCancelledCountdownDoesNotComplete() async throws {
        let service = RecordingReferralStub(), journal = MemoryReferralJournal()
        let coordinator = ReferralCoordinator(service: service, journal: journal)
        let id = try await coordinator.begin()
        try await coordinator.revalidate(id)
        XCTAssertEqual(service.begun, [id, id])
        coordinator.cancel(id)
        await coordinator.refresh()
        XCTAssertTrue(service.completed.isEmpty)
        XCTAssertTrue(service.cancelled.contains(id))
        XCTAssertTrue(journal.operations.isEmpty)
    }

    func testCompletionSurvivesOutageAndIsRetriedWithoutRecountingExport() async throws {
        let service = RecordingReferralStub(), journal = MemoryReferralJournal()
        let coordinator = ReferralCoordinator(service: service, journal: journal)
        let id = try await coordinator.begin()
        service.failCompletion = true
        coordinator.complete(id)
        await coordinator.refresh()
        XCTAssertEqual(journal.operations[id]?.state, .complete)
        service.failCompletion = false
        await coordinator.refresh()
        await coordinator.refresh()
        XCTAssertEqual(service.completed, [id])
        XCTAssertTrue(journal.operations.isEmpty)
    }

    func testRecoveryCancelsDeadProcessButDoesNotTouchLiveReservation() async throws {
        let service = RecordingReferralStub(), journal = MemoryReferralJournal()
        let dead = UUID().uuidString, live = UUID().uuidString
        try journal.save(ReferralOperation(id: dead, ownerPID: 10, state: .reserved))
        try journal.save(ReferralOperation(id: live, ownerPID: 20, state: .reserved))
        let coordinator = ReferralCoordinator(service: service, journal: journal, processAlive: { $0 == 20 })
        await coordinator.refresh()
        XCTAssertEqual(service.cancelled, [dead])
        XCTAssertNotNil(journal.operations[live])
        XCTAssertNil(journal.operations[dead])
    }

    func testDeniedStartCannotLeaveLocalActiveReservation() async throws {
        let service = RecordingReferralStub(), journal = MemoryReferralJournal()
        let coordinator = ReferralCoordinator(service: service, journal: journal)
        service.denyBegin = true
        do { _ = try await coordinator.begin(); XCTFail("quota must deny") } catch { }
        await coordinator.refresh()
        XCTAssertTrue(journal.operations.isEmpty)
        XCTAssertEqual(service.cancelled.count, 1)
    }

    func testCompletionWriteFailureBlocksNewBeginUntilTerminalIntentIsDurable() async throws {
        let service = RecordingReferralStub(), journal = MemoryReferralJournal()
        let coordinator = ReferralCoordinator(service: service, journal: journal)
        let id = try await coordinator.begin()
        try await coordinator.revalidate(id)
        journal.failSave = true
        coordinator.complete(id)
        do { _ = try await coordinator.begin(); XCTFail("must retain pending completion") } catch { }
        XCTAssertEqual(journal.operations[id]?.state, .recording)
        journal.failSave = false
        await coordinator.refresh()
        XCTAssertEqual(service.completed, [id])
        XCTAssertTrue(service.cancelled.isEmpty)
    }

    func testUnknownRecordingOutcomeIsNotRefundedOrCountedAsActivation() async throws {
        let service = RecordingReferralStub(), journal = MemoryReferralJournal()
        let id = UUID().uuidString
        try journal.save(ReferralOperation(id: id, ownerPID: 42, state: .recording))
        let coordinator = ReferralCoordinator(service: service, journal: journal, processAlive: { _ in false })
        await coordinator.refresh()
        XCTAssertTrue(service.completed.isEmpty)
        XCTAssertTrue(service.cancelled.isEmpty)
        XCTAssertNotNil(journal.operations[id])
        XCTAssertNotNil(coordinator.message)
    }

    func testJournalRoundTripAndInvalidID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ReferralOperationJournal(directory: directory)
        let operation = ReferralOperation(id: UUID().uuidString, ownerPID: 12, state: .complete)
        try journal.save(operation)
        XCTAssertEqual(try journal.read(), [operation])
        XCTAssertThrowsError(try journal.remove("../other"))
        try journal.remove(operation.id)
        XCTAssertTrue(try journal.read().isEmpty)
    }
}
