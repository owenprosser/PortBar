// PortBar icon renderer: a tiny signed-distance-field ray marcher that renders a glossy ceramic
// server stack and the supporting layers (shadow, glow, streaks, backlight) as transparent PNGs.
//
//   swiftc -swift-version 5 -O render.swift -o render
//   ./render <outDir> [size=1024] [samples=3] [yawDeg] [pitchDeg] [rollDeg] [viewHalfSize]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Look-development knobs: any of these can be overridden with an environment variable.
func tunable(_ name: String, _ def: Float) -> Float {
    if let v = ProcessInfo.processInfo.environment[name], let f = Float(v) { return f }
    return def
}

// MARK: - Small vector maths

struct V3 {
    var x: Float, y: Float, z: Float
    init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
    static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: V3, s: Float) -> V3 { V3(a.x * s, a.y * s, a.z * s) }
    static func * (s: Float, a: V3) -> V3 { a * s }
    static func * (a: V3, b: V3) -> V3 { V3(a.x * b.x, a.y * b.y, a.z * b.z) }
    static prefix func - (a: V3) -> V3 { V3(-a.x, -a.y, -a.z) }
}
@inline(__always) func dot(_ a: V3, _ b: V3) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
@inline(__always) func len(_ a: V3) -> Float { dot(a, a).squareRoot() }
@inline(__always) func norm(_ a: V3) -> V3 { a * (1 / max(len(a), 1e-9)) }
@inline(__always) func cross(_ a: V3, _ b: V3) -> V3 { V3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) }
@inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }
@inline(__always) func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func mixv(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
@inline(__always) func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clampf((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t)
}

// MARK: - Arguments

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "out"
let N = args.count > 2 ? Int(args[2])! : 1024
let SS = args.count > 3 ? Int(args[3])! : 3
let yaw = (args.count > 4 ? Float(args[4])! : -26) * .pi / 180
let pitch = (args.count > 5 ? Float(args[5])! : 22) * .pi / 180
let roll = (args.count > 6 ? Float(args[6])! : -30) * .pi / 180
let viewHalf: Float = args.count > 7 ? Float(args[7])! : 1.68
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: - Tunables (see `tunable` above)

let kKey = tunable("KEY", 2.1), kFill = tunable("FILL", 0.25), kAmb = tunable("AMB", 0.40)
let kAlbedo = tunable("ALBEDO", 1.0), kDiffuse = tunable("DIFFUSE", 0.45)
let kFall = tunable("FALL", 0.22), kRefl = tunable("REFL", 1.5)
let kOutline = tunable("OUTLINE", 0.7), kExpo = tunable("EXPO", 0.85)
let kSpec = tunable("SPEC", 1.8)
let kLidGrad = tunable("LIDGRAD", 0.55)
let kSheen = tunable("SHEEN", 2.4), kSheenPos = tunable("SHEENPOS", 0.10), kBounce = tunable("BOUNCE", 0.8)
let kGrain = tunable("GRAIN", 0.10), kGrainFreq = tunable("GRAINFREQ", 420)
let layerMax = Int(tunable("LAYERMAX", 2))
let shiftX = tunable("SHIFTX", 0), shiftY = tunable("SHIFTY", 0)
let ledScale = tunable("LEDSCALE", 1.2)

// MARK: - Camera (orthographic)

let toCam = V3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))   // origin -> camera
let fwd = -toCam
let right0 = norm(cross(fwd, V3(0, 1, 0)))
let up0 = cross(right0, fwd)
let camRight = right0 * cos(roll) + up0 * sin(roll)
let camUp = -right0 * sin(roll) + up0 * cos(roll)
let toViewer = -fwd

// MARK: - Scene: three Xserve-style 1U units
//
// Every feature below is positioned from measurements of the front plate of an Xserve (G4 slot-load /
// G5): thumbscrews at both ends; a control strip along the top (three round buttons, a port, two
// LEDs, a block of fine perforations and two rows of vent slots with a gap in the middle, then a long
// optical-drive slot); and, below, raised drive carriers separated by dark recessed vent windows.
// The Apple logo that sits in that gap is deliberately left out.

let uh = tunable("UNITH", 1.3)                                   // taller-than-1U multiplier
let hx: Float = 1.10, hy: Float = 0.150 * uh, hz: Float = 0.60   // half extents of one unit
let slabR: Float = 0.028
let unitPitch: Float = 2 * hy + 0.038
let slabYs: [Float] = [unitPitch, 0, -unitPitch]

/// Horizontal position from a fraction of the plate width (0 = left edge, 1 = right edge).
@inline(__always) func fxp(_ f: Float) -> Float { (f - 0.5) * 2 * hx }

let stripY: Float = 0.094 * uh
let bayTop: Float = 0.034 * uh, bayBottom: Float = -0.140 * uh
let bayMidY: Float = (bayTop + bayBottom) / 2
let bayHalfH: Float = (bayTop - bayBottom) / 2

struct Bay { let cx: Float, hw: Float; let vent: Bool }
let bays: [Bay] = [
    (0.045, 0.273, false), (0.277, 0.382, true), (0.386, 0.616, false), (0.620, 0.725, true), (0.730, 0.955, false),
].map { Bay(cx: fxp(($0.0 + $0.1) / 2), hw: ($0.1 - $0.0) * hx, vent: $0.2) }

struct LED { let x: Float, y: Float, r: Float, z: Float }
let stripLEDs = [LED(x: fxp(0.226), y: stripY + 0.026, r: 0.0115, z: 0), LED(x: fxp(0.226), y: stripY - 0.013, r: 0.0115, z: 0)]
let bayLEDs: [LED] = bays.filter { !$0.vent }.map { LED(x: $0.cx - $0.hw + 0.040, y: -0.006 * uh, r: 0.0150, z: 0.014) }
let allLEDs: [LED] = stripLEDs + bayLEDs
let heroLED = bayLEDs[0]                                    // the one that blooms: top unit, first drive bay

let buttonXs: [Float] = [fxp(0.074), fxp(0.110), fxp(0.142)]
let portX = fxp(0.190)
let dotX0 = fxp(0.248), dotPitch: Float = 0.021, dotCols = 7
let slotsA = (x0: fxp(0.318), pitch: Float(0.0290), count: 13)
let slotsB = (x0: fxp(0.527), pitch: Float(0.0304), count: 11)
let opticalX = fxp(0.822), opticalHalfW: Float = 0.293, opticalY: Float = 0.124 * uh
let screwX = hx - 0.052

@inline(__always) func sdRoundBox(_ p: V3, _ b: V3, _ r: Float) -> Float {
    let q = V3(abs(p.x) - b.x + r, abs(p.y) - b.y + r, abs(p.z) - b.z + r)
    let m = V3(max(q.x, 0), max(q.y, 0), max(q.z, 0))
    return len(m) + min(max(q.x, max(q.y, q.z)), 0) - r
}
/// Cylinder along z, centred at z = zc, half length hh, with rounded edges.
@inline(__always) func sdRoundCylZ(_ ax: Float, _ ay: Float, _ az: Float, _ r: Float, _ hh: Float, _ rr: Float) -> Float {
    let rad = (ax * ax + ay * ay).squareRoot() - r + rr
    let h = abs(az) - hh + rr
    return (max(rad, 0) * max(rad, 0) + max(h, 0) * max(h, 0)).squareRoot() + min(max(rad, h), 0) - rr
}

@inline(__always) func slabDist(_ p: V3, _ i: Int) -> Float {
    let q = V3(p.x, p.y - slabYs[i], p.z)
    var d = sdRoundBox(q, V3(hx, hy, hz), slabR)
    // Everything below lives on the front (+z) face.
    guard q.z > hz - 0.16 && d < 0.16 && abs(q.y) < hy + 0.03 else { return d }
    let fz = q.z - hz

    // drive carriers stand proud of the plate; vent windows are recessed
    for b in bays {
        let lx = q.x - b.cx, ly = q.y - bayMidY
        if abs(lx) > b.hw + 0.02 { continue }
        if b.vent {
            var w = sdRoundBox(V3(lx, ly, fz), V3(b.hw - 0.004, bayHalfH - 0.004, 0.075), 0.010)
            d = max(d, -w)
            // louvres: thin horizontal slats inside the window, so it reads as mesh and not a black hole
            let rib = (ly / 0.027).rounded()
            if abs(rib) <= 3 {
                w = sdRoundBox(V3(lx, ly - rib * 0.027, fz + 0.048), V3(b.hw - 0.010, 0.0055, 0.020), 0.003)
                d = min(d, max(w, sdRoundBox(V3(lx, ly, fz), V3(b.hw - 0.002, bayHalfH - 0.002, 0.075), 0.010)))
            }
        } else {
            d = min(d, sdRoundBox(V3(lx, ly, fz), V3(b.hw - 0.003, bayHalfH - 0.003, 0.014), 0.010))
        }
    }

    // control strip
    let sy = q.y - stripY
    if abs(sy) < 0.06 * uh {
        // three round buttons: a ring recess, a dome, and a diagonal slit across the dome
        for bx in buttonXs {
            let ax = q.x - bx
            let rr = (ax * ax + sy * sy).squareRoot()
            if rr < 0.040 {
                d = max(d, -max(rr - 0.029, abs(fz) - 0.013))
                d = min(d, sdRoundCylZ(ax, sy, fz + 0.012, 0.0215, 0.012, 0.006))
                let c: Float = 0.8191, s: Float = 0.5736                      // slit rotated 35 degrees
                let u = ax * c + sy * s, v = -ax * s + sy * c
                d = max(d, -sdRoundBox(V3(u, v, fz), V3(0.019, 0.0028, 0.010), 0.002))
            }
        }
        // port: a dark rounded recess
        d = max(d, -sdRoundBox(V3(q.x - portX, sy, fz), V3(0.044, 0.0165, 0.045), 0.008))
        // fine perforations: 7 x 3 round holes
        if q.x > dotX0 - 0.015 && q.x < dotX0 + dotPitch * Float(dotCols - 1) + 0.015 {
            let cx = clampf(((q.x - dotX0) / dotPitch).rounded(), 0, Float(dotCols - 1))
            let cy = clampf((sy / 0.024).rounded(), -1, 1)
            let hxp = q.x - (dotX0 + cx * dotPitch), hyp = sy - cy * 0.024
            d = max(d, -max((hxp * hxp + hyp * hyp).squareRoot() - 0.0068, abs(fz) - 0.030))
        }
        // two rows of vent slots
        for s in [slotsA, slotsB] {
            if q.x > s.x0 - 0.02 && q.x < s.x0 + s.pitch * Float(s.count - 1) + 0.02 {
                let cx = clampf(((q.x - s.x0) / s.pitch).rounded(), 0, Float(s.count - 1))
                let lx = q.x - (s.x0 + cx * s.pitch)
                d = max(d, -sdRoundBox(V3(lx, sy, fz), V3(0.0045, 0.024, 0.040), 0.003))
            }
        }
        // optical drive: a shallow bezel and a long slot
        let ox = q.x - opticalX, oy = q.y - opticalY
        d = max(d, -sdRoundBox(V3(ox, oy, fz), V3(opticalHalfW, 0.0145, 0.008), 0.006))
        d = max(d, -sdRoundBox(V3(ox, oy, fz), V3(opticalHalfW - 0.010, 0.0065, 0.070), 0.004))
    }

    // LEDs: a small recess with the lens sitting in it
    for led in allLEDs {
        let ax = q.x - led.x, ay = q.y - led.y
        if abs(ax) > 0.04 || abs(ay) > 0.04 { continue }
        let rr = (ax * ax + ay * ay).squareRoot()
        let lz = fz - led.z
        d = max(d, -max(rr - (led.r + 0.006), abs(lz) - 0.014))
        d = min(d, max(rr - led.r, abs(lz + 0.010) - 0.006))
    }

    // rack-ear thumbscrews
    for sgn in [Float(-1), 1] {
        d = min(d, sdRoundCylZ(q.x - sgn * screwX, q.y, fz - 0.026, 0.040, 0.034, 0.014))
    }
    return d
}

@inline(__always) func mapScene(_ p: V3) -> Float {
    min(slabDist(p, 0), min(slabDist(p, 1), slabDist(p, 2)))
}

enum Mat { case metal, steel, mesh, void, ledLit }

/// Which material a surface point belongs to, which unit it is on, and an LED strength.
func classify(_ p: V3) -> (Mat, Int, Float) {
    var best = 0; var bd = Float.greatestFiniteMagnitude
    for i in 0..<3 { let d = slabDist(p, i); if d < bd { bd = d; best = i } }
    let q = V3(p.x, p.y - slabYs[best], p.z)
    let fz = q.z - hz
    // thumbscrews
    if fz > 0.016 && abs(abs(q.x) - screwX) < 0.046 && abs(q.y) < 0.046 { return (.steel, best, 1) }
    // LEDs
    for (k, led) in allLEDs.enumerated() where fz - led.z < 0.002 && fz - led.z > -0.040 {
        do {
            let ax = q.x - led.x, ay = q.y - led.y
            if (ax * ax + ay * ay).squareRoot() < led.r + 0.0015 {
                let hero = best == 0 && k == stripLEDs.count
                return (.ledLit, best, hero ? 1.5 : (best == 0 ? 0.95 : 0.75))
            }
        }
    }
    // dark interiors: only on the flat face, not on the plate's rounded edge
    if fz < -0.010 && abs(q.x) < hx - 0.04 && abs(q.y) < hy - 0.022 {
        for b in bays where b.vent && abs(q.x - b.cx) < b.hw - 0.002 && abs(q.y - bayMidY) < bayHalfH - 0.002 {
            return (fz > -0.044 ? .mesh : .void, best, 1)
        }
        return (.void, best, 1)
    }
    return (.metal, best, 1)
}

func normalAt(_ p: V3) -> V3 {
    let e: Float = 0.0010
    let dx = mapScene(V3(p.x + e, p.y, p.z)) - mapScene(V3(p.x - e, p.y, p.z))
    let dy = mapScene(V3(p.x, p.y + e, p.z)) - mapScene(V3(p.x, p.y - e, p.z))
    let dz = mapScene(V3(p.x, p.y, p.z + e)) - mapScene(V3(p.x, p.y, p.z - e))
    return norm(V3(dx, dy, dz))
}

func ambientOcclusion(_ p: V3, _ n: V3) -> Float {
    var occ: Float = 0, w: Float = 1
    for i in 1...6 {
        let h = 0.03 * Float(i)
        occ += (h - mapScene(p + n * h)) * w
        w *= 0.78
    }
    return clampf(1 - 1.5 * occ, 0, 1)
}

func softShadow(_ o: V3, _ l: V3, _ k: Float) -> Float {
    var res: Float = 1, t: Float = 0.02
    for _ in 0..<40 {
        let h = mapScene(o + l * t)
        if h < 0.0004 { return 0 }
        res = min(res, k * h / t)
        t += clampf(h, 0.01, 0.2)
        if t > 3 { break }
    }
    return clampf(res, 0, 1)
}

// MARK: - Lighting (lights are defined relative to the camera so highlights stay put under roll)

let lKey = norm(camRight * -0.55 + camUp * 0.85 + toViewer * 0.55)
let lFill = norm(camRight * 0.9 + camUp * 0.15 + toViewer * 0.45)
let keyPos = camRight * -3.4 + camUp * 4.2 + toViewer * 3.2
let fillPos = camRight * 4.6 + camUp * 0.8 + toViewer * 3.0
let shadeCamPos = toCam * tunable("CAMDIST", 2.3)
let ledPos = V3(heroLED.x, heroLED.y + slabYs[0], hz + heroLED.z + 0.03)

/// A soft studio for satin metal: a bright ceiling, a dark floor, a broad key soft-box and a strip light.
func environment(_ r: V3) -> V3 {
    let ry = dot(r, camUp)
    let base = mixf(0.07, 0.95, smooth(-0.35, 0.75, ry))
    let key = pow(max(dot(r, lKey), 0), 4) * 1.45
    let strip = pow(max(dot(r, lFill), 0), 9) * 0.65
    let horizon = exp(-((ry - 0.04) / 0.07) * ((ry - 0.04) / 0.07)) * 0.16
    return V3(base + key + strip + horizon, base + key + strip + horizon, (base + key + strip + horizon) * 1.03)
}

func tone(_ c0: V3) -> V3 {
    let c = c0 * kExpo
    func f(_ x: Float) -> Float {
        let a = x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14)   // ACES approximation
        return pow(clampf(a, 0, 1), 1 / 2.2)
    }
    return V3(f(c.x), f(c.y), f(c.z))
}

@inline(__always) func hash1(_ x: Float) -> Float {
    let s = sin(x * 127.1) * 43758.5453
    return s - s.rounded(.down)
}

func shade(_ p: V3, _ n0: V3, _ info: (Mat, Int, Float)) -> V3 {
    let v = norm(shadeCamPos - p)
    var n = n0
    let (mat, unit, strength) = info
    let ao = ambientOcclusion(p, n)

    switch mat {
    case .ledLit:
        let ndv = max(dot(n, v), 0)
        let refl = n * (2 * dot(n, v)) - v
        let q = V3(p.x, p.y - slabYs[unit], 0)
        _ = q
        let glass = environment(refl) * (0.05 + 0.4 * pow(1 - ndv, 4))
        let emit = V3(0.02, 0.95, 0.20) * (1.25 * strength)
        return emit + glass
    case .mesh:
        // dark gunmetal slats catching a little light
        let ndv = max(dot(n, v), 0)
        let refl = n * (2 * dot(n, v)) - v
        let toKey = keyPos - p, lk = norm(toKey)
        let lit = max(dot(n, lk), 0)
        return (V3(0.030, 0.032, 0.038) * (0.5 + 1.6 * lit) + environment(refl) * (0.10 + 0.25 * pow(1 - ndv, 3))) * ao
    case .void:
        let ndv = max(dot(n, v), 0)
        let refl = n * (2 * dot(n, v)) - v
        return V3(0.010, 0.011, 0.013) * ao + environment(refl) * (0.03 + 0.20 * pow(1 - ndv, 3)) * ao
    case .metal, .steel:
        // Brushed grain: horizontal streaks, from a tiny vertical wobble of the normal.
        let grain = hash1((p.y - slabYs[unit]) * kGrainFreq + Float(unit) * 13.7) - 0.5
        let broad = hash1((p.y - slabYs[unit]) * kGrainFreq * 0.11 + 5.3) - 0.5
        n = norm(n + V3(0, 1, 0) * ((grain * 0.65 + broad * 0.9) * kGrain))
        let ndv = max(dot(n, v), 0)
        let refl = n * (2 * dot(n, v)) - v

        let toKey = keyPos - p, dKey = len(toKey), lk = toKey * (1 / dKey)
        let toFill = fillPos - p, dFill = len(toFill), lf = toFill * (1 / dFill)
        let sh = softShadow(p + n * 0.004, lk, 9)
        let keyFall = 1 / (1 + kFall * dKey * dKey) * 2.2
        let fillFall = 1 / (1 + 0.020 * dFill * dFill) * 2.0
        let key = max((dot(n, lk) + 0.25) / 1.25, 0) * sh * keyFall
        let fill = max((dot(n, lf) + 0.4) / 1.4, 0) * fillFall
        let sky = 0.5 + 0.5 * dot(n, camUp)
        let ambient = mixv(V3(0.09, 0.095, 0.115), V3(0.42, 0.44, 0.48), sky)

        let isSteel = mat == .steel
        let albedo = isSteel ? V3(0.34, 0.345, 0.36) : V3(0.80, 0.81, 0.83) * kAlbedo
        // a little matte body colour
        var col = albedo * kDiffuse * (V3(1.0, 0.975, 0.94) * (key * kKey * (0.55 + 0.45 * ao))
                                        + V3(0.80, 0.88, 1.0) * (fill * kFill * ao)
                                        + ambient * kAmb * ao)
        // satin metal reflection of the studio
        let f0: V3 = isSteel ? V3(0.55, 0.56, 0.58) : V3(0.90, 0.91, 0.93)
        let fres = f0 + (V3(1, 1, 1) - f0) * pow(1 - ndv, 5)
        col = col + environment(refl) * fres * (kRefl * (0.30 + 0.70 * ao) * (0.45 + 0.55 * sh))
        // crisp specular lines where the key light catches an edge
        let hv = norm(lk + v)
        col = col + V3(1.0, 0.98, 0.96) * (pow(max(dot(n, hv), 0), 140) * kSpec * sh * (0.4 + 0.6 * ao))
        // a broad soft-box sheen sweeping diagonally across the up-facing lids
        let upn = max(n0.y, 0); let top = upn * upn * upn * upn
        let along = p.x * 0.80 + p.z * 0.60
        let band = exp(-((along - kSheenPos) / 0.45) * ((along - kSheenPos) / 0.45)) * 0.26
                 + exp(-((along + 0.55) / 0.08) * ((along + 0.55) / 0.08)) * 0.12
        col = col + V3(1.0, 1.0, 1.0) * (band * top * kSheen * sh * ao)
        // a long diagonal light gradient across the lids: brighter at the near end, falling away
        col = col * (1 + top * kLidGrad * 1.4 * (0.5 - smooth(-0.9, 1.1, along)))
        // a cool contour where the surface turns away from the camera, like Flighty's plane
        let edge = smooth(0.04, 0.34, ndv)
        col = mixv(V3(0.17, 0.18, 0.22), col, 1 - (1 - edge) * kOutline)
        // green bounce from the hero LED
        let toLed = ledPos - p
        let dist = len(toLed)
        let bounce = max(dot(n, norm(toLed)), 0) / (1 + (dist / 0.20) * (dist / 0.20))
        col = col + V3(0.10, 0.95, 0.35) * (bounce * kBounce)
        return col
    }
}

// MARK: - Trace

let boxMin = V3(-1.25, -0.56 * uh, -0.75), boxMax = V3(1.25, 0.56 * uh, 0.75)

func traceSample(_ px: Float, _ py: Float) -> (V3, Float) {
    let u = (px / Float(N) * 2 - 1) * viewHalf + shiftX
    let v = (1 - py / Float(N) * 2) * viewHalf + shiftY
    let o = toCam * 8 + camRight * u + camUp * v
    let d = fwd
    // ray / box
    var tNear: Float = -1e9, tFar: Float = 1e9
    for axis in 0..<3 {
        let oo = axis == 0 ? o.x : (axis == 1 ? o.y : o.z)
        let dd = axis == 0 ? d.x : (axis == 1 ? d.y : d.z)
        let lo = axis == 0 ? boxMin.x : (axis == 1 ? boxMin.y : boxMin.z)
        let hi = axis == 0 ? boxMax.x : (axis == 1 ? boxMax.y : boxMax.z)
        if abs(dd) < 1e-8 { if oo < lo || oo > hi { return (V3(0, 0, 0), 0) } }
        else {
            var t0 = (lo - oo) / dd, t1 = (hi - oo) / dd
            if t0 > t1 { swap(&t0, &t1) }
            tNear = max(tNear, t0); tFar = min(tFar, t1)
        }
    }
    if tNear > tFar { return (V3(0, 0, 0), 0) }
    var t = tNear
    for _ in 0..<160 {
        let p = o + d * t
        let h = mapScene(p)
        if h < 0.0005 {
            let info = classify(p)
            if info.1 > layerMax { return (V3(0, 0, 0), 0) }   // a unit that belongs to a lower layer
            let n = normalAt(p)
            let c = shade(p, n, info)
            return (tone(c), 1)
        }
        t += h * 0.9
        if t > tFar { break }
    }
    return (V3(0, 0, 0), 0)
}

// MARK: - Render the object layer

let pixelCount = N * N
var object = [Float](repeating: 0, count: pixelCount * 4)   // premultiplied RGBA
let start = Date()
object.withUnsafeMutableBufferPointer { buf in
    let base = buf.baseAddress!
    DispatchQueue.concurrentPerform(iterations: N) { y in
        for x in 0..<N {
            var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
            for sy in 0..<SS { for sx in 0..<SS {
                let (c, al) = traceSample(Float(x) + (Float(sx) + 0.5) / Float(SS), Float(y) + (Float(sy) + 0.5) / Float(SS))
                r += c.x; g += c.y; b += c.z; a += al
            } }
            let inv = 1 / Float(SS * SS)
            let i = (y * N + x) * 4
            base[i] = r * inv; base[i + 1] = g * inv; base[i + 2] = b * inv; base[i + 3] = a * inv
        }
    }
}
FileHandle.standardError.write("object rendered in \(String(format: "%.1f", Date().timeIntervalSince(start)))s\n".data(using: .utf8)!)

// MARK: - 2D helpers for the supporting layers

func boxBlur(_ src: [Float], _ w: Int, _ h: Int, _ radius: Int, passes: Int = 3) -> [Float] {
    var a = src, b = [Float](repeating: 0, count: src.count)
    let win = Float(2 * radius + 1)
    for _ in 0..<passes {
        for y in 0..<h {                       // horizontal
            var acc: Float = 0
            for x in -radius...radius { acc += a[y * w + min(max(x, 0), w - 1)] }
            for x in 0..<w {
                b[y * w + x] = acc / win
                acc += a[y * w + min(x + radius + 1, w - 1)] - a[y * w + max(x - radius, 0)]
            }
        }
        for x in 0..<w {                       // vertical
            var acc: Float = 0
            for y in -radius...radius { acc += b[min(max(y, 0), h - 1) * w + x] }
            for y in 0..<h {
                a[y * w + x] = acc / win
                acc += b[min(y + radius + 1, h - 1) * w + x] - b[max(y - radius, 0) * w + x]
            }
        }
    }
    return a
}

func writePNG(_ premult: [Float], _ name: String) {
    var bytes = [UInt8](repeating: 0, count: N * N * 4)
    for i in 0..<(N * N) {
        for c in 0..<4 {
            // tiny ordered noise so smooth gradients don't band
            let nz = Float((i &* 2654435761 &+ c &* 40503) & 255) / 255 - 0.5
            let v = premult[i * 4 + c] * 255 + nz * 0.9
            bytes[i * 4 + c] = UInt8(clampf(v.rounded(), 0, 255))
        }
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    bytes.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: N, height: N, bitsPerComponent: 8, bytesPerRow: N * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}

func project(_ p: V3) -> (Float, Float) {
    let u = (dot(p, camRight) - shiftX) / viewHalf, v = (dot(p, camUp) - shiftY) / viewHalf
    return ((u * 0.5 + 0.5) * Float(N), (0.5 - v * 0.5) * Float(N))
}

let S = Float(N) / 1024      // so pixel sizes below are written for a 1024 canvas

// object.png
writePNG(object, "object.png")

// shadow.png: soft contact + wide drop shadow from the object's silhouette
do {
    var alpha = [Float](repeating: 0, count: pixelCount)
    for i in 0..<pixelCount { alpha[i] = object[i * 4 + 3] }
    func shifted(_ dx: Int, _ dy: Int) -> [Float] {
        var out = [Float](repeating: 0, count: pixelCount)
        for y in 0..<N { for x in 0..<N {
            let sx = x - dx, sy = y - dy
            if sx >= 0 && sx < N && sy >= 0 && sy < N { out[y * N + x] = alpha[sy * N + sx] }
        } }
        return out
    }
    let wide = boxBlur(shifted(Int(30 * S), Int(46 * S)), N, N, Int(18 * S))
    let tight = boxBlur(shifted(Int(8 * S), Int(14 * S)), N, N, Int(6 * S))
    var out = [Float](repeating: 0, count: pixelCount * 4)
    for i in 0..<pixelCount {
        let a = clampf(wide[i] * 0.55 + tight[i] * 0.35, 0, 0.8)
        out[i * 4 + 3] = a            // black, premultiplied => rgb stays 0
    }
    writePNG(out, "shadow.png")
}

// glow.png: LED bloom
do {
    let (cx, cy) = project(ledPos)
    var out = [Float](repeating: 0, count: pixelCount * 4)
    for y in 0..<N { for x in 0..<N {
        let dx = (Float(x) + 0.5 - cx) / S, dy = (Float(y) + 0.5 - cy) / S
        let r2 = dx * dx + dy * dy
        let g = ledScale
        let wide = 0.42 * exp(-r2 / (2 * 78 * g * 78 * g))
        let mid = 0.50 * exp(-r2 / (2 * 30 * g * 30 * g))
        let core = 0.50 * exp(-r2 / (2 * 11 * g * 11 * g))
        let a = clampf(wide + mid + core, 0, 0.95)
        let col = V3(0.18, 1.0, 0.45)
        let i = (y * N + x) * 4
        out[i] = col.x * a; out[i + 1] = col.y * a; out[i + 2] = col.z * a; out[i + 3] = a * 0.9
    } }
    writePNG(out, "glow.png")
}

// streaks.png: faint diagonal "data" streaks running along the stack's long axis
do {
    let ax = V3(1, 0, 0)
    var dir = (dot(ax, camRight), -dot(ax, camUp))                // screen dir of the long axis (y down)
    let dl = (dir.0 * dir.0 + dir.1 * dir.1).squareRoot(); dir = (dir.0 / dl, dir.1 / dl)
    let perp = (-dir.1, dir.0)
    let c = Float(N) / 2
    // (perpendicular offset, along offset, half length, half width, alpha)
    let streaks: [(Float, Float, Float, Float, Float)] = [
        (-300, -120, 330, 9, 0.20), (-185, -210, 420, 15, 0.26), (-70, -260, 380, 7, 0.16),
        (95, -190, 400, 12, 0.22), (215, -120, 300, 8, 0.16), (320, -60, 250, 14, 0.14),
    ]
    var out = [Float](repeating: 0, count: pixelCount * 4)
    for y in 0..<N { for x in 0..<N {
        let px = (Float(x) + 0.5 - c) / S, py = (Float(y) + 0.5 - c) / S
        let along = px * dir.0 + py * dir.1, across = px * perp.0 + py * perp.1
        var a: Float = 0
        for (po, ao, hl, hw, amp) in streaks {
            let t = (along - ao) / hl
            if abs(t) >= 1 { continue }
            let env = (1 - t * t) * (1 - t * t)
            let d = (across - po) / hw
            a += amp * env * exp(-d * d * 0.9)
        }
        a = clampf(a, 0, 0.5)
        let col = V3(0.80, 0.86, 1.0)
        let i = (y * N + x) * 4
        out[i] = col.x * a; out[i + 1] = col.y * a; out[i + 2] = col.z * a; out[i + 3] = a
    } }
    writePNG(out, "streaks.png")
}

// backlight.png: a soft pool of light behind the object
let blX = tunable("BLX", -60), blY = tunable("BLY", -70), blR = tunable("BLR", 380), blStrength = tunable("BACKLIGHT", 0.34)
let blColor = V3(tunable("BLR_R", 0.62), tunable("BLR_G", 0.68), tunable("BLR_B", 0.82))
do {
    var out = [Float](repeating: 0, count: pixelCount * 4)
    let c = Float(N) / 2
    for y in 0..<N { for x in 0..<N {
        let dx = (Float(x) + 0.5 - c + blX * S) / S, dy = (Float(y) + 0.5 - c + blY * S) / S
        let a = blStrength * exp(-(dx * dx + dy * dy) / (2 * blR * blR))
        let col = blColor
        let i = (y * N + x) * 4
        out[i] = col.x * a; out[i + 1] = col.y * a; out[i + 2] = col.z * a; out[i + 3] = a
    } }
    writePNG(out, "backlight.png")
}
let vignetteStrength = tunable("VIGNETTE", 0.40)
// vignette.png: darkens the edges and corners a little, so the object sits in a pool of light
do {
    var out = [Float](repeating: 0, count: pixelCount * 4)
    let c = Float(N) / 2, strength = vignetteStrength
    for y in 0..<N { for x in 0..<N {
        let dx = (Float(x) + 0.5 - c) / c, dy = (Float(y) + 0.5 - c) / c
        let r = (dx * dx + dy * dy).squareRoot() / 1.41421
        let a = strength * smooth(0.35, 1.0, r)
        out[(y * N + x) * 4 + 3] = a
    } }
    writePNG(out, "vignette.png")
}
print("wrote layers to \(outDir)")
