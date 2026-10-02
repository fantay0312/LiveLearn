import AppKit
import Testing
@testable import LiveLearnApp

@MainActor
struct BrandGeometryTests {
    @Test func theMarkFitsEveryNativeIconSizeAndLeavesRoomForItsNucleus() {
        for side in [16.0, 18, 32, 64, 128, 512, 1024] {
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            for index in LLBrandGeometry.parts.indices {
                let path = LLBrandGeometry.path(for: index, in: rect)
                #expect(rect.contains(path.boundingBoxOfPath))
                #expect(!path.contains(CGPoint(x: side / 2, y: side / 2)))
                #expect(!path.isEmpty)
            }
            #expect(rect.contains(LLBrandGeometry.nucleus(in: rect).boundingBoxOfPath))
        }
    }

    @Test func menuTemplatesKeepTheirNativeSizeAndDistinctState() {
        #expect(LLBrandAssets.menuBarIdle.isTemplate)
        #expect(LLBrandAssets.menuBarActive.isTemplate)
        #expect(LLBrandAssets.menuBarIdle.size == NSSize(width: 18, height: 18))
        #expect(LLBrandAssets.menuBarActive.size == NSSize(width: 18, height: 18))
        let rect = CGRect(x: -1, y: -1, width: 20, height: 20)
        let idle = LLBrandGeometry.nucleus(in: rect, active: false).boundingBoxOfPath
        let active = LLBrandGeometry.nucleus(in: rect, active: true).boundingBoxOfPath
        #expect(active.height > idle.height * 2)
        for index in LLBrandGeometry.parts.indices {
            #expect(CGRect(x: 0, y: 0, width: 18, height: 18).contains(LLBrandGeometry.path(for: index, in: rect).boundingBoxOfPath))
        }
    }
}
