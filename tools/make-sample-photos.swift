#!/usr/bin/env swift
//
// Generates the stand-in "bad photo" samples used in the App Store screenshots.
// They are synthetic on purpose — no real person's photos end up in the listing —
// but blurred and under/over-exposed enough that SnapSweep flags them and they
// read as genuine accidental shots at thumbnail size.
//
//   swift tools/make-sample-photos.swift <output-dir>
//   xcrun simctl addmedia <device> <output-dir>/*.jpg
//
import Foundation
import AppKit
import CoreImage

let out = CommandLine.arguments[1]
let ciCtx = CIContext()

// Each sample is a simple scene (a few soft colour fields plus a bright
// highlight) pushed through a heavy blur, so it reads as a real out-of-focus
// phone photo at thumbnail size without being a photo of anyone.
struct Scene { let name: String; let bands: [(CGFloat, CGFloat, CGFloat)]; let blur: Double; let exposure: Double }
let scenes: [Scene] = [
    Scene(name: "blur_kitchen", bands: [(0.85,0.78,0.66),(0.72,0.60,0.45),(0.45,0.36,0.28)], blur: 26, exposure: 0.0),
    Scene(name: "blur_carpet",  bands: [(0.40,0.34,0.31),(0.55,0.45,0.38),(0.30,0.26,0.24)], blur: 34, exposure: -0.3),
    Scene(name: "dark_room",    bands: [(0.10,0.10,0.13),(0.05,0.05,0.08),(0.02,0.02,0.04)], blur: 18, exposure: -1.4),
    Scene(name: "blur_yard",    bands: [(0.52,0.68,0.42),(0.38,0.55,0.30),(0.66,0.74,0.85)], blur: 30, exposure: 0.1),
    Scene(name: "blur_ceiling", bands: [(0.88,0.88,0.90),(0.76,0.77,0.80),(0.62,0.63,0.68)], blur: 38, exposure: 0.2),
    Scene(name: "blur_couch",   bands: [(0.58,0.42,0.40),(0.44,0.30,0.30),(0.70,0.58,0.52)], blur: 28, exposure: -0.2),
]

let W = 1600, H = 1200
for s in scenes {
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    // Diagonal colour fields.
    for (i, c) in s.bands.enumerated() {
        NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1).setFill()
        let p = NSBezierPath()
        let y0 = CGFloat(i) * CGFloat(H) / CGFloat(s.bands.count)
        let y1 = CGFloat(i+1) * CGFloat(H) / CGFloat(s.bands.count)
        p.move(to: NSPoint(x: -200, y: y0 - 120))
        p.line(to: NSPoint(x: CGFloat(W)+200, y: y0 + 160))
        p.line(to: NSPoint(x: CGFloat(W)+200, y: y1 + 160))
        p.line(to: NSPoint(x: -200, y: y1 - 120))
        p.close(); p.fill()
    }
    // A couple of soft highlights so the blur has something to smear.
    for (dx, dy, r, a) in [(0.30, 0.62, 0.20, 0.35), (0.68, 0.34, 0.14, 0.25)] as [(Double,Double,Double,Double)] {
        NSColor(white: 1, alpha: a).setFill()
        let rad = CGFloat(r) * CGFloat(W)
        NSBezierPath(ovalIn: NSRect(x: CGFloat(dx)*CGFloat(W)-rad/2, y: CGFloat(dy)*CGFloat(H)-rad/2,
                                    width: rad, height: rad)).fill()
    }
    img.unlockFocus()

    var rect = NSRect(x: 0, y: 0, width: W, height: H)
    guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
    var ci = CIImage(cgImage: cg)
    ci = ci.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: s.blur])
        .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure])
    let url = URL(fileURLWithPath: "\(out)/\(s.name).jpg")
    try! ciCtx.writeJPEGRepresentation(of: ci, to: url,
                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    print("wrote \(url.lastPathComponent)")
}
