import AppKit
import Combine
import SceneKit
import simd
import OSLog
import SwiftUI

/// Native GPU geometry with attributed planetary material maps; never a background image.
@MainActor
final class ExplorationWorldModel {
    let scene = SCNScene()
    let camera = SCNNode()
    private var moving: [(SCNNode, Double, Double)] = []
    private var floating: [(SCNNode, CGFloat, Double)] = []

    init(world: ExperienceTheme, animated: Bool) {
        scene.background.contents = Self.color(world == .stellar ? 0x09121F : 0xF3EFDF)
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = world == .stellar
        camera.camera?.orthographicScale = 4.6
        camera.camera?.fieldOfView = 51
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 160
        camera.camera?.wantsHDR = false
        camera.camera?.wantsDepthOfField = false
        camera.position = world == .stellar ? Self.v(0, 0, 18) : Self.v(0, 7, 23)
        camera.look(at: world == .stellar ? Self.v(0, 0, 0) : Self.v(0, 2, -24))
        if world == .wilds {
            scene.fogStartDistance = 24
            scene.fogEndDistance = 115
            scene.fogColor = Self.color(0xF3EFDF)
        }
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = world == .stellar ? 130 : 600
        ambient.light?.color = Self.color(world == .stellar ? 0x9EBDE7 : 0xFFF4D6)
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight(); sun.light?.type = .directional
        sun.light?.intensity = world == .stellar ? 1100 : 950
        sun.light?.castsShadow = false
        sun.eulerAngles = Self.v(-0.5, -0.7, 0)
        scene.rootNode.addChildNode(sun)
        if world == .stellar { buildStellar() } else { buildWilds(); applyComicShading() }
        if animated {
            for (node, speed, _) in moving {
                node.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: .pi * 2 / speed)))
            }
            for (node, _, duration) in floating {
                node.runAction(.repeatForever(.sequence([.moveBy(x: 0, y: 0.15, z: 0, duration: duration),
                                                          .moveBy(x: 0, y: -0.15, z: 0, duration: duration)])))
            }
        }
        scene.isPaused = !animated
    }

    func setPose(time: Double) {
        for (node, speed, start) in moving { node.eulerAngles.y = CGFloat(start + time * speed) }
        for (node, base, duration) in floating { node.position.y = base + CGFloat(sin(time / duration) * 0.15) }
    }

    var triangleCount: Int {
        var count = 0
        scene.rootNode.enumerateChildNodes { node, _ in
            count += node.geometry?.elements.filter { $0.primitiveType == .triangles || $0.primitiveType == .triangleStrip }.reduce(0) { $0 + $1.primitiveCount } ?? 0
        }
        return count
    }

    var imageTextureCount: Int {
        var count = 0
        scene.rootNode.enumerateChildNodes { node, _ in
            for material in node.geometry?.materials ?? [] {
                for property in [material.diffuse, material.normal, material.emission, material.multiply,
                                 material.roughness, material.metalness, material.ambientOcclusion] {
                    if property.contents is NSImage || property.contents is URL || property.contents is String { count += 1 }
                }
            }
        }
        return count
    }

    private func buildStellar() {
        let earthGeometry = SCNSphere(radius: 1.73)
        earthGeometry.segmentCount = 128
        let earthMaterial = Self.material(0xFFFFFF)
        earthMaterial.lightingModel = .blinn
        earthMaterial.shininess = 42
        WorldAssets.map(earthMaterial.diffuse, "earth-day.jpg")
        WorldAssets.map(earthMaterial.normal, "earth-normal.tif")
        WorldAssets.map(earthMaterial.specular, "earth-specular.tif")
        WorldAssets.map(earthMaterial.emission, "earth-night.jpg")
        earthMaterial.normal.intensity = 0.45
        earthMaterial.shaderModifiers = [.surface: """
        #pragma body
        float day = smoothstep(-0.1, 0.4, dot(normalize(_surface.normal), normalize(float3(0.5, 0.45, 0.75))));
        _surface.emission.rgb *= (1.0 - day) * 0.7;
        """]
        earthGeometry.materials = [earthMaterial]
        let lowEarth = SCNSphere(radius: 1.73); lowEarth.segmentCount = 64; lowEarth.materials = [earthMaterial]
        earthGeometry.levelsOfDetail = [SCNLevelOfDetail(geometry: lowEarth, screenSpaceRadius: 140)]
        let planet = SCNNode(geometry: earthGeometry)
        planet.position = Self.v(3.0, 0.25, 0)
        planet.scale.y = 0.996647
        planet.eulerAngles = Self.v(0, -1.3, 0.4091)
        mark(planet, destination: .home)
        scene.rootNode.addChildNode(planet)
        moving.append((planet, 0.025, -1.3))

        let clouds = sphere(radius: 1.745, color: 0xFFFFFF, segments: 64)
        clouds.position = planet.position
        clouds.eulerAngles = planet.eulerAngles
        let cloudMaterial = clouds.geometry!.firstMaterial!
        WorldAssets.map(cloudMaterial.diffuse, "earth-clouds.jpg")
        cloudMaterial.writesToDepthBuffer = false
        cloudMaterial.blendMode = .alpha
        cloudMaterial.transparency = 0.72
        cloudMaterial.transparencyMode = .rgbZero
        cloudMaterial.shaderModifiers = [.surface: """
        #pragma transparent
        #pragma body
        float coverage = smoothstep(0.15, 0.85, _surface.diffuse.r);
        _surface.transparent = float4(float3(1.0 - coverage), 1.0);
        _surface.diffuse.rgb = float3(0.94, 0.97, 1.0);
        """]
        scene.rootNode.addChildNode(clouds)
        moving.append((clouds, 0.028, -1.3))

        let atmosphere = sphere(radius: 1.775, color: 0x5BADED, segments: 64)
        atmosphere.position = planet.position
        let air = atmosphere.geometry!.firstMaterial!
        air.lightingModel = .constant
        air.blendMode = .add; air.writesToDepthBuffer = false
        air.shaderModifiers = [.fragment: """
        #pragma transparent
        #pragma body
        float rim = pow(1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view))), 4.5);
        _output.color = float4(float3(0.18, 0.47, 0.85) * rim, rim * 0.48);
        """]
        scene.rootNode.addChildNode(atmosphere)

        let orbit = SCNNode()
        orbit.position = planet.position
        orbit.eulerAngles = Self.v(0.9, 0, -0.2)
        scene.rootNode.addChildNode(orbit)
        let ring = SCNTorus(ringRadius: 2.5, pipeRadius: 0.007)
        ring.ringSegmentCount = 80; ring.pipeSegmentCount = 4
        ring.materials = [Self.material(0x7795AC, constant: true)]
        orbit.addChildNode(SCNNode(geometry: ring))
        let moonOrbit = SCNNode()
        orbit.addChildNode(moonOrbit)
        let moon = sphere(radius: 0.27, color: 0xFFFFFF, segments: 32)
        WorldAssets.map(moon.geometry!.firstMaterial!.diffuse, "moon.jpg")
        moon.position.x = 2.5
        mark(moon, destination: .records)
        moonOrbit.addChildNode(moon)
        moving.append((moonOrbit, 0.075, 0))

        let vocabulary = sphere(radius: 0.44, color: 0xFFFFFF, segments: 40)
        WorldAssets.map(vocabulary.geometry!.firstMaterial!.diffuse, "mars.jpg")
        vocabulary.position = Self.v(4.5, -2.1, 0.4)
        mark(vocabulary, destination: .vocabulary)
        scene.rootNode.addChildNode(vocabulary)
        floating.append((vocabulary, vocabulary.position.y, 7))
        let settings = sphere(radius: 0.31, color: 0xFFFFFF, segments: 32)
        WorldAssets.map(settings.geometry!.firstMaterial!.diffuse, "saturn.jpg")
        settings.position = Self.v(1.05, 2.7, -0.4)
        settings.eulerAngles.z = 0.35
        var ringVertices: [SCNVector3] = [], ringUV: [CGPoint] = [], ringIndices: [Int32] = []
        for i in 0...96 {
            let angle = Double(i) / 96 * .pi * 2
            for (j, radius) in [0.40, 0.66].enumerated() {
                ringVertices.append(Self.v(cos(angle) * radius, 0, sin(angle) * radius))
                ringUV.append(CGPoint(x: Double(j), y: 0.5))
            }
            if i < 96 { let a = Int32(i * 2); ringIndices.append(contentsOf: [a, a + 2, a + 1, a + 1, a + 2, a + 3]) }
        }
        let ringGeometry = SCNGeometry(sources: [SCNGeometrySource(vertices: ringVertices),
                                                SCNGeometrySource(normals: Array(repeating: SCNVector3(0, 1, 0), count: ringVertices.count)),
                                                SCNGeometrySource(textureCoordinates: ringUV)],
                                         elements: [SCNGeometryElement(indices: ringIndices, primitiveType: .triangles)])
        let rings = Self.material(0xFFFFFF)
        WorldAssets.map(rings.diffuse, "saturn-rings.png")
        rings.isDoubleSided = true; rings.writesToDepthBuffer = false
        rings.transparencyMode = .aOne
        ringGeometry.materials = [rings]
        let ringNode = SCNNode(geometry: ringGeometry)
        ringNode.eulerAngles.x = 0.4
        settings.addChildNode(ringNode)
        mark(settings, destination: .settings)
        scene.rootNode.addChildNode(settings)
        floating.append((settings, settings.position.y, 9))

        for group in 0..<3 {
            let points = (0..<42).map { i -> SCNVector3 in
                let seed = Double(i + group * 43)
                return Self.v(Self.fraction(sin(seed * 78.233 + 1) * 43758.5453) * 17 - 8.5,
                              Self.fraction(sin(seed * 37.719 + 3) * 23421.631) * 11 - 5.5, -7)
            }
            let field = pointCloud(points, color: 0xC1D6ED, size: group == 0 ? 2.0 : 1.1)
            field.opacity = 0.45
            field.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.85, duration: 3 + Double(group)),
                                                       .fadeOpacity(to: 0.35, duration: 3 + Double(group))])))
            scene.rootNode.addChildNode(field)
        }
    }

    private func buildWilds() {
        let landscape = WildernessLandscape.make()
        scene.rootNode.addChildNode(landscape.root)
        for (index, cloud) in landscape.clouds.enumerated() {
            let distance = 7.0 + Double(index)
            cloud.runAction(.repeatForever(.sequence([.moveBy(x: distance, y: 0, z: 0, duration: 40),
                                                        .moveBy(x: -distance, y: 0, z: 0, duration: 40)])))
        }
    }

    private func sphere(radius: CGFloat, color: UInt32, segments: Int) -> SCNNode {
        let geometry = SCNSphere(radius: radius); geometry.segmentCount = segments
        geometry.materials = [Self.material(color)]
        return SCNNode(geometry: geometry)
    }

    private func box(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, color: UInt32) -> SCNNode {
        let geometry = SCNBox(width: x, height: y, length: z, chamferRadius: 0)
        geometry.materials = [Self.material(color)]
        return SCNNode(geometry: geometry)
    }

    private func pointCloud(_ points: [SCNVector3], color: UInt32, size: CGFloat) -> SCNNode {
        let element = SCNGeometryElement(indices: points.indices.map(Int32.init), primitiveType: .point)
        element.pointSize = size; element.minimumPointScreenSpaceRadius = size * 0.5
        element.maximumPointScreenSpaceRadius = size
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points)], elements: [element])
        geometry.materials = [Self.material(color, constant: true)]
        return SCNNode(geometry: geometry)
    }

    private func mark(_ node: SCNNode, destination: ExplorationDestination) {
        node.name = "destination-\(destination.rawValue)"
        node.categoryBitMask = 2
        node.enumerateChildNodes { child, _ in child.categoryBitMask = 2 }
    }

    private static func material(_ hex: UInt32, constant: Bool = false) -> SCNMaterial {
        let result = SCNMaterial()
        result.diffuse.contents = color(hex)
        result.lightingModel = constant ? .constant : .lambert
        result.isDoubleSided = false
        return result
    }

    private func applyComicShading() {
        var surfaces: [SCNNode] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            if node.geometry?.elements.contains(where: { $0.primitiveType == .triangles || $0.primitiveType == .triangleStrip }) == true {
                surfaces.append(node)
            }
        }
        for node in surfaces {
            guard let geometry = node.geometry else { continue }
            if node.name == "landscape-ground" || node.name == "river" || node.parent?.name == "sky-cloud" { continue }
            for material in geometry.materials {
                material.lightingModel = .constant
                material.shaderModifiers = [.fragment: """
                #pragma body
                float n = dot(normalize(_surface.normal), normalize(float3(-0.35, 0.65, 0.85)));
                float shade = n > 0.45 ? 1.0 : (n > -0.1 ? 0.80 : 0.59);
                _output.color.rgb *= shade;
                """]
            }
            let bounds = node.boundingBox
            if bounds.max.x - bounds.min.x > 10 || bounds.max.z - bounds.min.z > 10 { continue }
            let hull = SCNNode(geometry: geometry.copy() as? SCNGeometry)
            let outline = Self.material(0x3B5140, constant: true)
            outline.cullMode = .front
            hull.geometry?.materials = Array(repeating: outline, count: geometry.materials.count)
            hull.scale = Self.v(1.018, 1.018, 1.018)
            hull.name = "comic-outline"
            node.addChildNode(hull)
        }
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    private static func fraction(_ number: Double) -> Double { number - floor(number) }
    private static func v(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 { SCNVector3(x, y, z) }

    /// Offscreen QA only; the shipped interface always renders the live mesh.
    static func snapshot(world: ExperienceTheme, size: CGSize, time: Double) -> NSImage {
        let model = ExplorationWorldModel(world: world, animated: false)
        model.setPose(time: time)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = model.scene; renderer.pointOfView = model.camera
        renderer.isPlaying = false
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: size.width * 2, height: size.height * 2), antialiasingMode: .multisampling2X)
        image.size = size
        return image
    }
}

struct ExplorationWorldView: NSViewRepresentable {
    let world: ExperienceTheme
    let motionEnabled: Bool
    var onDestination: ((ExplorationDestination) -> Void)?

    func makeNSView(context: Context) -> ExplorationSCNView {
        let view = ExplorationSCNView(frame: .zero, options: nil)
        view.preferredFramesPerSecond = 20
        view.antialiasingMode = .multisampling2X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ExplorationSCNView, context: Context) {
        view.configure(world: world)
        view.onDestination = onDestination
        view.motionEnabled = motionEnabled
        view.updatePlayback()
    }

    static func dismantleNSView(_ view: ExplorationSCNView, coordinator: ()) {
        view.motionEnabled = false; view.updatePlayback()
        view.scene = nil; view.model = nil
    }
}

final class ExplorationSCNView: SCNView {
    var model: ExplorationWorldModel?
    var world: ExperienceTheme?
    var motionEnabled = false
    var onDestination: ((ExplorationDestination) -> Void)?
    private var observers: [AnyCancellable] = []
    private var lastPlayback: Bool?
    private let sceneLogger = Logger(subsystem: "com.fantasy.livelearn", category: "ExplorationScene")

    func configure(world: ExperienceTheme) {
        guard self.world != world else { return }
        self.world = world
        lastPlayback = nil
        let model = ExplorationWorldModel(world: world, animated: true)
        self.model = model
        scene = model.scene; pointOfView = model.camera
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.publisher(for: name, object: window)
                    .sink { [weak self] _ in MainActor.assumeIsolated { self?.updatePlayback() } })
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.publisher(for: name)
                    .sink { [weak self] _ in MainActor.assumeIsolated { self?.updatePlayback() } })
            }
        }
        updatePlayback()
    }

    func updatePlayback() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        let playing = motionEnabled && visible && NSApp.isActive && !isHiddenOrHasHiddenAncestor
        rendersContinuously = false
        isPlaying = playing
        scene?.isPaused = !playing
        #if DEBUG
        if lastPlayback != playing {
            let name = world?.rawValue ?? "none"
            let allocated = device?.currentAllocatedSize ?? 0
            sceneLogger.info("world=\(name, privacy: .public) playing=\(playing) fps=\(self.preferredFramesPerSecond) metalBytes=\(allocated)")
        }
        #endif
        lastPlayback = playing
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onDestination != nil else { return nil }
        let local = convert(point, from: superview)
        return destination(at: local) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if let destination = destination(at: convert(event.locationInWindow, from: nil)) { onDestination?(destination) }
    }

    private func destination(at point: NSPoint) -> ExplorationDestination? {
        guard let hit = hitTest(point, options: [.categoryBitMask: 2]).first else { return nil }
        var node: SCNNode? = hit.node
        while let current = node {
            if let name = current.name, name.hasPrefix("destination-"), let raw = Int(name.dropFirst(12)) {
                return ExplorationDestination(rawValue: raw)
            }
            node = current.parent
        }
        return nil
    }
}
