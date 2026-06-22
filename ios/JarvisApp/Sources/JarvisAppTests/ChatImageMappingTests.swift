import XCTest
import UIKit
@testable import Jarvis

@MainActor
final class ChatImageMappingTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatImageMappingTests-\(UUID().uuidString)", isDirectory: true)
        ChatImageStore.shared = ChatImageStore(baseURL: tmpDir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        ChatImageStore.shared = ChatImageStore(baseURL: ChatImageStore.defaultBaseURL())
    }

    private func row(attachmentsJSON: String) -> StoredMessage {
        StoredMessage(id: "r1", dir: .in_, seq: 1, text: "", attachmentsJSON: attachmentsJSON,
                      contextJSON: nil, status: .delivered, failureReason: nil,
                      ts: 1_700_000_000_000, serverTS: nil, createdAt: 1_700_000_000_000,
                      agentId: "jarvis")
    }

    func test_refImage_buildsThumbnailBubbleWithSHA() throws {
        let sha = ChatImageStore.shared.write(jpeg())
        let json = "[{\"kind\":\"image\",\"name\":\"p.jpg\",\"mime_type\":\"image/jpeg\",\"byte_size\":3,\"sha256\":\"\(sha)\"}]"
        let msgs = WebSocketClientV2.toChatMessage(row(attachmentsJSON: json))
        XCTAssertEqual(msgs.count, 1)
        guard case .image = msgs[0].content else { return XCTFail("expected image content") }
        XCTAssertEqual(msgs[0].imageSHA, sha)
    }

    func test_legacyInlineImage_stillRenders() throws {
        let b64 = jpeg().base64EncodedString()
        let json = "[{\"id\":\"a\",\"kind\":\"image\",\"name\":\"p.jpg\",\"mime_type\":\"image/jpeg\",\"byte_size\":3,\"bytes_base64\":\"\(b64)\",\"remote_id\":null}]"
        let msgs = WebSocketClientV2.toChatMessage(row(attachmentsJSON: json))
        guard case .image = msgs[0].content else { return XCTFail("expected image content") }
        XCTAssertNil(msgs[0].imageSHA)   // legacy → no store ref yet
    }

    func test_fileRef_buildsFileBubble() throws {
        let json = "[{\"kind\":\"file\",\"name\":\"doc.pdf\",\"mime_type\":\"application/pdf\",\"byte_size\":10,\"sha256\":\"abc\"}]"
        let msgs = WebSocketClientV2.toChatMessage(row(attachmentsJSON: json))
        guard case .file = msgs[0].content else { return XCTFail("expected file content") }
    }

    func test_toChatMessage_buildsActionContent_fromActionsJSON() throws {
        let actionsJSON = "[{\"id\":\"yes\",\"label\":\"Yes\",\"style\":\"primary\"},{\"id\":\"no\",\"label\":\"No\"}]"
        let row = StoredMessage(id: "q1", dir: .in_, seq: 1, text: "Pick", attachmentsJSON: nil,
                                contextJSON: nil, status: .delivered, failureReason: nil,
                                ts: 1_700_000_000_000, serverTS: nil, createdAt: 1_700_000_000_000,
                                agentId: "jarvis", actionsJSON: actionsJSON, actionChoice: "yes")
        let msgs = WebSocketClientV2.toChatMessage(row)
        XCTAssertEqual(msgs.count, 1)
        guard case .action(let info) = msgs[0].content else { return XCTFail("expected .action") }
        XCTAssertEqual(info.text, "Pick")
        XCTAssertEqual(info.buttons.map(\.id), ["yes", "no"])
        XCTAssertTrue(info.answered)
        XCTAssertEqual(info.selectedId, "yes")
    }

    func test_toChatMessage_buildsWorkoutPlan_fromWorkoutPlanJSON() throws {
        let plan = WorkoutPlan(
            workoutId: "w1", dayName: "День ног", week: 2, intensityLabel: "высокая",
            exercises: [ExercisePlan(exerciseSlug: "squat", targetSets: 5, targetReps: "5", targetRir: 2, restSec: 180, notes: nil)],
            imageManifest: [])
        let json = String(data: try JSONEncoder().encode(plan), encoding: .utf8)!

        let row = StoredMessage(id: "w1", dir: .in_, seq: nil, text: "🏋️ День ног · высокая · 1 упр.",
                                attachmentsJSON: nil, contextJSON: nil, status: .delivered, failureReason: nil,
                                ts: 1_700_000_000_000, serverTS: nil, createdAt: 1_700_000_000_000,
                                agentId: "payne", actionsJSON: nil, actionChoice: nil, workoutPlanJSON: json)
        let msgs = WebSocketClientV2.toChatMessage(row)
        XCTAssertEqual(msgs.count, 1)
        guard case .workoutPlan(let info) = msgs[0].content else { return XCTFail("expected .workoutPlan") }
        XCTAssertEqual(info.plan, plan)
        XCTAssertFalse(info.done)
        XCTAssertNil(info.outcome)

        var doneRow = row
        doneRow.actionChoice = "completed"
        guard case .workoutPlan(let doneInfo) = WebSocketClientV2.toChatMessage(doneRow)[0].content
        else { return XCTFail("expected .workoutPlan") }
        XCTAssertTrue(doneInfo.done)
        XCTAssertEqual(doneInfo.outcome, "completed")

        var badRow = row
        badRow.workoutPlanJSON = "{not json"
        guard case .text = WebSocketClientV2.toChatMessage(badRow)[0].content
        else { return XCTFail("garbage workoutPlanJSON should fall through to text") }
    }

    private func jpeg() -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return r.image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
            .jpegData(compressionQuality: 0.8)!
    }
}
