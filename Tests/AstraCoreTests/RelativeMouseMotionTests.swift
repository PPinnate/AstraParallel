import XCTest
import CoreGraphics
@testable import AstraCore

final class RelativeMouseMotionTests: XCTestCase {
    func testSlowTrackpadMotionSurvivesIndividualPackets() {
        var motion = RelativeMouseMotion()
        var total = CGPoint.zero
        for _ in 0..<400 {
            let next = motion.consume(CGPoint(x: 0.25, y: -0.125))
            total.x += next.x; total.y += next.y
        }
        XCTAssertEqual(total, CGPoint(x: 100, y: -50))
    }

    func testCoalescingPreservesTravelAndDirectionReversals() {
        let deltas = [CGPoint(x: 0.75, y: -0.75), CGPoint(x: -0.25, y: 0.25),
                      CGPoint(x: 3, y: -3), CGPoint(x: -1.25, y: 1.25)]
        var individual = RelativeMouseMotion(), batched = RelativeMouseMotion()
        var delivered = CGPoint.zero, aggregate = CGPoint.zero
        for delta in deltas {
            let next = individual.consume(delta)
            delivered.x += next.x; delivered.y += next.y
            aggregate.x += delta.x; aggregate.y += delta.y
        }
        XCTAssertEqual(delivered, batched.consume(aggregate))
        XCTAssertEqual(individual.consume(CGPoint(x: 0.75, y: -0.75)),
                       batched.consume(CGPoint(x: 0.75, y: -0.75)))
    }

    func testCaptureResetAndInvalidMotionCannotLeakIntoNextSession() {
        var motion = RelativeMouseMotion()
        XCTAssertEqual(motion.consume(CGPoint(x: 0.25, y: -0.25)), .zero)
        motion.reset()
        XCTAssertEqual(motion.consume(CGPoint(x: 0.25, y: -0.25)), .zero)
        XCTAssertEqual(motion.consume(CGPoint(x: CGFloat.nan, y: 9)), .zero)
        XCTAssertEqual(motion.consume(CGPoint(x: CGFloat.infinity, y: 9)), .zero)
        XCTAssertEqual(motion.consume(CGPoint(x: CGFloat(Int32.max) * 2, y: 9)), .zero)
        XCTAssertEqual(motion.consume(CGPoint(x: 0.5, y: -0.5)), CGPoint(x: 1, y: -1))
    }
}
