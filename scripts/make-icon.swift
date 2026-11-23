#!/usr/bin/env swift
//
// Generates F Wrds' app icon (10 PNGs in AppIcon.appiconset) and the menu bar template glyph
// (a single vector PDF in MenuBarIcon.imageset) with CoreGraphics — no Icon Composer, no external
// tools. Deterministic and re-runnable: `swift scripts/make-icon.swift` regenerates every asset
// from the constants below.
//
// The design: a rounded-rect filled with a vertical red-to-orange gradient, with an off-white
// monoline speech bubble holding "#!" centred on top. The glyph is the exact geometry of
// `App/Icon/bubble-glyph.svg` (24×24 viewBox, 1.5 stroke, round caps and joins), translated to
// CoreGraphics' y-up coordinate space and scaled to fit — see `rawGlyphPath()`.
//
// The rounded rect's canvas-to-shape ratio (full-bleed, corner radius ≈ 0.224 of the canvas)
// matches hosts-switchr's shipped AppIcon.appiconset (measured by alpha-scanning its PNGs' top
// row for the tangent point where the corner curve reaches full opacity — see
// `iconCornerRadiusRatio`'s doc comment for the measured values), so the two apps read at a
// consistent visual size in macOS 26's Dock, which wraps legacy PNG icons in its own squircle
// frame.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let assetsDir = repoRoot.appendingPathComponent("App/Sources/Assets.xcassets")
let appIconDir = assetsDir.appendingPathComponent("AppIcon.appiconset")
let menuBarDir = assetsDir.appendingPathComponent("MenuBarIcon.imageset")

// MARK: - Colour + contrast

/// The gradient's colours, red at the bottom of the tile and orange at the top, and the glyph's
/// colour on them. Both stops must clear `minimumWCAG` and `minimumAPCA` against the glyph: the
/// glyph is drawn in 1.5-unit strokes, which at Dock and Finder sizes are a pixel or two wide.
let gradientRedHex = "D63A26"
let gradientOrangeHex = "E35A1E"
let glyphHex = "FFF7F0"
let minimumWCAG = 3.0
let minimumAPCA = 60.0

struct RGB { let r: Double, g: Double, b: Double }

func rgb(fromHex hex: String) -> RGB {
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    return RGB(
        r: Double((value >> 16) & 0xFF) / 255,
        g: Double((value >> 8) & 0xFF) / 255,
        b: Double(value & 0xFF) / 255)
}

/// WCAG 2 relative luminance.
func relativeLuminance(_ color: RGB) -> Double {
    func linearize(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * linearize(color.r) + 0.7152 * linearize(color.g) + 0.0722 * linearize(color.b)
}

/// WCAG 2 contrast ratio between two colours.
func wcagContrast(_ a: RGB, _ b: RGB) -> Double {
    let (l1, l2) = (relativeLuminance(a), relativeLuminance(b))
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

/// APCA (0.1.9 constants) lightness contrast of `text` on `background`, as an absolute Lc value.
func apcaContrast(text: RGB, background: RGB) -> Double {
    func screenLuminance(_ c: RGB) -> Double {
        let y = 0.2126729 * pow(c.r, 2.4) + 0.7151522 * pow(c.g, 2.4) + 0.0721750 * pow(c.b, 2.4)
        return y < 0.022 ? y + pow(0.022 - y, 1.414) : y
    }
    let (txt, bg) = (screenLuminance(text), screenLuminance(background))
    guard abs(bg - txt) >= 0.0005 else { return 0 }
    let sapc = bg > txt
        ? (pow(bg, 0.56) - pow(txt, 0.57)) * 1.14
        : (pow(bg, 0.65) - pow(txt, 0.62)) * 1.14
    guard abs(sapc) >= 0.1 else { return 0 }
    return (abs(sapc) - 0.027) * 100
}

let gradientRed = rgb(fromHex: gradientRedHex)
let gradientOrange = rgb(fromHex: gradientOrangeHex)
let glyphColor = rgb(fromHex: glyphHex)

print("Glyph #\(glyphHex) contrast:")
for (label, hexValue, color) in [("top", gradientOrangeHex, gradientOrange), ("bottom", gradientRedHex, gradientRed)] {
    let wcag = wcagContrast(glyphColor, color)
    let apca = apcaContrast(text: glyphColor, background: color)
    print("  #\(hexValue) (\(label)): WCAG \(String(format: "%.2f", wcag)):1, APCA Lc \(String(format: "%.1f", apca))")
    guard wcag >= minimumWCAG, apca >= minimumAPCA else {
        fatalError("#\(hexValue) is below WCAG \(minimumWCAG):1 or APCA Lc \(minimumAPCA) against the glyph")
    }
}

// MARK: - Geometry

/// Corner radius as a fraction of the icon's full width. Measured by alpha-scanning hosts-switchr's
/// shipped AppIcon.appiconset PNGs along their top row (y=0), finding the x pixel where alpha first
/// reaches full opacity (255) — the tangent point where the corner curve meets the flat top edge.
/// (The first *nonzero*-alpha x, further left, is a point partway around the curve, not the
/// tangent — that's what an earlier version of this script measured, giving a too-small 0.2031.)
/// Measured tangent points: 128px→29, 256px→57, 512px→114, 1024px→229, i.e. a ratio of
/// 0.223—0.227 depending on size; 0.224 is used as the representative value.
let iconCornerRadiusRatio: Double = 0.224

/// The glyph's path bounding-box width as a fraction of the icon's full width. With the stroke
/// added, the ink spans about half the tile, level with the house's other app icons.
let glyphWidthRatio: Double = 0.46

/// The same, for the menu bar template: larger, since there is no tile around it.
let menuBarGlyphWidthRatio: Double = 0.72

/// The glyph's stroke width at the source SVG's 24×24 viewBox scale.
let glyphSourceStrokeWidth: Double = 1.5

/// `App/Icon/bubble-glyph.svg`, in its own viewBox units (0...24, y-down). The bubble is one closed
/// outline with its tail at the bottom left; the "#" is four strokes; the "!" is a stroke and a
/// zero-length segment, which the round cap draws as a dot.
func rawGlyphPath() -> CGPath {
    let path = CGMutablePath()
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    path.move(to: p(10.25, 16.75))
    path.addLine(to: p(16.75, 16.75))
    path.addCurve(to: p(20.75, 12.75), control1: p(18.96, 16.75), control2: p(20.75, 14.96))
    path.addLine(to: p(20.75, 8))
    path.addCurve(to: p(16.75, 4), control1: p(20.75, 5.79), control2: p(18.96, 4))
    path.addLine(to: p(7.25, 4))
    path.addCurve(to: p(3.25, 8), control1: p(5.04, 4), control2: p(3.25, 5.79))
    path.addLine(to: p(3.25, 12.75))
    path.addCurve(to: p(6.44, 16.67), control1: p(3.25, 14.68), control2: p(4.62, 16.29))
    path.addLine(to: p(6.44, 20.25))
    path.closeSubpath()

    let strokes: [(CGPoint, CGPoint)] = [
        (p(9, 7.25), p(9, 13.5)),
        (p(12, 7.25), p(12, 13.5)),
        (p(7.25, 9.1), p(13.75, 9.1)),
        (p(7.25, 11.65), p(13.75, 11.65)),
        (p(16.5, 7.25), p(16.5, 10.6)),
        (p(16.5, 13.5), p(16.5, 13.5)),
    ]
    for (from, to) in strokes {
        path.move(to: from)
        path.addLine(to: to)
    }
    return path
}

/// The glyph's `CGPath`, scaled and translated so its bounding box is centred at `center` with the
/// given `width`, in a y-up coordinate space (SVG's y-down is flipped in the process). Returns the
/// path alongside the stroke width to use, scaled by the same factor as the geometry so it stays
/// proportional to the source's 1.5-at-24-viewBox-units ratio.
func transformedGlyphPath(center: CGPoint, width: CGFloat) -> (path: CGPath, strokeWidth: CGFloat) {
    let raw = rawGlyphPath()
    let bounds = raw.boundingBoxOfPath
    let scale = width / bounds.width
    var transform = CGAffineTransform(translationX: center.x, y: center.y)
        .scaledBy(x: scale, y: -scale)
        .translatedBy(x: -bounds.midX, y: -bounds.midY)
    let path = raw.copy(using: &transform)!
    return (path, CGFloat(glyphSourceStrokeWidth) * scale)
}

// MARK: - App icon rendering

func renderAppIcon(pixelSize: Int) -> CGImage {
    let size = CGFloat(pixelSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // The rounded rect, full-bleed to the canvas edge — see `iconCornerRadiusRatio`'s doc comment.
    let radius = size * CGFloat(iconCornerRadiusRatio)
    let shapePath = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: size, height: size), cornerWidth: radius, cornerHeight: radius,
        transform: nil)

    ctx.saveGState()
    ctx.addPath(shapePath)
    ctx.clip()
    let colors = [
        CGColor(red: CGFloat(gradientRed.r), green: CGFloat(gradientRed.g), blue: CGFloat(gradientRed.b), alpha: 1),
        CGColor(
            red: CGFloat(gradientOrange.r), green: CGFloat(gradientOrange.g), blue: CGFloat(gradientOrange.b),
            alpha: 1),
    ]
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1])!
    // CoreGraphics is y-up: the first colour (red) lands at the bottom, the orange at the top.
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: size / 2, y: 0), end: CGPoint(x: size / 2, y: size), options: [])
    ctx.restoreGState()

    let (glyphPath, strokeWidth) = transformedGlyphPath(
        center: CGPoint(x: size / 2, y: size / 2), width: size * CGFloat(glyphWidthRatio))
    ctx.addPath(glyphPath)
    ctx.setStrokeColor(CGColor(red: CGFloat(glyphColor.r), green: CGFloat(glyphColor.g), blue: CGFloat(glyphColor.b), alpha: 1))
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG for \(url.lastPathComponent)")
    }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try data.write(to: url)
    } catch {
        fatalError("Failed to write \(url.path): \(error)")
    }
}

struct IconSpec { let pointSize: Int, scale: Int, filename: String }

let iconSpecs: [IconSpec] = [
    IconSpec(pointSize: 16, scale: 1, filename: "icon_16x16.png"),
    IconSpec(pointSize: 16, scale: 2, filename: "icon_16x16@2x.png"),
    IconSpec(pointSize: 32, scale: 1, filename: "icon_32x32.png"),
    IconSpec(pointSize: 32, scale: 2, filename: "icon_32x32@2x.png"),
    IconSpec(pointSize: 128, scale: 1, filename: "icon_128x128.png"),
    IconSpec(pointSize: 128, scale: 2, filename: "icon_128x128@2x.png"),
    IconSpec(pointSize: 256, scale: 1, filename: "icon_256x256.png"),
    IconSpec(pointSize: 256, scale: 2, filename: "icon_256x256@2x.png"),
    IconSpec(pointSize: 512, scale: 1, filename: "icon_512x512.png"),
    IconSpec(pointSize: 512, scale: 2, filename: "icon_512x512@2x.png"),
]

print("\nRendering AppIcon.appiconset:")
for spec in iconSpecs {
    let pixelSize = spec.pointSize * spec.scale
    let image = renderAppIcon(pixelSize: pixelSize)
    let url = appIconDir.appendingPathComponent(spec.filename)
    writePNG(image, to: url)
    print("  \(spec.filename) (\(pixelSize)×\(pixelSize))")
}

let appIconContentsImages = iconSpecs.map {
    "    {\"size\":\"\($0.pointSize)x\($0.pointSize)\",\"idiom\":\"mac\",\"filename\":\"\($0.filename)\",\"scale\":\"\($0.scale)x\"}"
}.joined(separator: ",\n")
let appIconContents = """
{
  "images" : [
\(appIconContentsImages)
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}

"""
try! appIconContents.write(
    to: appIconDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("  Contents.json")

// MARK: - Menu bar glyph (vector PDF, template rendering)

/// Overwrites every byte range immediately following an occurrence of `marker` with `replacement`
/// (which must be exactly `length` bytes, so the file's total length — and every xref byte offset
/// after the edit — stays unchanged). Used to neutralise the non-deterministic fields CoreGraphics'
/// PDF writer stamps into every document (see `neutralizeNonDeterministicFields` below). The file is
/// a few KB, so a naive scan is more than fast enough.
func replaceFollowing(_ marker: String, length: Int, with replacement: String, in bytes: inout [UInt8]) {
    let markerBytes = Array(marker.utf8)
    let replacementBytes = Array(replacement.utf8)
    precondition(replacementBytes.count == length, "replacement for \(marker) must be \(length) bytes")
    guard !markerBytes.isEmpty, bytes.count >= markerBytes.count else { return }
    var searchStart = 0
    while searchStart <= bytes.count - markerBytes.count {
        guard let matchStart = bytes[searchStart...].firstRange(of: markerBytes)?.lowerBound else { break }
        let replaceStart = matchStart + markerBytes.count
        guard replaceStart + length <= bytes.count else { break }
        bytes.replaceSubrange(replaceStart..<(replaceStart + length), with: replacementBytes)
        searchStart = replaceStart + length
    }
}

/// CoreGraphics' PDF writer stamps `/CreationDate`, `/ModDate` and `/ID` with the current wall-clock
/// time (and a time-derived document ID), so two otherwise-identical runs of this script produce
/// byte-different PDFs. Since every other byte of the document — content streams, ICC profile,
/// object/xref layout — is a pure function of the fixed geometry drawn above, pinning these three
/// fields to fixed values makes the whole file byte-identical across runs. Each replacement is the
/// same length as the text it overwrites (14-digit `D:YYYYMMDDHHMMSS` timestamps, 32-hex-char `/ID`
/// strings), so no byte offset elsewhere in the file shifts and the xref table stays valid.
func neutralizeNonDeterministicFields(_ data: Data) -> Data {
    var bytes = [UInt8](data)
    let fixedTimestamp = "20260101000000"  // 14 digits: YYYYMMDDHHMMSS
    let fixedID = String(repeating: "0", count: 32)  // 32 hex chars, matching the real ID's length
    replaceFollowing("/CreationDate (D:", length: 14, with: fixedTimestamp, in: &bytes)
    replaceFollowing("/ModDate (D:", length: 14, with: fixedTimestamp, in: &bytes)
    replaceFollowing("/ID [ <", length: 32, with: fixedID, in: &bytes)
    replaceFollowing(">\n<", length: 32, with: fixedID, in: &bytes)
    return Data(bytes)
}

/// Renders the glyph alone — no background shape — as a single-page vector PDF at the source SVG's
/// own 24×24 viewBox scale, so it carries the same proportions the designer drew it at. Drawn in
/// black: template images are used purely as an alpha stencil, so the colour itself is never seen.
///
/// Rendered into an in-memory buffer (rather than straight to `url` via `CGDataConsumer(url:)`) so
/// the raw PDF bytes can be passed through `neutralizeNonDeterministicFields` before hitting disk —
/// see that function's doc comment for why.
func renderMenuBarGlyphPDF(to url: URL) {
    var mediaBox = CGRect(x: 0, y: 0, width: 24, height: 24)
    let buffer = NSMutableData()
    guard let consumer = CGDataConsumer(data: buffer as CFMutableData),
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
        fatalError("Failed to create PDF context for \(url.path)")
    }
    ctx.beginPDFPage(nil)
    ctx.setShouldAntialias(true)

    let (glyphPath, strokeWidth) = transformedGlyphPath(
        center: CGPoint(x: 12, y: 12), width: 24 * CGFloat(menuBarGlyphWidthRatio))
    ctx.addPath(glyphPath)
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    ctx.endPDFPage()
    ctx.closePDF()

    let pdfData = neutralizeNonDeterministicFields(buffer as Data)
    do {
        try pdfData.write(to: url)
    } catch {
        fatalError("Failed to write \(url.path): \(error)")
    }
}

print("\nRendering MenuBarIcon.imageset:")
try? FileManager.default.createDirectory(at: menuBarDir, withIntermediateDirectories: true)
renderMenuBarGlyphPDF(to: menuBarDir.appendingPathComponent("MenuBarIcon.pdf"))
print("  MenuBarIcon.pdf")

let menuBarContents = """
{
  "images" : [
    {
      "filename" : "MenuBarIcon.pdf",
      "idiom" : "universal"
    }
  ],
  "info" : { "version" : 1, "author" : "xcode" },
  "properties" : {
    "template-rendering-intent" : "template",
    "preserves-vector-representation" : true
  }
}

"""
try! menuBarContents.write(
    to: menuBarDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("  Contents.json")

print("\nDone.")
