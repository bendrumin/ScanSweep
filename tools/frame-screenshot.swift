#!/usr/bin/env swift
//
// Wraps a raw simulator screenshot in the SnapSweep App Store frame:
// a purple vertical gradient, a headline and subhead, and the screenshot
// itself as a rounded card that bleeds off the bottom of the canvas.
//
// The constants below were measured off the original hand-made 6.9" set so
// regenerated screenshots stay pixel-consistent with the ones already live.
//
//   swift tools/frame-screenshot.swift <raw.png> <headline> <subhead> <out.png>
//
// The raw input must be a 1320x2868 capture (iPhone 6.9" — 17 Pro Max).

import Foundation
import AppKit

let canvasW = 1320, canvasH = 2868

// Card: 90pt margins, top edge at y=432, corners at r=60, clipped by the canvas.
let cardX: CGFloat = 90
let cardTop: CGFloat = 432
let cardW: CGFloat = 1140
let cardRadius: CGFloat = 60

// Background gradient, sampled from the original set.
let bgTop = NSColor(srgbRed: 109/255, green: 112/255, blue: 222/255, alpha: 1)
let bgBottom = NSColor(srgbRed: 156/255, green: 105/255, blue: 233/255, alpha: 1)

// Type: sizes fitted so the ink lands on the original's baselines.
let headlineSize: CGFloat = 92
let headlineBaseline: CGFloat = 225
let subheadSize: CGFloat = 45
let subheadBaseline: CGFloat = 347

guard CommandLine.arguments.count == 5 else {
    FileHandle.standardError.write(
        "usage: frame-screenshot.swift <raw.png> <headline> <subhead> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let (rawPath, headline, subhead, outPath) =
    (CommandLine.arguments[1], CommandLine.arguments[2], CommandLine.arguments[3], CommandLine.arguments[4])

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: rawPath) as CFURL, nil),
      let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("cannot read \(rawPath)\n".data(using: .utf8)!)
    exit(1)
}

let ctx = CGContext(data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

/// Canvas coordinates are top-down; Core Graphics is bottom-up.
func cgY(_ top: CGFloat) -> CGFloat { CGFloat(canvasH) - top }

// Background gradient.
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [bgBottom.cgColor, bgTop.cgColor] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: 0),
                       end: CGPoint(x: 0, y: CGFloat(canvasH)),
                       options: [])

// The card keeps the raw screenshot's aspect ratio and runs off the bottom edge.
let scale = cardW / CGFloat(raw.width)
let cardH = CGFloat(raw.height) * scale
let cardRect = CGRect(x: cardX, y: cgY(cardTop) - cardH, width: cardW, height: cardH)
let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius,
                      transform: nil)

// Soft drop shadow, then the clipped screenshot.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 44,
              color: NSColor(white: 0, alpha: 0.28).cgColor)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(cardPath)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(cardPath)
ctx.clip()
ctx.draw(raw, in: cardRect)
ctx.restoreGState()

// Headline and subhead, centred on the canvas and drawn on their measured baselines.
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx

func drawCentered(_ text: String, font: NSFont, color: NSColor, baseline: CGFloat) {
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let line = CTLineCreateWithAttributedString(attributed)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: (CGFloat(canvasW) - CGFloat(width)) / 2, y: cgY(baseline))
    CTLineDraw(line, ctx)
}

drawCentered(headline, font: .systemFont(ofSize: headlineSize, weight: .bold),
             color: .white, baseline: headlineBaseline)
drawCentered(subhead, font: .systemFont(ofSize: subheadSize, weight: .semibold),
             color: NSColor(white: 1, alpha: 0.88), baseline: subheadBaseline)

NSGraphicsContext.restoreGraphicsState()

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write("cannot write \(outPath)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(outPath)")
