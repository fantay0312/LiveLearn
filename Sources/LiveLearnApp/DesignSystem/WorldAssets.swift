import AppKit
import SceneKit

@MainActor
enum WorldAssets {
    private static var textures: [String: NSImage] = [:]
    private static var models: [String: SCNNode] = [:]

    static func url(_ relativePath: String) -> URL {
        worlds.appendingPathComponent(relativePath)
    }

    /// The resource bundle may be flat or carry a `Contents/Resources` layout (the current SwiftPM
    /// build does), so `Worlds` is resolved through the bundle's `resourceURL`, never its root.
    private static let worlds: URL = {
        let packaged = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("LiveLearn_LiveLearnApp.bundle")) }
        let bundle = packaged ?? Bundle.module
        return (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent("Worlds", isDirectory: true)
    }()

    static func texture(_ name: String) -> NSImage {
        if let image = textures[name] { return image }
        guard let image = NSImage(contentsOf: url(name.contains("/") ? name : "Planets/\(name)")) else {
            preconditionFailure("Missing planet material: \(name)")
        }
        textures[name] = image
        return image
    }

    static func map(_ property: SCNMaterialProperty, _ name: String) {
        property.contents = texture(name)
        property.wrapS = .repeat
        property.wrapT = .clamp
        property.magnificationFilter = .linear
        property.minificationFilter = .linear
        property.mipFilter = .linear
        property.maxAnisotropy = 4
    }

    static func model(_ name: String, height: CGFloat) -> SCNNode {
        let template: SCNNode
        if let cached = models[name] { template = cached }
        else {
            guard let scene = try? SCNScene(url: url("Nature/\(name).dae"), options: nil) else {
                preconditionFailure("Missing landscape model: \(name)")
            }
            template = scene.rootNode
            template.enumerateChildNodes { node, _ in
                if name == "oak" || name == "tree" { node.geometry?.subdivisionLevel = 2 }
                for material in node.geometry?.materials ?? [] {
                    let leaf = (material.name ?? "").lowercased().contains("leaf")
                    if !name.hasPrefix("castle-") {
                        material.diffuse.contents = NSColor(srgbRed: leaf ? 0.40 : 0.43, green: leaf ? 0.58 : 0.35,
                                                           blue: leaf ? 0.29 : 0.23, alpha: 1)
                    }
                    material.lightingModel = .lambert
                }
            }
            models[name] = template
        }
        let result = template.clone()
        let bounds = result.boundingBox
        let scale = height / max(0.001, bounds.max.y - bounds.min.y)
        result.scale = SCNVector3(scale, scale, scale)
        result.position.y = -bounds.min.y * scale
        return result
    }
}
