import Foundation
import AppKit
import CoreGraphics

/// Procedural galaxy and starfield textures. Generated in-process so no image
/// assets ship with the binary.
enum GalaxyTexture {

    /// Top-down view of a spiral galaxy: bright warm bulge, multi-arm logarithmic
    /// spiral, soft halo, dust lane darkening. RGBA with premultiplied alpha so
    /// the texture is meant to be drawn with additive blending.
    static func makeSpiral(size: Int = 1024,
                            arms: Int = 4,
                            twist: Double = 3.6,
                            armWidth: Double = 0.32,
                            seed: UInt64 = 0xC0FFEE_1729) -> CGImage? {
        let w = size, h = size
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                   width: w,
                                   height: h,
                                   bitsPerComponent: 8,
                                   bytesPerRow: w * 4,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        guard let raw = ctx.data else { return nil }
        let buf = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)

        let noise = ValueNoise(seed: seed)
        let starNoise = ValueNoise(seed: seed ^ 0xABCD)

        let cx = Double(w) / 2.0
        let cy = Double(h) / 2.0
        let maxR = Double(w) / 2.0 - 6.0

        for y in 0..<h {
            for x in 0..<w {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                let r = sqrt(dx * dx + dy * dy)
                let nr = r / maxR
                let theta = atan2(dy, dx)

                // Soft edge: alpha fades to 0 at and past disc radius.
                let edgeMask = smoothstep(1.05, 0.55, nr) // 1 inside, 0 outside
                if edgeMask <= 0.001 {
                    setPixel(buf: buf, x: x, y: y, w: w, r: 0, g: 0, b: 0, a: 0)
                    continue
                }

                // Distance to nearest spiral arm.
                let logR = log(max(0.04, nr)) * twist
                var minDist = Double.infinity
                for n in 0..<arms {
                    let armPhase = Double(n) * (2 * .pi / Double(arms))
                    var diff = theta - logR - armPhase
                    diff = atan2(sin(diff), cos(diff))
                    minDist = min(minDist, abs(diff))
                }
                let armCore = exp(-pow(minDist / armWidth, 2))

                // Bulge: bright dense center, exponentially decaying.
                let bulge = exp(-pow(nr * 3.2, 2)) * 1.2
                // Halo: gentle wide glow filling the disc.
                let halo = exp(-pow(nr * 1.4, 2)) * 0.30

                // Detail: dust clumps + arm break-up.
                let detail = noise.fbm(Double(x) * 0.008, Double(y) * 0.008, 0, octaves: 5,
                                       lacunarity: 2.0, gain: 0.55)
                let detailFactor = 0.55 + (detail - 0.5) * 1.1

                // Slight radial falloff for arm brightness.
                let armBrightness = armCore * smoothstep(0.0, 0.18, nr) * (0.55 + detailFactor * 0.7) * (1.0 - 0.35 * nr)

                // Star sparkle inside the disc.
                let sparkleNoise = starNoise.value(Double(x) * 0.5, Double(y) * 0.5, 0)
                let sparkle = pow(max(0, sparkleNoise - 0.88), 3.0) * 90.0

                let armComp = armBrightness * 1.55
                let bulgeComp = bulge
                let haloComp = halo
                let total = armComp + bulgeComp + haloComp + sparkle

                // Color: bulge warm, arms cool blue/violet, halo faint indigo.
                // tWarm = how much bulge dominates this pixel.
                let tWarm = clamp01(bulgeComp / (bulgeComp + armComp + haloComp + 0.001))

                // Cool palette (arms): blue-violet with slight gradient by radius.
                let armR = lerp(0.55, 0.30, nr)
                let armG = lerp(0.58, 0.38, nr)
                let armB = lerp(1.00, 0.95, nr)
                // Warm palette (bulge): white-yellow.
                let warmR = 1.00
                let warmG = 0.92
                let warmB = 0.72

                var r_ = lerp(armR, warmR, tWarm) * total
                var g_ = lerp(armG, warmG, tWarm) * total
                var b_ = lerp(armB, warmB, tWarm) * total

                // Dust lanes: subtract a bit where detailNoise is low and we're in an arm.
                let dust = max(0, (0.42 - detail)) * armCore * 0.95
                r_ -= dust * 0.85
                g_ -= dust * 0.80
                b_ -= dust * 0.70

                let alpha = clamp01(total * 1.05) * edgeMask
                r_ = clamp01(r_) * alpha
                g_ = clamp01(g_) * alpha
                b_ = clamp01(b_) * alpha

                setPixel(buf: buf, x: x, y: y, w: w,
                         r: UInt8(r_ * 255),
                         g: UInt8(g_ * 255),
                         b: UInt8(b_ * 255),
                         a: UInt8(alpha * 255))
            }
        }

        return ctx.makeImage()
    }

    /// A scattered starfield with size + color variation, transparent background.
    /// Drawn with additive blending behind the galaxy disc.
    static func makeStarfield(size: Int = 1024,
                               density: Int = 850,
                               seed: UInt64 = 0xFEEDFACE_C0DE) -> CGImage? {
        let w = size, h = size
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                   width: w,
                                   height: h,
                                   bitsPerComponent: 8,
                                   bytesPerRow: w * 4,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Start fully transparent.
        ctx.setFillColor(NSColor.clear.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        var rng = SplitMix64(seed: seed)
        for _ in 0..<density {
            let x = Double(rng.next() % UInt64(w))
            let y = Double(rng.next() % UInt64(h))
            // Size: most stars tiny, a few larger.
            let roll = Double(rng.next() % 1000) / 1000.0
            let radius: Double
            let brightness: Double
            if roll > 0.985 {
                radius = 2.6 + Double(rng.next() % 8) / 10.0
                brightness = 1.0
            } else if roll > 0.93 {
                radius = 1.8
                brightness = 0.85
            } else if roll > 0.65 {
                radius = 1.1
                brightness = 0.65
            } else {
                radius = 0.7
                brightness = 0.4
            }
            // Color tint: most white, a few warm or blue.
            let tint = Int(rng.next() % 100)
            let (r, g, b): (Double, Double, Double)
            switch tint {
            case 0..<6:   (r, g, b) = (1.0, 0.78, 0.55) // warm
            case 6..<14:  (r, g, b) = (0.7, 0.85, 1.0)  // cool
            default:      (r, g, b) = (1.0, 1.0, 1.0)   // white
            }
            // Glow disc + bright core.
            let glowRadius = radius * 3.0
            for ny in Int(y - glowRadius)...Int(y + glowRadius) {
                guard ny >= 0, ny < h else { continue }
                for nx in Int(x - glowRadius)...Int(x + glowRadius) {
                    guard nx >= 0, nx < w else { continue }
                    let dx = Double(nx) - x
                    let dy = Double(ny) - y
                    let d = sqrt(dx * dx + dy * dy)
                    if d > glowRadius { continue }
                    // Soft falloff: core is bright, halo soft.
                    let core = exp(-pow(d / radius, 2)) * brightness
                    let outer = exp(-pow(d / glowRadius, 2)) * 0.25 * brightness
                    let intensity = min(1.0, core + outer)
                    if intensity < 0.01 { continue }
                    let off = (ny * w + nx) * 4
                    let existingR = Double(ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)[off]) / 255.0
                    let existingG = Double(ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)[off + 1]) / 255.0
                    let existingB = Double(ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)[off + 2]) / 255.0
                    let existingA = Double(ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)[off + 3]) / 255.0
                    let newR = min(1.0, existingR + r * intensity)
                    let newG = min(1.0, existingG + g * intensity)
                    let newB = min(1.0, existingB + b * intensity)
                    let newA = min(1.0, existingA + intensity)
                    let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
                    buf[off] = UInt8(newR * 255)
                    buf[off + 1] = UInt8(newG * 255)
                    buf[off + 2] = UInt8(newB * 255)
                    buf[off + 3] = UInt8(newA * 255)
                }
            }
        }

        return ctx.makeImage()
    }

    // MARK: - Helpers

    private static func setPixel(buf: UnsafeMutablePointer<UInt8>,
                                  x: Int, y: Int, w: Int,
                                  r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let off = (y * w + x) * 4
        buf[off] = r
        buf[off + 1] = g
        buf[off + 2] = b
        buf[off + 3] = a
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp01((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Noise (formerly in EarthTexture; kept generic for reuse)

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
