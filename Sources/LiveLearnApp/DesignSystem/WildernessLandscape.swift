import AppKit
import SceneKit
import simd

/// A continuous valley, with foreground vegetation and distant kingdom landmarks.
/// Distant vegetation is flattened into shared-material batches; only nearby trees sway.
@MainActor
enum WildernessLandscape {
    struct Result {
        let root: SCNNode
        let clouds: [SCNNode]
    }

    static func make() -> Result {
        let root = SCNNode()
        let ground = SCNNode(geometry: terrain())
        ground.name = "landscape-ground"
        root.addChildNode(ground)
        let river = SCNNode(geometry: riverMesh()); river.name = "river"; root.addChildNode(river)

        let forest = SCNNode()
        for i in 0..<105 {
            let seed = Double(i)
            let x = fraction(sin(seed * 71.37 + 2) * 15313.71) * 62 - 25
            let z = fraction(sin(seed * 32.93 + 5) * 45671.03) * 63 - 52
            if abs(x - riverX(z)) < 2.4 || (abs(x - 13) < 5 && abs(z + 24) < 6) { continue }
            let model = WorldAssets.model(i.isMultiple(of: 3) ? "tree" : "oak", height: CGFloat(1.3 + fraction(seed * 0.618) * 1.5))
            model.position = v(x, elevation(x, z), z)
            model.eulerAngles.y = CGFloat(seed * 1.37)
            forest.addChildNode(model)
        }
        let distantForest = forest.flattenedClone()
        distantForest.enumerateChildNodes { node, _ in node.geometry?.subdivisionLevel = 0 }
        distantForest.geometry?.subdivisionLevel = 0
        root.addChildNode(distantForest)
        for (index, point) in [(15.0, 7.0), (19.0, 9.0), (11.5, 4.0), (5.0, 9.0), (22.0, 4.0)].enumerated() {
            let tree = WorldAssets.model(index.isMultiple(of: 2) ? "oak" : "tree", height: CGFloat(2.5 + Double(index % 3) * 0.4))
            tree.position = v(point.0, elevation(point.0, point.1), point.1)
            tree.eulerAngles.y = CGFloat(Double(index) * 0.8)
            tree.runAction(.repeatForever(.sequence([.rotateBy(x: 0, y: 0, z: 0.012, duration: 3.5),
                                                      .rotateBy(x: 0, y: 0, z: -0.012, duration: 3.5)])))
            root.addChildNode(tree)
        }
        for i in 0..<18 {
            let x = 4 + Double(i % 6) * 3.2, z = -2 + Double(i / 6) * 4.3
            let rock = WorldAssets.model("rock", height: CGFloat(0.35 + Double(i % 4) * 0.20))
            rock.position = v(x, elevation(x, z) - 0.08, z); rock.eulerAngles.y = CGFloat(Double(i) * 0.7)
            root.addChildNode(rock)
        }
        let kingdom = castle()
        kingdom.position = v(13, elevation(13, -24), -24)
        kingdom.name = "destination-0"
        kingdom.enumerateChildNodes { node, _ in node.categoryBitMask = 2 }
        root.addChildNode(kingdom)

        var clouds: [SCNNode] = []
        for i in 0..<5 {
            let cloud = SCNNode()
            for j in 0..<4 {
                let sphere = SCNSphere(radius: 1); sphere.segmentCount = 12
                sphere.materials = [material(0xFFF9E7, constant: true)]
                let puff = SCNNode(geometry: sphere)
                puff.scale = v(2.8 + Double(j % 2), 0.45 + Double(j % 3) * 0.17, 1.5)
                puff.position = v(Double(j) * 2.2, Double(j % 2) * 0.2, 0)
                puff.opacity = 0.40
                cloud.addChildNode(puff)
            }
            cloud.name = "sky-cloud"
            cloud.position = v(-25 + Double(i) * 14, 14 + Double(i % 2) * 3, -42 - Double(i % 3) * 7)
            root.addChildNode(cloud); clouds.append(cloud)
        }
        for i in 0..<2 {
            let island = skyIsland()
            island.position = v(8 + Double(i) * 16, 12 + Double(i) * 4, -38 - Double(i) * 10)
            island.name = "destination-\(i == 0 ? 2 : 3)"
            island.enumerateChildNodes { node, _ in node.categoryBitMask = 2 }
            island.runAction(.repeatForever(.sequence([.moveBy(x: 0, y: 0.25, z: 0, duration: 9),
                                                        .moveBy(x: 0, y: -0.25, z: 0, duration: 9)])))
            root.addChildNode(island)
        }
        return Result(root: root, clouds: clouds)
    }

    static func elevation(_ x: Double, _ z: Double) -> Double {
        let rolling = 0.8 + 1.2 * sin(x * 0.10 + z * 0.075) + 0.5 * cos(x * 0.28 - z * 0.15)
        let ridge = 13.0 * exp(-pow((x - 14) / 13, 2) - pow((z + 62) / 12, 2)) * (1 + 0.12 * sin(x * 0.73) + 0.07 * cos(z * 0.89))
            + 9.0 * exp(-pow((x + 24) / 14, 2) - pow((z + 52) / 13, 2))
            + 7.0 * exp(-pow((x - 39) / 13, 2) - pow((z + 47) / 18, 2))
        let detail = 0.12 * sin(x * 1.3 + z * 0.6) + 0.18 * cos(z * 0.7 - x * 0.3)
        let bed = exp(-pow((x - riverX(z)) / 2.8, 2)) * 0.6
        return rolling + ridge + detail - bed
    }

    private static func terrain() -> SCNGeometry {
        let nx = 144, nz = 144
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        var coordinates: [CGPoint] = []
        var groups = [[Int32]](repeating: [], count: 4)
        for row in 0...nz {
            let z = -82 + Double(row) / Double(nz) * 102
            for column in 0...nx {
                let x = -65 + Double(column) / Double(nx) * 130
                let y = elevation(x, z)
                vertices.append(v(x, y, z))
                coordinates.append(CGPoint(x: x / 5, y: z / 5))
                let normal = simd_normalize(SIMD3<Double>(elevation(x - 0.1, z) - elevation(x + 0.1, z), 0.2,
                                                        elevation(x, z - 0.1) - elevation(x, z + 0.1)))
                normals.append(v(normal.x, normal.y, normal.z))
                guard row < nz, column < nx else { continue }
                let a = Int32(row * (nx + 1) + column), b = a + 1, c = a + Int32(nx + 1), d = c + 1
                let kind = y > 7 ? 3 : abs(x - riverX(z)) < 2.2 ? 2 : sin(x * 0.12 + z * 0.07) > 0.3 ? 0 : 1
                groups[kind].append(contentsOf: [a, c, b, b, c, d])
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
                                             SCNGeometrySource(textureCoordinates: coordinates)],
                                   elements: groups.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) })
        geometry.materials = [0x91A972, 0xA5B580, 0xBFB58A, 0x9DAB9C].map { material(UInt32($0)) }
        for (index, grass) in geometry.materials.prefix(2).enumerated() {
            WorldAssets.map(grass.diffuse, "Nature/meadow.png")
            grass.diffuse.wrapT = .repeat
            grass.multiply.contents = color(index == 0 ? 0xDCE8C5 : 0xEDF0D9)
        }
        return geometry
    }

    private static func riverX(_ z: Double) -> Double { 17 + sin(z * 0.075) * 5 }
    private static func riverMesh() -> SCNGeometry {
        var vertices: [SCNVector3] = [], indices: [Int32] = []
        for i in 0...100 {
            let z = -72 + Double(i) * 0.9, x = riverX(z)
            let y = elevation(x, z) + 0.045
            vertices.append(v(x - 0.85, y, z)); vertices.append(v(x + 0.85, y, z))
            if i < 100 { let a = Int32(i * 2); indices.append(contentsOf: [a, a + 2, a + 1, a + 1, a + 2, a + 3]) }
        }
        let result = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                         SCNGeometrySource(normals: Array(repeating: SCNVector3(0, 1, 0), count: vertices.count))],
                                 elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let water = material(0x93B7AE); water.specular.contents = color(0xEFE9C8); water.shininess = 50
        result.materials = [water]
        return result
    }

    private static func castle() -> SCNNode {
        let root = SCNNode()
        let keep = box(3.4, 3.7, 2.4, color: 0xBCC2B1); keep.position.y = 1.85; root.addChildNode(keep)
        let carvedKeep = WorldAssets.model("castle-keep", height: 4.8)
        carvedKeep.position.y = 2.8
        root.addChildNode(carvedKeep)
        let gate = WorldAssets.model("castle-gate", height: 2.7)
        gate.position = v(0, 0, 1.3)
        root.addChildNode(gate)
        for (i, point) in [(-2.0, -1.5), (2.0, -1.5), (-2.0, 1.5), (2.0, 1.5), (0.0, -0.2)].enumerated() {
            let height = i == 4 ? 7.4 : 4.2 + Double(i % 2) * 0.9
            let tower = SCNNode()
            let body = SCNCylinder(radius: i == 4 ? 0.56 : 0.40, height: CGFloat(height))
            body.radialSegmentCount = 32; body.materials = [material(0xBAC4B8)]
            let shaft = SCNNode(geometry: body); shaft.position.y = CGFloat(height * 0.5); tower.addChildNode(shaft)
            for j in 0..<3 {
                let belt = SCNCylinder(radius: i == 4 ? 0.61 : 0.46, height: 0.13)
                belt.radialSegmentCount = 24; belt.materials = [material(0x7F968A)]
                let node = SCNNode(geometry: belt); node.position.y = CGFloat(height * (0.25 + Double(j) * 0.3)); tower.addChildNode(node)
            }
            let roof = SCNCone(topRadius: 0.015, bottomRadius: i == 4 ? 0.83 : 0.65, height: i == 4 ? 2.4 : 1.7)
            roof.radialSegmentCount = 20; roof.materials = [material(0x5C8582)]
            let roofNode = SCNNode(geometry: roof); roofNode.position.y = CGFloat(height + (i == 4 ? 1.2 : 0.85)); tower.addChildNode(roofNode)
            tower.position = v(point.0, 0, point.1); root.addChildNode(tower)
            for level in 1...3 {
                let window = box(0.15, 0.42, 0.04, color: 0x486E6C)
                window.position = v(point.0, Double(level) * height / 4, point.1 + 0.41)
                root.addChildNode(window)
            }
        }
        for i in 0..<12 {
            let battlement = box(0.18, 0.26, 0.35, color: 0xC0C7B7)
            battlement.position = v(-1.6 + Double(i) * 0.29, 3.8, 1.12); root.addChildNode(battlement)
        }
        return root
    }

    private static func skyIsland() -> SCNNode {
        let root = SCNNode()
        for i in 0..<5 {
            let shard = SCNCone(topRadius: CGFloat(0.9 - Double(i) * 0.11), bottomRadius: 0.12, height: CGFloat(1.2 + Double(i % 3) * 0.4))
            shard.radialSegmentCount = 9; shard.materials = [material(0xB8B7A1)]
            let node = SCNNode(geometry: shard); node.position = v(Double(i % 3) * 0.7 - 0.7, -0.2, Double(i / 3) * 0.7); root.addChildNode(node)
        }
        let platform = SCNCylinder(radius: 1.5, height: 0.22); platform.radialSegmentCount = 24; platform.materials = [material(0x9AB090)]
        let top = SCNNode(geometry: platform); top.position.y = 0.60; root.addChildNode(top)
        let ruin = castle(); ruin.scale = v(0.22, 0.22, 0.22); ruin.position.y = 0.72; root.addChildNode(ruin)
        return root
    }

    private static func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, color: UInt32) -> SCNNode {
        let shape = SCNBox(width: w, height: h, length: d, chamferRadius: 0.025)
        shape.chamferSegmentCount = 1; shape.materials = [material(color)]
        return SCNNode(geometry: shape)
    }
    private static func material(_ hex: UInt32, constant: Bool = false) -> SCNMaterial {
        let material = SCNMaterial(); material.diffuse.contents = color(hex)
        material.lightingModel = constant ? .constant : .lambert
        return material
    }
    private static func color(_ h: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }
    private static func v(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 { SCNVector3(x, y, z) }
    private static func fraction(_ n: Double) -> Double { n - floor(n) }
}
