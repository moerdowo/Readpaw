import Foundation
import AppKit
import CoreGraphics

/// Procedural textures for the glowing-orb onboarding visual. The orb surface
/// is a softly-varying equirectangular map driven by 3D value-noise (so the
/// texture wraps cleanly across the seam at lon = ±180°) — colors stay in a
/// pale cyan-white range so the sphere reads as luminous rather than as a
/// planet. The glow map is a radial gradient with a sharp inner core plus a
/// long soft falloff, intended to be drawn additively as a halo plane.
enum OrbTexture {

    static func makeSurface(width: Int = 1024,
                            height: Int = 512,
                            seed: UInt64 = 0xB1AE_0B_BACE) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: width * 4,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        guard let raw = ctx.data else { return nil }
        let buf = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let cloudNoise = ValueNoise(seed: seed)
        let detailNoise = ValueNoise(seed: seed ^ 0xACED_BEEF)

        for y in 0..<height {
            let v = Double(y) / Double(height)
            let lat = (0.5 - v) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)

            for x in 0..<width {
                let u = Double(x) / Double(width)
                let lon = (u - 0.5) * 2 * .pi
                let px = cosLat * cos(lon)
                let py = sinLat
                let pz = cosLat * sin(lon)

                let cloud  = cloudNoise.fbm(px * 2.0, py * 2.0, pz * 2.0, octaves: 4, lacunarity: 2.0, gain: 0.55)
                let detail = detailNoise.fbm(px * 5.5, py * 5.5, pz * 5.5, octaves: 3, lacunarity: 2.1, gain: 0.5)

                let combined = cloud * 0.72 + detail * 0.28

                // Bright pale cyan-white base with subtle variations.
                let intensity = 0.78 + (combined - 0.5) * 0.42 // ~0.57..0.99
                let r = clamp01(intensity * 0.88)
                let g = clamp01(intensity * 0.96)
                let b = clamp01(intensity * 1.05)

                let off = (y * width + x) * 4
                buf[off]     = UInt8(r * 255)
                buf[off + 1] = UInt8(g * 255)
                buf[off + 2] = UInt8(b * 255)
                buf[off + 3] = 255
            }
        }

        return ctx.makeImage()
    }

    static func makeGlow(size: Int = 1024,
                          coreRadius: Double = 0.40,
                          falloff: Double = 0.9,
                          tint: (Double, Double, Double) = (0.72, 0.86, 1.0)) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                   width: size,
                                   height: size,
                                   bitsPerComponent: 8,
                                   bytesPerRow: size * 4,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        guard let raw = ctx.data else { return nil }
        let buf = raw.bindMemory(to: UInt8.self, capacity: size * size * 4)

        let cx = Double(size) / 2.0
        let cy = Double(size) / 2.0
        let maxR = Double(size) / 2.0

        for y in 0..<size {
            for x in 0..<size {
                let dx = (Double(x) - cx) / maxR
                let dy = (Double(y) - cy) / maxR
                let d = sqrt(dx * dx + dy * dy)
                if d > 1.0 {
                    let off = (y * size + x) * 4
                    buf[off] = 0; buf[off + 1] = 0; buf[off + 2] = 0; buf[off + 3] = 0
                    continue
                }
                let inner = exp(-pow(d / coreRadius, 2))
                let outer = pow(max(0, 1 - d), 1.0 + falloff) * 0.55
                let intensity = clamp01(inner + outer * 0.7)
                let r = intensity * tint.0
                let g = intensity * tint.1
                let b = intensity * tint.2
                let off = (y * size + x) * 4
                buf[off]     = UInt8(r * 255)
                buf[off + 1] = UInt8(g * 255)
                buf[off + 2] = UInt8(b * 255)
                buf[off + 3] = UInt8(intensity * 255)
            }
        }

        return ctx.makeImage()
    }

    private static func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
}

// MARK: - Noise utilities (shared)

struct ValueNoise {
    private let perm: [UInt8]

    init(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var p: [UInt8] = (0...255).map { UInt8($0) }
        for i in stride(from: p.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            p.swapAt(i, j)
        }
        self.perm = p + p
    }

    private func grad(_ x: Int, _ y: Int, _ z: Int) -> Double {
        let h = Int(perm[(x + Int(perm[(y + Int(perm[z & 255])) & 255])) & 255])
        return Double(h) / 255.0
    }

    func value(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let xi = Int(floor(x)) & 255
        let yi = Int(floor(y)) & 255
        let zi = Int(floor(z)) & 255

        let xf = x - floor(x)
        let yf = y - floor(y)
        let zf = z - floor(z)

        let u = fade(xf)
        let v = fade(yf)
        let w = fade(zf)

        let c000 = grad(xi, yi, zi)
        let c100 = grad(xi + 1, yi, zi)
        let c010 = grad(xi, yi + 1, zi)
        let c110 = grad(xi + 1, yi + 1, zi)
        let c001 = grad(xi, yi, zi + 1)
        let c101 = grad(xi + 1, yi, zi + 1)
        let c011 = grad(xi, yi + 1, zi + 1)
        let c111 = grad(xi + 1, yi + 1, zi + 1)

        let x00 = lerp(c000, c100, u)
        let x10 = lerp(c010, c110, u)
        let x01 = lerp(c001, c101, u)
        let x11 = lerp(c011, c111, u)
        let y0 = lerp(x00, x10, v)
        let y1 = lerp(x01, x11, v)
        return lerp(y0, y1, w)
    }

    func fbm(_ x: Double, _ y: Double, _ z: Double,
             octaves: Int = 4, lacunarity: Double = 2.0, gain: Double = 0.5) -> Double {
        var sum = 0.0
        var amp = 1.0
        var freq = 1.0
        var norm = 0.0
        for _ in 0..<octaves {
            sum += value(x * freq, y * freq, z * freq) * amp
            norm += amp
            amp *= gain
            freq *= lacunarity
        }
        return sum / norm
    }

    private func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed != 0 ? seed : 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
