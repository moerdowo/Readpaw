import Foundation
import AppKit
import CoreGraphics

/// Procedural Moon textures generated entirely in code (no assets shipped).
///
/// `makeSurface` produces an equirectangular albedo map: a fractal-noise base
/// for the highlands, large soft maria from low-frequency noise thresholding,
/// and several hundred craters with darkened floors and bright rims. The
/// craters are positioned in 3D so they wrap cleanly across the seam at
/// lon=±180° without distortion at the poles.
///
/// `makeGlow` is a soft radial gradient for use as a halo plane behind the
/// sphere, drawn with additive blending.
enum MoonTexture {

    private struct Crater {
        let x: Double
        let y: Double
        let z: Double
        let radius: Double      // angular radius (radians)
        let depth: Double       // 0..1, how dark the floor is
        let cosOuter: Double    // cos(radius * 1.5) — culling threshold
        let cosFloor: Double    // cos(radius * 0.75) — inside floor
        let cosRim: Double      // cos(radius)        — outside ejecta
    }

    static func makeSurface(width: Int = 1536,
                            height: Int = 768,
                            seed: UInt64 = 0xCAFE_BABE_F00D) -> CGImage? {
        let w = width, h = height
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

        var rng = SplitMix64(seed: seed)

        // Generate craters with mixed sizes.
        var craters: [Crater] = []
        craters.reserveCapacity(420)
        func addCraters(count: Int, minR: Double, maxR: Double, minDepth: Double, maxDepth: Double) {
            for _ in 0..<count {
                let lat = (Double(rng.next() % 100000) / 100000.0 - 0.5) * .pi
                let lon = Double(rng.next() % 100000) / 100000.0 * 2 * .pi - .pi
                let cosLat = cos(lat)
                let cx = cosLat * cos(lon)
                let cy = sin(lat)
                let cz = cosLat * sin(lon)
                let r = minR + (maxR - minR) * Double(rng.next() % 10000) / 10000.0
                let depth = minDepth + (maxDepth - minDepth) * Double(rng.next() % 10000) / 10000.0
                craters.append(Crater(
                    x: cx, y: cy, z: cz,
                    radius: r,
                    depth: depth,
                    cosOuter: cos(min(.pi, r * 1.5)),
                    cosFloor: cos(min(.pi, r * 0.7)),
                    cosRim:   cos(min(.pi, r))
                ))
            }
        }
        // tiny, abundant
        addCraters(count: 260, minR: 0.005, maxR: 0.014, minDepth: 0.35, maxDepth: 0.55)
        // small-medium
        addCraters(count: 95,  minR: 0.015, maxR: 0.034, minDepth: 0.45, maxDepth: 0.70)
        // medium-large
        addCraters(count: 32,  minR: 0.035, maxR: 0.070, minDepth: 0.55, maxDepth: 0.80)
        // large hero craters
        addCraters(count: 9,   minR: 0.080, maxR: 0.140, minDepth: 0.60, maxDepth: 0.85)
        // very large "basin"-style features
        addCraters(count: 3,   minR: 0.180, maxR: 0.260, minDepth: 0.40, maxDepth: 0.55)

        let surfaceNoise = ValueNoise(seed: seed)
        let mareNoise    = ValueNoise(seed: seed ^ 0x6B79_1357)
        let detailNoise  = ValueNoise(seed: seed ^ 0xACED_BEEF)

        for y in 0..<h {
            let v = Double(y) / Double(h)
            let lat = (0.5 - v) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)

            for x in 0..<w {
                let u = Double(x) / Double(w)
                let lon = (u - 0.5) * 2 * .pi
                let cosLon = cos(lon), sinLon = sin(lon)

                let px = cosLat * cosLon
                let py = sinLat
                let pz = cosLat * sinLon

                // Base highland brightness: mid-grey with fbm variance.
                let baseFBM = surfaceNoise.fbm(px * 3.5, py * 3.5, pz * 3.5, octaves: 4)
                var brightness = 0.66 + (baseFBM - 0.5) * 0.18

                // Mare (dark basalt plains): low-frequency threshold mask.
                let mareFBM = mareNoise.fbm(px * 1.4, py * 1.4, pz * 1.4, octaves: 3, lacunarity: 2.0, gain: 0.55)
                let mareMask = smoothstep(0.56, 0.74, mareFBM)
                brightness *= (1.0 - mareMask * 0.42)
                // Add subtle variation inside maria.
                let mareTexture = detailNoise.fbm(px * 8.0, py * 8.0, pz * 8.0, octaves: 3)
                brightness += mareMask * (mareTexture - 0.5) * 0.06

                // Craters: iterate with early-out using dot product.
                for c in craters {
                    let dot = px * c.x + py * c.y + pz * c.z
                    if dot < c.cosOuter { continue }
                    // Inside outer culling sphere — compute true angular distance.
                    let angle = acos(max(-1.0, min(1.0, dot)))
                    let nd = angle / c.radius // 0 at center, 1 at rim, >1 in ejecta
                    if nd <= 0.7 {
                        // Floor: darken with smooth falloff.
                        let t = (1.0 - nd / 0.7)
                        brightness *= (1.0 - 0.55 * t * c.depth)
                    } else if nd <= 1.0 {
                        // Rim: bright ring (raised crater wall caught in sunlight).
                        let t = (nd - 0.7) / 0.3
                        let rim = sin(t * .pi) // peaks mid-rim
                        brightness *= (1.0 + 0.35 * rim * c.depth)
                    } else if nd <= 1.5 {
                        // Ejecta blanket: subtle brightening fading outward.
                        let t = 1.0 - (nd - 1.0) / 0.5
                        brightness *= (1.0 + 0.06 * t * c.depth)
                    }
                }

                // Limb darkening hint: not really physical on equirect texture,
                // but a touch of latitude darkening adds depth.
                let polarDarken = 1.0 - 0.10 * pow(abs(py), 2.0)
                brightness *= polarDarken

                let g = clamp01(brightness)
                // Slight warm tint in highlands, cool in shadows.
                let warmth = 0.04 * (g - 0.5)
                let r_ = clamp01(g + warmth)
                let g_ = clamp01(g)
                let b_ = clamp01(g - warmth)

                let off = (y * w + x) * 4
                buf[off]     = UInt8(r_ * 255)
                buf[off + 1] = UInt8(g_ * 255)
                buf[off + 2] = UInt8(b_ * 255)
                buf[off + 3] = 255
            }
        }

        return ctx.makeImage()
    }

    static func makeGlow(size: Int = 1024,
                          coreRadius: Double = 0.30,
                          falloff: Double = 1.0,
                          tint: (Double, Double, Double) = (0.92, 0.95, 1.0)) -> CGImage? {
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
                    buf[off] = 0; buf[off+1] = 0; buf[off+2] = 0; buf[off+3] = 0
                    continue
                }
                // Inner sharp core then long soft falloff.
                let inner = exp(-pow(d / coreRadius, 2)) * 1.0
                let outer = pow(max(0, 1 - d), 1.0 + falloff) * 0.45
                let intensity = clamp01(inner + outer * 0.7)
                let r_ = intensity * tint.0
                let g_ = intensity * tint.1
                let b_ = intensity * tint.2
                let off = (y * size + x) * 4
                buf[off]     = UInt8(r_ * 255)
                buf[off + 1] = UInt8(g_ * 255)
                buf[off + 2] = UInt8(b_ * 255)
                buf[off + 3] = UInt8(intensity * 255)
            }
        }
        return ctx.makeImage()
    }

    private static func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
    private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = clamp01((x - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }
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
