import SwiftUI
import AppKit
import SceneKit

/// A slowly rotating spiral galaxy. The disc is a procedurally-textured plane
/// drawn with additive blending so it glows over the page background. A static
/// starfield sits behind so the rotation reads clearly.
struct GalaxyView: NSViewRepresentable {
    var spinDuration: Double = 80

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = Self.buildScene(spinDuration: spinDuration)
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}

    private static func buildScene(spinDuration: Double) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        // Static starfield: large plane sitting behind, no rotation.
        let starfieldTexture = GalaxyTexture.makeStarfield(size: 1024, density: 700)
        let starPlane = SCNPlane(width: 8, height: 8)
        let starMat = SCNMaterial()
        starMat.diffuse.contents = NSColor.clear
        starMat.emission.contents = starfieldTexture
        starMat.lightingModel = .constant
        starMat.blendMode = .add
        starMat.writesToDepthBuffer = false
        starMat.readsFromDepthBuffer = false
        starMat.isDoubleSided = false
        starPlane.firstMaterial = starMat
        let starNode = SCNNode(geometry: starPlane)
        starNode.position = SCNVector3(0, 0, -2.0)
        scene.rootNode.addChildNode(starNode)

        // Tilt container — the galaxy disc rotates around its local Z (the
        // axis perpendicular to the disc face), inside this tilted node.
        let tilt = SCNNode()
        tilt.eulerAngles = SCNVector3(-0.55, 0.05, 0.10)
        scene.rootNode.addChildNode(tilt)

        // Galaxy disc.
        let galaxyTexture = GalaxyTexture.makeSpiral(size: 1024,
                                                      arms: 4,
                                                      twist: 3.4,
                                                      armWidth: 0.32)
        let disc = SCNPlane(width: 3.4, height: 3.4)
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor.clear
        mat.emission.contents = galaxyTexture
        mat.lightingModel = .constant
        mat.blendMode = .add
        mat.writesToDepthBuffer = false
        mat.isDoubleSided = false
        disc.firstMaterial = mat
        let discNode = SCNNode(geometry: disc)
        tilt.addChildNode(discNode)

        let spin = CABasicAnimation(keyPath: "rotation")
        spin.fromValue = NSValue(scnVector4: SCNVector4(0, 0, 1, 0))
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 0, 1, CGFloat.pi * 2))
        spin.duration = spinDuration
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        discNode.addAnimation(spin, forKey: "spin")

        // A second, slower spiral overlay rotating in the opposite direction
        // adds a subtle parallax to the bulge — like internal motion.
        let innerTexture = GalaxyTexture.makeSpiral(size: 1024,
                                                      arms: 2,
                                                      twist: 4.6,
                                                      armWidth: 0.45,
                                                      seed: 0xBADA_55_DEED)
        let inner = SCNPlane(width: 1.7, height: 1.7)
        let innerMat = SCNMaterial()
        innerMat.diffuse.contents = NSColor.clear
        innerMat.emission.contents = innerTexture
        innerMat.lightingModel = .constant
        innerMat.blendMode = .add
        innerMat.writesToDepthBuffer = false
        innerMat.isDoubleSided = false
        inner.firstMaterial = innerMat
        let innerNode = SCNNode(geometry: inner)
        innerNode.position = SCNVector3(0, 0, 0.01)
        innerNode.opacity = 0.55
        tilt.addChildNode(innerNode)

        let counterSpin = CABasicAnimation(keyPath: "rotation")
        counterSpin.fromValue = NSValue(scnVector4: SCNVector4(0, 0, 1, 0))
        counterSpin.toValue = NSValue(scnVector4: SCNVector4(0, 0, 1, -CGFloat.pi * 2))
        counterSpin.duration = spinDuration * 1.6
        counterSpin.repeatCount = .infinity
        counterSpin.timingFunction = CAMediaTimingFunction(name: .linear)
        innerNode.addAnimation(counterSpin, forKey: "counterSpin")

        // Camera.
        let camera = SCNCamera()
        camera.fieldOfView = 36
        camera.zNear = 0.01
        camera.zFar = 100
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0, 3.4)
        scene.rootNode.addChildNode(camNode)

        return scene
    }
}
