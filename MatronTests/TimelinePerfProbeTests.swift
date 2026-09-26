import XCTest
@testable import Matron

final class TimelinePerfProbeTests: XCTestCase {
    func test_steadyFrames_haveNoHitches() {
        var counter = HitchCounter()
        for frame in 0..<60 { counter.frame(at: Double(frame) / 60, duration: 1.0 / 60) }
        XCTAssertEqual(counter.frames, 59)
        XCTAssertEqual(counter.hitches, 0)
    }

    func test_aDroppedFrameGap_isOneHitch_ofTheLateTime() {
        var counter = HitchCounter()
        counter.frame(at: 0, duration: 1.0 / 60)
        counter.frame(at: 1.0 / 60, duration: 1.0 / 60)
        counter.frame(at: 4.0 / 60, duration: 1.0 / 60)
        XCTAssertEqual(counter.hitches, 1)
        XCTAssertEqual(counter.hitchSeconds, 2.0 / 60, accuracy: 1e-9)
    }

    func test_config_readsTheLaunchEnvironment() {
        XCTAssertEqual(TimelinePerfProbe.Config.fromEnvironment(["MATRON_PERF_AUTOSCROLL_PT": "25"]),
                       .init(pointsPerFrame: 25, duration: 15))
        XCTAssertEqual(TimelinePerfProbe.Config.fromEnvironment(["MATRON_PERF_AUTOSCROLL_PT": "150",
                                                                 "MATRON_PERF_DURATION_S": "5"]),
                       .init(pointsPerFrame: 150, duration: 5))
        XCTAssertNil(TimelinePerfProbe.Config.fromEnvironment([:]))
    }
}
