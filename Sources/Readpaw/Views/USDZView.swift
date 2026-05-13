import SwiftUI
import AppKit
import SceneKit

/// Loads a bundled USDZ model, frames the camera around its bounding box,
/// auto-rotates it around Y, and lets the user click-and-drag to spin it.
/// USDZ is SceneKit-native — no third-party loader needed.
struct USDZView: NSViewRepresentable {
    var resourceName: String = "Color_orb"
    var spinDuration: Double = 22

    func makeCoordinator() -> Coordinator {
        Coordinator(spinDuration: spinDuration)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true

        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        // Soft IBL fallback so PBR-style USDZ materials don't render flat.
        scene.lightingEnvironment.contents = NSColor(white: 0.95, alpha: 1)
        scene.lightingEnvironment.intensity = 1.4
        view.scene = scene

        if let url = Bundle.module.url(forResource: resourceName, withExtension: "usdz"),
           let loaded = try? SCNScene(url: url) {
            let rotor = SCNNode()
            rotor.name = "USDZRotor"
            for child in loaded.rootNode.childNodes {
                child.removeFromParentNode()
                rotor.addChildNode(child)
            }
            scene.rootNode.addChildNode(rotor)

            frameCamera(in: scene, around: rotor)
            addLights(to: scene)

            let action = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: spinDuration)
            rotor.runAction(SCNAction.repeatForever(action), forKey: "autoSpin")

            context.coordinator.rotorNode = rotor
            context.coordinator.scnView = view
        }

        let pan = NSPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)

        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}

    private func frameCamera(in scene: SCNScene, around node: SCNNode) {
        let (minB, maxB) = node.boundingBox
        let center = SCNVector3(
            (minB.x + maxB.x) / 2,
            (minB.y + maxB.y) / 2,
            (minB.z + maxB.z) / 2
        )
        let size = SCNVector3(
            maxB.x - minB.x,
            maxB.y - minB.y,
            maxB.z - minB.z
        )
        let radius = max(size.x, max(size.y, size.z)) / 2.0
        let dist = max(radius * 2.6, 0.5)

        let camera = SCNCamera()
        camera.fieldOfView = 34
        camera.zNear = max(0.001, Double(radius) * 0.001)
        camera.zFar = Double(radius) * 50 + 100
        camera.wantsHDR = true

        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(
            center.x,
            center.y + radius * 0.10,
            center.z + dist
        )
        camNode.look(at: center)
        scene.rootNode.addChildNode(camNode)
    }

    private func addLights(to scene: SCNScene) {
        let key = SCNLight()
        key.type = .directional
        key.intensity = 1200
        key.color = NSColor(red: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.35, -0.50, 0)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 500
        fill.color = NSColor(red: 0.55, green: 0.72, blue: 1.0, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0.32, 1.10, 0)
        scene.rootNode.addChildNode(fillNode)

        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 350
        amb.color = NSColor(white: 0.55, alpha: 1)
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)
    }

    final class Coordinator: NSObject {
        let spinDuration: Double
        weak var scnView: SCNView?
        weak var rotorNode: SCNNode?
        private var dragStartYaw: CGFloat = 0
        private var dragStartPitch: CGFloat = 0

        init(spinDuration: Double) { self.spinDuration = spinDuration }

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let view = scnView, let rotor = rotorNode else { return }
            switch gesture.state {
            case .began:
                rotor.removeAllActions()
                dragStartYaw = rotor.eulerAngles.y
                dragStartPitch = rotor.eulerAngles.x
            case .changed:
                let t = gesture.translation(in: view)
                let yaw = dragStartYaw + t.x * 0.012
                let pitchClamp: CGFloat = .pi / 2 - 0.05
                let pitch = max(-pitchClamp,
                                min(pitchClamp, dragStartPitch + t.y * 0.012))
                rotor.eulerAngles = SCNVector3(pitch, yaw, 0)
            case .ended, .cancelled, .failed:
                let action = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0,
                                                 duration: spinDuration)
                rotor.runAction(SCNAction.repeatForever(action), forKey: "autoSpin")
            default:
                break
            }
        }
    }
}
