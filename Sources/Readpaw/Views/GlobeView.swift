import SwiftUI
import AppKit
import SceneKit

/// Rotating, lit 3D globe used on the onboarding screen. The texture is
/// generated procedurally so we don't have to ship an image asset.
struct GlobeView: NSViewRepresentable {
    var size: CGFloat
    var spinDuration: Double = 38

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

    static func buildScene(spinDuration: Double) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        // Earth
        let sphere = SCNSphere(radius: 1.0)
        sphere.segmentCount = 96
        let mat = SCNMaterial()
        if let texture = EarthTexture.makeNSImage(width: 1536, height: 768) {
            mat.diffuse.contents = texture
        } else {
            mat.diffuse.contents = NSColor(red: 0.10, green: 0.22, blue: 0.45, alpha: 1)
        }
        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .clamp
        mat.specular.contents = NSColor(white: 0.45, alpha: 1)
        mat.shininess = 0.35
        mat.locksAmbientWithDiffuse = true
        sphere.firstMaterial = mat

        let earthNode = SCNNode(geometry: sphere)
        // Slight axial tilt for visual interest.
        earthNode.eulerAngles = SCNVector3(x: 0.42, y: 0, z: 0.0)
        scene.rootNode.addChildNode(earthNode)

        // Inner glow sphere — slightly larger, gradient material — gives the
        // soft atmospheric halo.
        let halo = SCNSphere(radius: 1.06)
        halo.segmentCount = 64
        let haloMat = SCNMaterial()
        haloMat.diffuse.contents = NSColor.clear
        haloMat.emission.contents = NSColor(red: 0.30, green: 0.55, blue: 1.0, alpha: 0.25)
        haloMat.transparent.contents = NSColor(white: 1.0, alpha: 0.35)
        haloMat.transparencyMode = .rgbZero
        haloMat.lightingModel = .constant
        haloMat.cullMode = .front
        haloMat.writesToDepthBuffer = false
        halo.firstMaterial = haloMat
        let haloNode = SCNNode(geometry: halo)
        scene.rootNode.addChildNode(haloNode)

        // Spin animation
        let spin = CABasicAnimation(keyPath: "rotation")
        spin.fromValue = NSValue(scnVector4: SCNVector4(0, 1, 0, 0))
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, CGFloat.pi * 2))
        spin.duration = spinDuration
        spin.repeatCount = .infinity
        earthNode.addAnimation(spin, forKey: "spin")

        // Camera
        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 0.01
        camera.zFar = 100
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0.05, 3.2)
        scene.rootNode.addChildNode(camNode)

        // Key light (sun) — warm and from upper-right
        let key = SCNLight()
        key.type = .directional
        key.intensity = 1400
        key.color = NSColor(red: 1.0, green: 0.96, blue: 0.88, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.25, -0.7, 0)
        scene.rootNode.addChildNode(keyNode)

        // Fill light — cool, low intensity, from opposite side for rim
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 400
        fill.color = NSColor(red: 0.45, green: 0.55, blue: 0.85, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0.3, 1.2, 0)
        scene.rootNode.addChildNode(fillNode)

        // Ambient — very low
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 60
        ambient.color = NSColor(white: 0.4, alpha: 1)
        let ambNode = SCNNode()
        ambNode.light = ambient
        scene.rootNode.addChildNode(ambNode)

        return scene
    }
}
