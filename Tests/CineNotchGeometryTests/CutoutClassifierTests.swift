import XCTest
@testable import CineNotchGeometry

/// Synthetic screens. The notched values are close to what notched MacBooks report; the island
/// values are made up, varied on purpose: no PROLED XDR machine has been measured yet.
private func screen(width: CGFloat, height: CGFloat, inset: CGFloat, reserved: CGFloat,
                    housing: CGFloat? = nil, auxHeight: CGFloat? = nil, dock: CGFloat = 0) -> ScreenMeasurements {
    let frame = CGRect(x: 0, y: 0, width: width, height: height)
    let visible = CGRect(x: 0, y: dock, width: width, height: height - reserved - dock)
    var left: CGRect?, right: CGRect?
    if let housing {
        let h = auxHeight ?? inset
        let side = (width - housing) / 2
        // Uneven halves, as on real notched Macs.
        left = CGRect(x: 0, y: height - h, width: (side + 6).rounded(.down), height: h)
        right = CGRect(x: width - (side - 6).rounded(.up), y: height - h, width: (side - 6).rounded(.up), height: h)
    }
    return ScreenMeasurements(frame: frame, visibleFrame: visible, safeAreaTop: inset,
                              auxiliaryTopLeft: left, auxiliaryTopRight: right)
}

final class CutoutClassifierTests: XCTestCase {
    // MARK: Classic notch

    func testNotchedAir13() {
        let g = CutoutClassifier.classify(screen(width: 1470, height: 956, inset: 32, reserved: 33, housing: 185, dock: 70))
        XCTAssertEqual(g.kind, .notch)
        XCTAssertEqual(g.housing, CGSize(width: 185, height: 32))
        XCTAssertEqual(g.topGap, 0)
        XCTAssertEqual(g.gapSource, GapSource.none)
    }

    func testNotchedPro14() {
        let g = CutoutClassifier.classify(screen(width: 1512, height: 982, inset: 38, reserved: 38, housing: 200))
        XCTAssertEqual(g.kind, .notch)
        XCTAssertEqual(g.housing, CGSize(width: 200, height: 38))
        XCTAssertEqual(g.topGap, 0)
    }

    func testNotchedPro14MoreSpace() {
        // Scaled for more space: more points across, the notch takes the same share.
        let g = CutoutClassifier.classify(screen(width: 1800, height: 1169, inset: 38, reserved: 38, housing: 238))
        XCTAssertEqual(g.kind, .notch)
    }

    func testNotchedPro14NarrowHousing() {
        // A notch at the small end of what notched Macs report (~180 pt on 1512).
        let g = CutoutClassifier.classify(screen(width: 1512, height: 982, inset: 32, reserved: 33, housing: 180))
        XCTAssertEqual(g.kind, .notch)
    }

    func testNotchedPro16() {
        let g = CutoutClassifier.classify(screen(width: 1728, height: 1117, inset: 38, reserved: 38, housing: 200))
        XCTAssertEqual(g.kind, .notch)
        XCTAssertEqual(g.housing, CGSize(width: 200, height: 38))
    }

    func testNotchedPro16LargerText() {
        // Scaled for larger text: fewer points, the same notch.
        let g = CutoutClassifier.classify(screen(width: 1312, height: 848, inset: 38, reserved: 38, housing: 152))
        XCTAssertEqual(g.kind, .notch)
    }

    func testNotchWithHiddenMenuBar() {
        // The menu bar hides itself (or a full screen app): no reserved strip; the auxiliary
        // areas' height stands in for it and the inset still matches.
        let g = CutoutClassifier.classify(screen(width: 1512, height: 982, inset: 38, reserved: 0, housing: 200))
        XCTAssertEqual(g.kind, .notch)
    }

    func testNotchWithoutAuxiliaryAreas() {
        // No shipped Mac reports an inset without auxiliary areas; keep the classic notch
        // with the fallback width rather than a screen-wide one.
        let g = CutoutClassifier.classify(screen(width: 1512, height: 982, inset: 38, reserved: 38))
        XCTAssertEqual(g.kind, .notch)
        XCTAssertEqual(g.housing, CGSize(width: CutoutClassifier.fallbackNotch.width, height: 38))
        XCTAssertTrue(g.widthAssumed)
    }

    // MARK: No cutout

    func testExternalDisplay() {
        let g = CutoutClassifier.classify(screen(width: 2560, height: 1440, inset: 0, reserved: 25))
        XCTAssertEqual(g.kind, CutoutKind.none)
        XCTAssertNil(g.housing)
    }

    func testIMac() {
        let g = CutoutClassifier.classify(screen(width: 2240, height: 1260, inset: 0, reserved: 24, dock: 80))
        XCTAssertEqual(g.kind, CutoutKind.none)
    }

    func testNoCutoutHiddenMenuBar() {
        let g = CutoutClassifier.classify(screen(width: 1440, height: 900, inset: 0, reserved: 0))
        XCTAssertEqual(g.kind, CutoutKind.none)
    }

    func testAuxiliaryAreasWithoutCentralGap() {
        // Auxiliary areas that cover the whole width leave no housing.
        var m = screen(width: 1440, height: 900, inset: 0, reserved: 24)
        m.auxiliaryTopLeft = CGRect(x: 0, y: 876, width: 720, height: 24)
        m.auxiliaryTopRight = CGRect(x: 720, y: 876, width: 720, height: 24)
        XCTAssertEqual(CutoutClassifier.classify(m).kind, CutoutKind.none)
    }

    func testSubPointInsetIsNoise() {
        let g = CutoutClassifier.classify(screen(width: 1440, height: 900, inset: 0.3, reserved: 24))
        XCTAssertEqual(g.kind, CutoutKind.none)
    }

    // MARK: Camera island

    func testIslandInsetIsGap16() {
        // The inset is only the gap above the pill; the pill hangs into the menu bar strip.
        let g = CutoutClassifier.classify(screen(width: 1736, height: 1130, inset: 8.5, reserved: 40, housing: 59))
        XCTAssertEqual(g.kind, .island)
        XCTAssertEqual(g.topGap, 8.5)
        XCTAssertEqual(g.gapSource, .inset)
        XCTAssertEqual(g.housing?.width, 59)
        XCTAssertEqual(g.housing?.height, 31.5)
        XCTAssertFalse(g.widthAssumed)
    }

    func testIslandInsetIsGap14() {
        let g = CutoutClassifier.classify(screen(width: 1512, height: 990, inset: 6, reserved: 36, housing: 48))
        XCTAssertEqual(g.kind, .island)
        XCTAssertEqual(g.topGap, 6)
        XCTAssertEqual(g.housing, CGSize(width: 48, height: 30))
    }

    func testIslandInsetIsGapWithTallerAuxiliaryAreas() {
        // The auxiliary areas reach lower than the menu bar strip: the pill ends there.
        let g = CutoutClassifier.classify(screen(width: 1512, height: 990, inset: 10, reserved: 32, housing: 64, auxHeight: 44))
        XCTAssertEqual(g.kind, .island)
        XCTAssertEqual(g.topGap, 10)
        XCTAssertEqual(g.housing?.height, 34)
    }

    func testIslandInsetIsGapWideHousing() {
        // A short inset under a tall menu bar means a floating housing, whatever its width.
        let g = CutoutClassifier.classify(screen(width: 1512, height: 982, inset: 9, reserved: 38, housing: 200))
        XCTAssertEqual(g.kind, .island)
        XCTAssertEqual(g.topGap, 9)
    }

    func testIslandInsetIsGapWithoutAuxiliaryAreas() {
        let g = CutoutClassifier.classify(screen(width: 1736, height: 1130, inset: 8, reserved: 40))
        XCTAssertEqual(g.kind, .island)
        XCTAssertEqual(g.topGap, 8)
        XCTAssertEqual(g.housing?.height, 32)
        XCTAssertEqual(g.housing?.width, 64)
        XCTAssertTrue(g.widthAssumed)
    }

    func testIslandInsetCoversPill16() {
        // The inset covers gap and pill; the housing is compact, so it's not a notch. The gap
        // isn't measured and is assumed.
        let g = CutoutClassifier.classify(screen(width: 1736, height: 1130, inset: 40, reserved: 40, housing: 59))
        XCTAssertEqual(g.kind, .island)
        XCTAssertEqual(g.gapSource, .assumed)
        XCTAssertEqual(g.topGap, 8)
        XCTAssertEqual(g.housing, CGSize(width: 59, height: 32))
        XCTAssertGreaterThan(g.topGap, 0)
    }

    func testIslandInsetCoversPill14Small() {
        let g = CutoutClassifier.classify(screen(width: 1512, height: 990, inset: 34, reserved: 36, housing: 72))
        XCTAssertEqual(g.kind, .island)
        XCTAssertEqual(g.depth, 34)
        XCTAssertEqual(g.housing?.width, 72)
    }

    func testIslandNoInsetButCentralHousing() {
        // No top inset, yet the auxiliary areas leave a housing in the middle: an island, so
        // the menu bar pill isn't drawn over the camera.
        let g = CutoutClassifier.classify(screen(width: 1736, height: 1130, inset: 0, reserved: 40, housing: 66, auxHeight: 38))
        XCTAssertEqual(g.kind, .island)
        XCTAssertEqual(g.gapSource, .assumed)
        XCTAssertEqual(g.depth, 38)
        XCTAssertEqual(g.housing?.width, 66)
        XCTAssertGreaterThan(g.topGap, 0)
    }

    func testIslandNoInsetZeroHeightAuxiliaryAreas() {
        // Auxiliary areas without height: the menu bar strip gives the depth.
        let g = CutoutClassifier.classify(screen(width: 1736, height: 1130, inset: 0, reserved: 40, housing: 66, auxHeight: 0))
        XCTAssertEqual(g.kind, .island)
        XCTAssertEqual(g.depth, 40)
    }

    func testIslandNeverFlushWithoutGap() {
        for m in [screen(width: 1736, height: 1130, inset: 8.5, reserved: 40, housing: 59),
                  screen(width: 1736, height: 1130, inset: 40, reserved: 40, housing: 59),
                  screen(width: 1736, height: 1130, inset: 0, reserved: 40, housing: 59, auxHeight: 40)] {
            let g = CutoutClassifier.classify(m)
            XCTAssertEqual(g.kind, .island)
            XCTAssertGreaterThan(g.topGap, 0)
            XCTAssertGreaterThanOrEqual(g.housing?.height ?? 0, CutoutClassifier.minPillHeight)
        }
    }

    // MARK: Edges

    func testBorderlineCompactPrefersNotch() {
        // Just above the compact share (0.075 of the width) with a full inset: classic notch.
        let g = CutoutClassifier.classify(screen(width: 1512, height: 982, inset: 38, reserved: 38, housing: 114))
        XCTAssertEqual(g.kind, .notch)
    }

    func testBorderlineInsetPrefersNotch() {
        // An inset at 60% of the strip is not gap-like: classic notch.
        let g = CutoutClassifier.classify(screen(width: 1512, height: 982, inset: 23, reserved: 38, housing: 200))
        XCTAssertEqual(g.kind, .notch)
    }

    func testOneAuxiliaryAreaIsNoHousing() {
        var m = screen(width: 1512, height: 982, inset: 0, reserved: 38)
        m.auxiliaryTopLeft = CGRect(x: 0, y: 944, width: 600, height: 38)
        XCTAssertNil(m.auxiliaryGapWidth)
        XCTAssertEqual(CutoutClassifier.classify(m).kind, CutoutKind.none)
    }

    func testPreferredScreen() {
        XCTAssertEqual(CutoutClassifier.preferredScreen([CutoutKind.none, .notch]), 1)
        XCTAssertEqual(CutoutClassifier.preferredScreen([CutoutKind.none, .island, .notch]), 1)
        XCTAssertEqual(CutoutClassifier.preferredScreen([CutoutKind.none, .none]), 0)
        XCTAssertNil(CutoutClassifier.preferredScreen([]))
    }

    // MARK: Forced layouts

    func testForcedNotchKeepsRealNotch() {
        let m = screen(width: 1470, height: 956, inset: 32, reserved: 33, housing: 185)
        let measured = CutoutClassifier.classify(m)
        XCTAssertEqual(CutoutClassifier.forced(.notch, measured: measured, measurements: m), measured)
    }

    func testForcedNotchOnPlainScreenUsesDebugHousing() {
        let m = screen(width: 2560, height: 1440, inset: 0, reserved: 25)
        let g = CutoutClassifier.forced(.notch, measured: CutoutClassifier.classify(m), measurements: m)
        XCTAssertEqual(g.kind, .notch)
        XCTAssertEqual(g.housing, CGSize(width: 185, height: 32))
        XCTAssertEqual(g.topGap, 0)
    }

    func testForcedIslandOnNotchedAir() {
        let m = screen(width: 1470, height: 956, inset: 32, reserved: 33, housing: 185)
        let g = CutoutClassifier.forced(.island, measured: CutoutClassifier.classify(m), measurements: m)
        XCTAssertEqual(g.kind, .island)
        XCTAssertEqual(g.gapSource, .debug)
        XCTAssertEqual(g.topGap, 7)
        XCTAssertEqual(g.housing, CGSize(width: 52, height: 26))
    }

    func testForcedNone() {
        let m = screen(width: 1470, height: 956, inset: 32, reserved: 33, housing: 185)
        let g = CutoutClassifier.forced(.none, measured: CutoutClassifier.classify(m), measurements: m)
        XCTAssertEqual(g.kind, CutoutKind.none)
        XCTAssertNil(g.housing)
    }
}

final class SystemIslandDetectorTests: XCTestCase {
    /// A 1736 x 1130 screen as the window list sees it (y down).
    private let screenRect = CGRect(x: 0, y: 0, width: 1736, height: 1130)

    private func detect(_ windows: [WindowSample]) -> SystemIslandOccupancy? {
        SystemIslandDetector.occupancy(windows: windows, screen: screenRect, strip: 40, idleHousingWidth: 59, ownPID: 42)
    }

    func testExpandedIslandWindow() {
        let w = WindowSample(bounds: CGRect(x: 868 - 180, y: 6, width: 360, height: 84), layer: 25, ownerPID: 7)
        let o = detect([w])
        XCTAssertEqual(o?.width, 360)
        XCTAssertEqual(o?.depth, 90)
    }

    func testIgnoresOwnWindowsAndNormalWindows() {
        let mine = WindowSample(bounds: CGRect(x: 868 - 180, y: 0, width: 360, height: 84), layer: 26, ownerPID: 42)
        let normal = WindowSample(bounds: CGRect(x: 868 - 180, y: 0, width: 360, height: 84), layer: 0, ownerPID: 7)
        XCTAssertNil(detect([mine, normal]))
    }

    func testIgnoresMenuBarAndOffCenterAndLowWindows() {
        let menuBar = WindowSample(bounds: CGRect(x: 0, y: 0, width: 1736, height: 40), layer: 24, ownerPID: 7)
        let statusItem = WindowSample(bounds: CGRect(x: 1400, y: 0, width: 80, height: 40), layer: 25, ownerPID: 8)
        let belowMenuBar = WindowSample(bounds: CGRect(x: 868 - 200, y: 40, width: 400, height: 300), layer: 3, ownerPID: 9)
        let idleSized = WindowSample(bounds: CGRect(x: 868 - 29, y: 8, width: 58, height: 31), layer: 25, ownerPID: 7)
        XCTAssertNil(detect([menuBar, statusItem, belowMenuBar, idleSized]))
    }

    func testAuxiliaryAreasWidening() {
        let idle = CutoutClassifier.classify(screen(width: 1736, height: 1130, inset: 8.5, reserved: 40, housing: 59))
        let expanded = screen(width: 1736, height: 1130, inset: 8.5, reserved: 40, housing: 300)
        let o = SystemIslandDetector.occupancy(idle: idle, current: expanded)
        XCTAssertEqual(o?.width, 300)
        XCTAssertNil(SystemIslandDetector.occupancy(idle: idle, current: screen(width: 1736, height: 1130, inset: 8.5, reserved: 40, housing: 59)))
    }

    func testMerge() {
        let a = SystemIslandOccupancy(width: 200, depth: 60, source: "a")
        let b = SystemIslandOccupancy(width: 300, depth: 40, source: "b")
        XCTAssertEqual(SystemIslandDetector.merge(a, b), SystemIslandOccupancy(width: 300, depth: 60, source: "b"))
        XCTAssertEqual(SystemIslandDetector.merge(nil, a), a)
    }
}

final class CameraPlacementTests: XCTestCase {
    func testClassicUnchanged() {
        let notch = CutoutClassifier.classify(screen(width: 1512, height: 982, inset: 38, reserved: 38, housing: 200))
        XCTAssertEqual(CameraPlacement.normalizedY(classic: -0.04, geometry: notch, menuBarHeight: 38, screenHeight: 982), -0.04)
        let none = CutoutClassifier.classify(screen(width: 2560, height: 1440, inset: 0, reserved: 25))
        XCTAssertEqual(CameraPlacement.normalizedY(classic: -0.04, geometry: none, menuBarHeight: 25, screenHeight: 1440), -0.04)
    }

    func testIslandLensLower() {
        let island = CutoutClassifier.classify(screen(width: 1736, height: 1130, inset: 8.5, reserved: 40, housing: 59))
        let y = CameraPlacement.normalizedY(classic: -0.04, geometry: island, menuBarHeight: 40, screenHeight: 1130)
        // Lens at 8.5 + 31.5 / 2 = 24.25 pt, menu bar middle at 20 pt.
        XCTAssertEqual(y, -0.04 + 4.25 / 1130, accuracy: 1e-9)
        XCTAssertLessThan(abs(y + 0.04), 0.01)
    }
}
