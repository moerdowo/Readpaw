import SwiftUI
import AppKit
import SceneKit

/// A slowly rotating 3D moon with procedural surface and a soft glow halo.
struct MoonView: NSViewRepresentable {
    var spinDuration: Double = 110

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = Self.buildScene(spinDuration: spinDuration)
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
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

        // --- Outer halo ----------------------------------------------------
        // Big soft glow plane behind everything, drawn additively.
        let outerHalo = SCNPlane(width: 5.6, height: 5.6)
        let outerMat = SCNMaterial()
        outerMat.diffuse.contents = NSColor.clear
        outerMat.emission.contents = MoonTexture.makeGlow(
            size: 1024,
            coreRadius: 0.42,
            falloff: 0.6,
            tint: (0.78, 0.85, 1.0)
        )
        outerMat.lightingModel = .constant
        outerMat.blendMode = .add
        outerMat.writesToDepthBuffer = false
        outerMat.readsFromDepthBuffer = false
        outerMat.isDoubleSided = false
        outerHalo.firstMaterial = outerMat
        let outerNode = SCNNode(geometry: outerHalo)
        outerNode.position = SCNVector3(0, 0, -1.5)
        outerNode.opacity = 0.85
        scene.rootNode.addChildNode(outerNode)

        // --- Inner halo (tighter, brighter) --------------------------------
        let innerHalo = SCNPlane(width: 2.9, height: 2.9)
        let innerMat = SCNMaterial()
        innerMat.diffuse.contents = NSColor.clear
        innerMat.emission.contents = MoonTexture.makeGlow(
            size: 1024,
            coreRadius: 0.55,
            falloff: 0.8,
            tint: (0.96, 0.96, 0.92)
        )
        innerMat.lightingModel = .constant
        innerMat.blendMode = .add
        innerMat.writesToDepthBuffer = false
        innerMat.readsFromDepthBuffer = false
        innerHalo.firstMaterial = innerMat
        let innerNode = SCNNode(geometry: innerHalo)
        innerNode.position = SCNVector3(0, 0, -0.4)
        innerNode.opacity = 0.95
        scene.rootNode.addChildNode(innerNode)

        // --- Moon ----------------------------------------------------------
        let moonGeom = SCNSphere(radius: 1.0)
        moonGeom.segmentCount = 128
        let moonMat = SCNMaterial()
        moonMat.diffuse.contents = MoonTexture.makeSurface(width: 1536, height: 768)
        moonMat.diffuse.wrapS = .repeat
        moonMat.diffuse.wrapT = .clamp
        moonMat.diffuse.mipFilter = .linear
        moonMat.specular.contents = NSColor(white: 0.05, alpha: 1)
        moonMat.shininess = 0.05
        moonMat.locksAmbientWithDiffuse = true
        moonMat.lightingModel = .blinn
        moonGeom.firstMaterial = moonMat

        let moonNode = SCNNode(geometry: moonGeom)
        // Slight axial tilt for visual interest.
        moonNode.eulerAngles = SCNVector3(x: 0.18, y: 0, z: 0)
        scene.rootNode.addChildNode(moonNode)

        // Rotation: spin around the moon's Y axis (local).
        let spin = CABasicAnimation(keyPath: "rotation")
        spin.fromValue = NSValue(scnVector4: SCNVector4(0, 1, 0, 0))
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, CGFloat.pi * 2))
        spin.duration = spinDuration
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        moonNode.addAnimation(spin, forKey: "spin")

        // --- Rim glow sphere ----------------------------------------------
        // A slightly larger sphere with back faces visible — creates a soft
        // bright outline around the moon (atmosphere-style rim light).
        let rim = SCNSphere(radius: 1.04)
        rim.segmentCount = 96
        let rimMat = SCNMaterial()
        rimMat.diffuse.contents = NSColor.clear
        rimMat.emission.contents = NSColor(red: 0.78, green: 0.86, blue: 1.0, alpha: 1)
        rimMat.transparent.contents = NSColor(white: 0.6, alpha: 1)
        rimMat.transparencyMode = .rgbZero
        rimMat.lightingModel = .constant
        rimMat.cullMode = .front
        rimMat.writesToDepthBuffer = false
        rimMat.readsFromDepthBuffer = false
        rimMat.blendMode = .add
        rim.firstMaterial = rimMat
        let rimNode = SCNNode(geometry: rim)
        rimNode.opacity = 0.55
        scene.rootNode.addChildNode(rimNode)

        // --- Camera --------------------------------------------------------
        let camera = SCNCamera()
        camera.fieldOfView = 36
        camera.zNear = 0.01
        camera.zFar = 100
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0.05, 3.0)
        scene.rootNode.addChildNode(camNode)

        // --- Lights --------------------------------------------------------
        // Key: bright warm directional from front-upper-left of the moon —
        // produces phase shading. Angled so most of the moon is lit.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 1300
        key.color = NSColor(red: 1.00, green: 0.97, blue: 0.90, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.22, -0.30, 0)
        scene.rootNode.addChildNode(keyNode)

        // Fill: cool faint light from opposite side to keep the dark side
        // legible without washing out shading.
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 350
        fill.color = NSColor(red: 0.55, green: 0.65, blue: 0.92, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0.30, 1.10, 0)
        scene.rootNode.addChildNode(fillNode)

        // Low ambient.
        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 120
        amb.color = NSColor(white: 0.55, alpha: 1)
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        return scene
    }
}
