import SwiftUI
import AppKit
import SceneKit

/// A small glowing glass orb. The scene layers:
///
/// 1. Two additive halo planes behind everything for the soft outer bloom.
/// 2. An *inner energy core* sphere with a high-contrast cyan-white wispy
///    texture, rotating quickly so the spin reads clearly.
/// 3. A *glass shell* sphere just outside the core: lightly tinted, ~20%
///    opaque, with Blinn lighting + sharp specular so a directional light
///    paints a clean highlight on the surface like a glass marble.
/// 4. A back-face emissive rim shell just outside the glass to brighten the
///    silhouette.
/// 5. A directional key light (provides the specular highlight on the glass).
struct OrbView: NSViewRepresentable {
    var coreSpinDuration: Double = 28
    var shellSpinDuration: Double = 80

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = Self.buildScene(coreSpinDuration: coreSpinDuration,
                                     shellSpinDuration: shellSpinDuration)
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

    static func buildScene(coreSpinDuration: Double = 28,
                            shellSpinDuration: Double = 80) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        // --- Halos (background, additive) --------------------------------
        let outerHalo = makeHaloPlane(
            width: 7.0,
            tint: (0.40, 0.62, 1.00),
            coreRadius: 0.22,
            falloff: 0.5,
            z: -1.9
        )
        scene.rootNode.addChildNode(outerHalo)

        let midHalo = makeHaloPlane(
            width: 3.8,
            tint: (0.65, 0.84, 1.00),
            coreRadius: 0.36,
            falloff: 0.8,
            z: -1.0
        )
        scene.rootNode.addChildNode(midHalo)

        let innerHalo = makeHaloPlane(
            width: 2.0,
            tint: (0.92, 0.97, 1.00),
            coreRadius: 0.55,
            falloff: 1.3,
            z: -0.55
        )
        scene.rootNode.addChildNode(innerHalo)
        // Breathing animation on the inner halo.
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.78
        breathe.toValue = 1.00
        breathe.duration = 2.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        innerHalo.addAnimation(breathe, forKey: "breathe")

        // --- Inner energy core (opaque, rotates quickly) -----------------
        let coreGeom = SCNSphere(radius: 0.38)
        coreGeom.segmentCount = 96
        let coreMat = SCNMaterial()
        coreMat.diffuse.contents = OrbTexture.makeInterior(width: 1024, height: 512)
        coreMat.diffuse.wrapS = .repeat
        coreMat.diffuse.wrapT = .clamp
        coreMat.emission.contents = NSColor(red: 0.18, green: 0.40, blue: 0.85, alpha: 1)
        coreMat.lightingModel = .constant
        coreMat.writesToDepthBuffer = true
        coreGeom.firstMaterial = coreMat
        let coreNode = SCNNode(geometry: coreGeom)
        coreNode.renderingOrder = 0
        scene.rootNode.addChildNode(coreNode)

        let coreSpin = CABasicAnimation(keyPath: "rotation")
        coreSpin.fromValue = NSValue(scnVector4: SCNVector4(0, 1, 0, 0))
        coreSpin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, CGFloat.pi * 2))
        coreSpin.duration = coreSpinDuration
        coreSpin.repeatCount = .infinity
        coreSpin.timingFunction = CAMediaTimingFunction(name: .linear)
        coreNode.addAnimation(coreSpin, forKey: "coreSpin")

        // Subtle scale pulse — a heartbeat for the core.
        let pulse = CABasicAnimation(keyPath: "scale")
        pulse.fromValue = NSValue(scnVector3: SCNVector3(0.98, 0.98, 0.98))
        pulse.toValue = NSValue(scnVector3: SCNVector3(1.03, 1.03, 1.03))
        pulse.duration = 2.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coreNode.addAnimation(pulse, forKey: "pulse")

        // --- Glass shell (translucent, specular, slow counter-rotation) --
        let shellGeom = SCNSphere(radius: 0.50)
        shellGeom.segmentCount = 128
        let shellMat = SCNMaterial()
        shellMat.diffuse.contents = NSColor(red: 0.72, green: 0.86, blue: 1.00, alpha: 1)
        shellMat.specular.contents = NSColor.white
        shellMat.specular.intensity = 1.4             // hotter highlight
        shellMat.shininess = 0.7                      // moderately tight
        shellMat.lightingModel = .blinn
        shellMat.transparency = 0.20                  // mostly see-through
        shellMat.fresnelExponent = 2.6                // brighten the silhouette
        shellMat.isDoubleSided = false
        shellMat.writesToDepthBuffer = false
        shellMat.blendMode = .alpha
        // Boost the specular reflection on top of the transparent base by
        // adding an emission of the same key-light direction in code below.
        shellGeom.firstMaterial = shellMat
        let shellNode = SCNNode(geometry: shellGeom)
        shellNode.renderingOrder = 100
        scene.rootNode.addChildNode(shellNode)

        let shellSpin = CABasicAnimation(keyPath: "rotation")
        shellSpin.fromValue = NSValue(scnVector4: SCNVector4(0, 1, 0, 0))
        shellSpin.toValue = NSValue(scnVector4: SCNVector4(0, 1, 0, -CGFloat.pi * 2))
        shellSpin.duration = shellSpinDuration
        shellSpin.repeatCount = .infinity
        shellSpin.timingFunction = CAMediaTimingFunction(name: .linear)
        shellNode.addAnimation(shellSpin, forKey: "shellSpin")

        // --- Specular hotspot ---------------------------------------------
        // SceneKit's specular term gets multiplied down by the shell's alpha,
        // which leaves it nearly invisible at the transparencies that read as
        // "glass". A small additive billboard fakes a crisp reflection at the
        // upper-left of the surface — the classic glass-marble look.
        let specGeom = SCNPlane(width: 0.42, height: 0.42)
        let specMat = SCNMaterial()
        specMat.diffuse.contents = OrbTexture.makeGlow(
            size: 256,
            coreRadius: 0.30,
            falloff: 1.6,
            tint: (1.0, 1.0, 1.0)
        )
        specMat.lightingModel = .constant
        specMat.blendMode = .add
        specMat.transparencyMode = .aOne
        specMat.writesToDepthBuffer = false
        specMat.readsFromDepthBuffer = false
        specGeom.firstMaterial = specMat
        let specNode = SCNNode(geometry: specGeom)
        specNode.position = SCNVector3(-0.18, 0.22, 0.48)
        specNode.opacity = 0.95
        specNode.constraints = [SCNBillboardConstraint()]
        specNode.renderingOrder = 300
        scene.rootNode.addChildNode(specNode)

        // A second, smaller, brighter "kicker" reflection further toward the
        // top-left for depth.
        let kickerGeom = SCNPlane(width: 0.16, height: 0.16)
        let kickerMat = SCNMaterial()
        kickerMat.diffuse.contents = OrbTexture.makeGlow(
            size: 128,
            coreRadius: 0.40,
            falloff: 1.0,
            tint: (1.0, 1.0, 1.0)
        )
        kickerMat.lightingModel = .constant
        kickerMat.blendMode = .add
        kickerMat.transparencyMode = .aOne
        kickerMat.writesToDepthBuffer = false
        kickerMat.readsFromDepthBuffer = false
        kickerGeom.firstMaterial = kickerMat
        let kickerNode = SCNNode(geometry: kickerGeom)
        kickerNode.position = SCNVector3(-0.24, 0.30, 0.48)
        kickerNode.constraints = [SCNBillboardConstraint()]
        kickerNode.renderingOrder = 301
        scene.rootNode.addChildNode(kickerNode)

        // --- Rim glow shell (back-face emission, additive) ---------------
        let rimGeom = SCNSphere(radius: 0.515)
        rimGeom.segmentCount = 96
        let rimMat = SCNMaterial()
        rimMat.diffuse.contents = NSColor.clear
        rimMat.emission.contents = NSColor(red: 0.70, green: 0.86, blue: 1.0, alpha: 1)
        rimMat.transparent.contents = NSColor(white: 0.50, alpha: 1)
        rimMat.transparencyMode = .rgbZero
        rimMat.lightingModel = .constant
        rimMat.cullMode = .front
        rimMat.writesToDepthBuffer = false
        rimMat.readsFromDepthBuffer = false
        rimMat.blendMode = .add
        rimGeom.firstMaterial = rimMat
        let rimNode = SCNNode(geometry: rimGeom)
        rimNode.opacity = 0.55
        rimNode.renderingOrder = 200
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

        // --- Lights (only the glass shell responds — core uses .constant) -
        let key = SCNLight()
        key.type = .directional
        key.intensity = 2400
        key.color = NSColor(red: 1.0, green: 0.99, blue: 0.96, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.35, -0.55, 0)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 400
        fill.color = NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0.35, 1.10, 0)
        scene.rootNode.addChildNode(fillNode)

        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 80
        amb.color = NSColor(white: 0.5, alpha: 1)
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        return scene
    }

    private static func makeHaloPlane(width: CGFloat,
                                       tint: (Double, Double, Double),
                                       coreRadius: Double,
                                       falloff: Double,
                                       z: CGFloat) -> SCNNode {
        let plane = SCNPlane(width: width, height: width)
        let mat = SCNMaterial()
        mat.diffuse.contents = OrbTexture.makeGlow(
            size: 1024,
            coreRadius: coreRadius,
            falloff: falloff,
            tint: tint
        )
        mat.lightingModel = .constant
        mat.blendMode = .add
        mat.transparencyMode = .aOne
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        plane.firstMaterial = mat
        let node = SCNNode(geometry: plane)
        node.position = SCNVector3(0, 0, z)
        node.renderingOrder = -1000 + Int(z * 10)
        return node
    }
}
