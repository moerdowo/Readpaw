import Foundation
import AppKit
import CoreGraphics

/// Generates a stylized equirectangular Earth-like texture entirely in code.
/// Uses 3D value noise sampled on the unit sphere so the texture wraps
/// seamlessly across the seam at lon = ±180°. Continents are land where noise
/// crosses a threshold; oceans get a depth-shaded blue.
enum EarthTexture {

    static func make(width: Int = 1536, height: Int = 768) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        guard let ctx = CGContext(data: nil,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        guard let raw = ctx.data else { return nil }
        let buf = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let noise = ValueNoise(seed: 1729)

        // Northern-hemisphere bias to roughly recall Earth's land/sea ratio.
        let landThreshold: Double = 0.50

        for y in 0..<height {
            let v = Double(y) / Double(height)
            let lat = (0.5 - v) * .pi  // -pi/2 .. pi/2
            let cosLat = cos(lat)
            let sinLat = sin(lat)

            for x in 0..<width {
                let u = Double(x) / Double(width)
                let lon = (u - 0.5) * 2.0 * .pi

                // 3D point on unit sphere — wraps seamlessly.
                let px = cosLat * cos(lon)
                let py = sinLat
                let pz = cosLat * sin(lon)

                // Continent shape: low-frequency fractal noise.
                let continent = noise.fbm(px * 1.6, py * 1.6, pz * 1.6, octaves: 5, lacunarity: 2.0, gain: 0.55)
                // Detail noise for coastlines & texture.
                let detail = noise.fbm(px * 4.5, py * 4.5, pz * 4.5, octaves: 3, lacunarity: 2.0, gain: 0.5)
                let mixed = continent * 0.78 + detail * 0.22

                // Bias by latitude: poles slightly icy.
                let icy = max(0, abs(py) - 0.78) * 5.0
                let isLand = mixed > landThreshold

                let off = (y * width + x) * 4
                let (r, g, b): (UInt8, UInt8, UInt8)

                if icy > 0 {
                    // Polar ice — bias toward white
                    let blend = min(1.0, icy)
                    let baseR = isLand ? 0.85 : 0.78
                    let baseG = isLand ? 0.88 : 0.84
                    let baseB = isLand ? 0.92 : 0.90
                    r = UInt8((baseR * blend + (isLand ? 0.4 : 0.22) * (1 - blend)) * 255)
                    g = UInt8((baseG * blend + (isLand ? 0.5 : 0.36) * (1 - blend)) * 255)
                    b = UInt8((baseB * blend + (isLand ? 0.3 : 0.55) * (1 - blend)) * 255)
                } else if isLand {
                    let elev = (mixed - landThreshold) / (1.0 - landThreshold) // 0..1
                    // Greens lower, browns/highlands higher.
                    let highlandMix = min(1.0, elev * 1.8)
                    let lr = lerp(0.18, 0.48, highlandMix)
                    let lg = lerp(0.42, 0.40, highlandMix)
                    let lb = lerp(0.18, 0.22, highlandMix)
                    // Add detail variance.
                    let dn = (detail - 0.5) * 0.12
                    r = clampByte((lr + dn) * 255)
                    g = clampByte((lg + dn) * 255)
                    b = clampByte((lb + dn * 0.6) * 255)
                } else {
                    // Ocean: deeper means darker blue.
                    let depth = (landThreshold - mixed) / landThreshold // 0..1
                    let or_ = lerp(0.18, 0.04, depth)
                    let og = lerp(0.40, 0.14, depth)
                    let ob = lerp(0.65, 0.30, depth)
                    // Subtle wave detail.
                    let dn = (detail - 0.5) * 0.06
                    r = clampByte((or_ + dn) * 255)
                    g = clampByte((og + dn) * 255)
                    b = clampByte((ob + dn) * 255)
                }

                buf[off]     = r
                buf[off + 1] = g
                buf[off + 2] = b
                buf[off + 3] = 255
            }
        }

        return ctx.makeImage()
    }

    static func makeNSImage(width: Int = 1536, height: Int = 768) -> NSImage? {
        guard let cg = make(width: width, height: height) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    // MARK: - helpers

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func clampByte(_ d: Double) -> UInt8 {
        UInt8(max(0, min(255, d)))
    }
}

/// 3D value noise with fractal Brownian motion. Plenty good for stylized
/// textures; not as smooth as Perlin or Simplex but trivial to implement and
/// has no external deps.
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
