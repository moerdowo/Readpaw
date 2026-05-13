import SwiftUI
import AppKit
import SceneKit

/// A glowing orb — emissive sphere with soft pale surface noise, an inverted
/// rim-glow sphere just outside it, and two radial-gradient halo planes for
/// the outer bloom. Slowly rotates so the surface variations read; the inner
/// halo gently breathes.
struct OrbView: NSViewRepresentable {
    var spinDuration: Double = 70

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

        // --- Outermost halo: large, very soft bloom -----------------------
        let outermost = SCNPlane(width: 7.0, height: 7.0)
        let outermostMat = SCNMaterial()
        outermostMat.diffuse.contents = OrbTexture.makeGlow(
            size: 1024,
            coreRadius: 0.22,
            falloff: 0.5,
            tint: (0.40, 0.62, 1.0)
        )
        outermostMat.lightingModel = .constant
        outermostMat.blendMode = .add
        outermostMat.transparencyMode = .aOne
        outermostMat.writesToDepthBuffer = false
        outermostMat.readsFromDepthBuffer = false
        outermost.firstMaterial = outermostMat
        let outermostNode = SCNNode(geometry: outermost)
        outermostNode.position = SCNVector3(0, 0, -1.8)
        scene.rootNode.addChildNode(outermostNode)

        // --- Outer halo: medium bloom -------------------------------------
        let outerHalo = SCNPlane(width: 3.6, height: 3.6)
        let outerMat = SCNMaterial()
        outerMat.diffuse.contents = OrbTexture.makeGlow(
            size: 1024,
            coreRadius: 0.36,
            falloff: 0.8,
            tint: (0.65, 0.84, 1.0)
        )
        outerMat.lightingModel = .constant
        outerMat.blendMode = .add
        outerMat.transparencyMode = .aOne
        outerMat.writesToDepthBuffer = false
        outerMat.readsFromDepthBuffer = false
        outerHalo.firstMaterial = outerMat
        let outerNode = SCNNode(geometry: outerHalo)
        outerNode.position = SCNVector3(0, 0, -1.0)
        scene.rootNode.addChildNode(outerNode)

        // --- Inner halo: tight, bright, breathes --------------------------
        let innerHalo = SCNPlane(width: 1.9, height: 1.9)
        let innerMat = SCNMaterial()
        innerMat.diffuse.contents = OrbTexture.makeGlow(
            size: 1024,
            coreRadius: 0.55,
            falloff: 1.3,
            tint: (0.92, 0.97, 1.0)
        )
        innerMat.lightingModel = .constant
        innerMat.blendMode = .add
        innerMat.transparencyMode = .aOne
        innerMat.writesToDepthBuffer = false
        innerHalo.firstMaterial = innerMat
        let innerNode = SCNNode(geometry: innerHalo)
        innerNode.position = SCNVector3(0, 0, -0.3)
        scene.rootNode.addChildNode(innerNode)

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.78
        breathe.toValue = 1.00
        breathe.duration = 3.0
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        innerNode.addAnimation(breathe, forKey: "breathe")

        // --- Orb core ----------------------------------------------------
        let orb = SCNSphere(radius: 0.50)
        orb.segmentCount = 96
        let orbMat = SCNMaterial()
        let surface = OrbTexture.makeSurface(width: 1024, height: 512)
        orbMat.diffuse.contents = surface
        orbMat.diffuse.wrapS = .repeat
        orbMat.diffuse.wrapT = .clamp
        // A touch of self-emission boosts the "glowing" feel beyond the halo.
        orbMat.emission.contents = NSColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1)
        orbMat.lightingModel = .constant
        orbMat.writesToDepthBuffer = true
        orb.firstMaterial = orbMat
        let orbNode = SCNNode(geometry: orb)
        scene.rootNode.addChildNode(orbNode)

        let spin = CABasicAnimation(keyPath: "rotation")
        spin.fromValue = NSValue(scnVector4: SCNVector4(0, 1, 0, 0))
        spin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, CGFloat.pi * 2))
        spin.duration = spinDuration
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        orbNode.addAnimation(spin, forKey: "spin")

        // --- Rim glow: back-face emissive shell, slightly larger ---------
        let rim = SCNSphere(radius: 0.535)
        rim.segmentCount = 96
        let rimMat = SCNMaterial()
        rimMat.diffuse.contents = NSColor.clear
        rimMat.emission.contents = NSColor(red: 0.65, green: 0.82, blue: 1.0, alpha: 1)
        rimMat.transparent.contents = NSColor(white: 0.45, alpha: 1)
        rimMat.transparencyMode = .rgbZero
        rimMat.lightingModel = .constant
        rimMat.cullMode = .front
        rimMat.writesToDepthBuffer = false
        rimMat.readsFromDepthBuffer = false
        rimMat.blendMode = .add
        rim.firstMaterial = rimMat
        let rimNode = SCNNode(geometry: rim)
        rimNode.opacity = 0.6
        scene.rootNode.addChildNode(rimNode)

        // --- Camera ------------------------------------------------------
        let camera = SCNCamera()
        camera.fieldOfView = 36
        camera.zNear = 0.01
        camera.zFar = 100
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0, 2.4)
        scene.rootNode.addChildNode(camNode)

        return scene
    }
}
