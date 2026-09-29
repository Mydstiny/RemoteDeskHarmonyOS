// Generates the preset application icons as layered images plus picker previews.
// Usage (from the repository root): swift scripts/generate_app_icons.swift
//
// Every alternate icon uses the same layered-image format as the default icon, so
// the launcher masks all choices identically. The only input is the RD logo on a
// transparent 1024x1024 canvas (AppScope/resources/base/media/icon_rd_logo_color.png).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let appMedia = "AppScope/resources/base/media"
let entryMedia = "entry/src/main/resources/base/media"
let size = 1024
let previewSize = 256
// Matches the default background's corner radius (224 of 1024).
let cornerRatio: CGFloat = 224.0 / 1024.0

func load(_ path: String) -> CGImage {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read \(path)")
  }
  return image
}

func canvas(_ side: Int) -> CGContext {
  guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot create canvas")
  }
  context.interpolationQuality = .high
  return context
}

func save(_ context: CGContext, _ path: String) {
  guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
          UTType.png.identifier as CFString, 1, nil) else { fatalError("Cannot write \(path)") }
  CGImageDestinationAddImage(destination, image, nil)
  if !CGImageDestinationFinalize(destination) { fatalError("Cannot finalize \(path)") }
  print("wrote \(path)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Angle follows the CSS/ArkUI convention: 0 points up, 90 points right.
func linear(_ context: CGContext, _ stops: [(UInt32, CGFloat)], angle: CGFloat) {
  let side = CGFloat(context.width)
  let radians = (angle - 90) * .pi / 180
  let half = side / 2
  let reach = abs(cos(radians)) * half + abs(sin(radians)) * half
  // CoreGraphics' origin is bottom-left, so the y component is inverted.
  let dx = cos(radians) * reach, dy = -sin(radians) * reach
  let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: stops.map { color($0.0) } as CFArray, locations: stops.map { $0.1 })!
  context.drawLinearGradient(gradient, start: CGPoint(x: half - dx, y: half - dy),
    end: CGPoint(x: half + dx, y: half + dy), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// x/y are fractions measured from the top-left corner.
func glow(_ context: CGContext, x: CGFloat, y: CGFloat, radius: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
  let side = CGFloat(context.width)
  let center = CGPoint(x: x * side, y: (1 - y) * side)
  let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: [0, 1])!
  context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
    endRadius: radius * side, options: [])
}

func whiteLogo(_ logo: CGImage) -> CGImage {
  let context = canvas(size)
  let rect = CGRect(x: 0, y: 0, width: size, height: size)
  context.draw(logo, in: rect)
  context.setBlendMode(.sourceIn)
  context.setFillColor(color(0xFFFFFF))
  context.fill(rect)
  return context.makeImage()!
}

func foreground(_ logo: CGImage, shadow: Bool) -> CGContext {
  let context = canvas(size)
  if shadow {
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: color(0x001A4D, 0.28))
  }
  context.draw(logo, in: CGRect(x: 0, y: 0, width: size, height: size))
  return context
}

struct Preset {
  let name: String          // system alternate icon name (app.json5)
  let resource: String      // layered-image resource base name
  let foreground: String    // foreground layer resource
  let background: (CGContext) -> Void
  var drawForeground: ((CGContext) -> Void)? = nil  // original artwork written to `foreground`
}

// Top-left origin helpers for the original artwork (1024 canvas, key shapes inside the safe zone).
func topLeft(_ context: CGContext) {
  context.translateBy(x: 0, y: CGFloat(context.height)); context.scaleBy(x: 1, y: -1)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
  CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// A pointer arrow whose tip is at `tip`, `scale` 1 is about 400 px tall.
func cursor(tip: CGPoint, scale: CGFloat) -> CGPath {
  let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 400), (100, 305), (172, 452), (236, 422),
    (164, 280), (292, 280)]
  let path = CGMutablePath()
  path.addLines(between: points.map { CGPoint(x: tip.x + $0.0 * scale, y: tip.y + $0.1 * scale) })
  path.closeSubpath()
  return path
}

// Line art: a monoline remote screen with signal arcs.
func drawLine(_ context: CGContext) {
  topLeft(context)
  context.setStrokeColor(color(0xFFFFFF)); context.setLineWidth(40)
  context.setLineCap(.round); context.setLineJoin(.round)
  context.addPath(roundedRect(CGRect(x: 232, y: 262, width: 560, height: 400), 72)); context.strokePath()
  context.move(to: CGPoint(x: 512, y: 662)); context.addLine(to: CGPoint(x: 512, y: 752))
  context.move(to: CGPoint(x: 392, y: 772)); context.addLine(to: CGPoint(x: 632, y: 772)); context.strokePath()
  let center = CGPoint(x: 512, y: 560)
  context.setStrokeColor(color(0x7FF3E4))
  for radius in [92.0, 176.0] as [CGFloat] {
    context.addArc(center: center, radius: radius, startAngle: .pi * 1.25, endAngle: .pi * 1.75, clockwise: false)
    context.strokePath()
  }
  context.setFillColor(color(0x7FF3E4))
  context.fillEllipse(in: CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
}

// Flat geometric: two overlapping devices with a cursor.
func drawDuo(_ context: CGContext) {
  topLeft(context)
  let back = roundedRect(CGRect(x: 214, y: 226, width: 420, height: 420), 96)
  let front = roundedRect(CGRect(x: 390, y: 402, width: 420, height: 420), 96)
  context.addPath(back); context.setFillColor(color(0x4338CA)); context.fillPath()
  context.addPath(front); context.setFillColor(color(0xFF6F59)); context.fillPath()
  context.saveGState()
  context.addPath(back); context.clip()
  context.addPath(front); context.setFillColor(color(0x2A1B5E)); context.fillPath()
  context.restoreGState()
  context.addPath(cursor(tip: CGPoint(x: 560, y: 548), scale: 0.62))
  context.setFillColor(color(0xFFFFFF)); context.fillPath()
}

// Glassmorphism: a frosted card with a glowing pointer.
func drawGlass(_ context: CGContext) {
  topLeft(context)
  let card = roundedRect(CGRect(x: 252, y: 252, width: 520, height: 520), 132)
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: 24), blur: 60, color: color(0x1B0B5A, 0.35))
  context.addPath(card); context.setFillColor(color(0xFFFFFF, 0.18)); context.fillPath()
  context.restoreGState()
  context.saveGState()
  context.addPath(card); context.clip()
  let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [color(0xFFFFFF, 0.42), color(0xFFFFFF, 0.04)] as CFArray, locations: [0, 1])!
  context.drawLinearGradient(sheen, start: CGPoint(x: 300, y: 252), end: CGPoint(x: 700, y: 772), options: [])
  context.restoreGState()
  context.addPath(card); context.setStrokeColor(color(0xFFFFFF, 0.65)); context.setLineWidth(6); context.strokePath()
  context.saveGState()
  context.setShadow(offset: .zero, blur: 48, color: color(0xFFFFFF, 0.9))
  context.addPath(cursor(tip: CGPoint(x: 424, y: 356), scale: 0.78))
  context.setFillColor(color(0xFFFFFF)); context.fillPath()
  context.restoreGState()
}

let logo = load("\(appMedia)/icon_rd_logo_color.png")
let white = whiteLogo(logo)
save(foreground(white, shadow: true), "\(appMedia)/icon_rd_logo_white.png")

let presets: [Preset] = [
  Preset(name: "rd_white", resource: "icon_rd_white", foreground: "icon_rd_logo_color") { context in
    context.setFillColor(color(0xFFFFFF)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
  },
  // An empty background layer: the launcher shows only the logo.
  Preset(name: "rd_transparent", resource: "icon_rd_clear", foreground: "icon_rd_logo_color") { _ in },
  Preset(name: "rd_night", resource: "icon_rd_night", foreground: "icon_rd_logo_color") { context in
    linear(context, [(0x1C3264, 0), (0x0B1430, 0.6), (0x060A18, 1)], angle: 180)
    glow(context, x: 0.28, y: 0.2, radius: 0.62, 0x2F7BFF, 0.42)
    glow(context, x: 0.82, y: 0.9, radius: 0.5, 0x6A4DFF, 0.18)
  },
  Preset(name: "rd_sky", resource: "icon_rd_sky", foreground: "icon_rd_logo_white") { context in
    linear(context, [(0x7FD0FF, 0), (0x2E8BFF, 0.55), (0x0A56F0, 1)], angle: 145)
    glow(context, x: 0.22, y: 0.14, radius: 0.55, 0xFFFFFF, 0.32)
  },
  // The Pro badge's iridescent stops (ProBadge.ets) with the original blue logo.
  Preset(name: "rd_aurora", resource: "icon_rd_aurora", foreground: "icon_rd_logo_color") { context in
    linear(context, [(0xB9F3EA, 0), (0xCDC9FF, 0.35), (0xF4C8E5, 0.7), (0xF9E3B8, 1)], angle: 115)
    glow(context, x: 0.3, y: 0.18, radius: 0.6, 0xFFFFFF, 0.45)
  },
  Preset(name: "rd_line", resource: "icon_rd_line", foreground: "icon_rd_line_fg", background: { context in
    linear(context, [(0x0B3A4A, 0), (0x0C5C66, 0.6), (0x0E7C74, 1)], angle: 160)
    glow(context, x: 0.5, y: 0.55, radius: 0.5, 0x3FE0C8, 0.25)
  }, drawForeground: drawLine),
  Preset(name: "rd_duo", resource: "icon_rd_duo", foreground: "icon_rd_duo_fg", background: { context in
    context.setFillColor(color(0xF6EFE6)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
  }, drawForeground: drawDuo),
  Preset(name: "rd_glass", resource: "icon_rd_glass", foreground: "icon_rd_glass_fg", background: { context in
    linear(context, [(0x7B5CFF, 0), (0x3D7BFF, 0.55), (0x22D1E0, 1)], angle: 150)
    glow(context, x: 0.78, y: 0.22, radius: 0.5, 0xFF7AD9, 0.6)
    glow(context, x: 0.18, y: 0.85, radius: 0.45, 0x7CF5FF, 0.5)
  }, drawForeground: drawGlass)
]

func rounded(_ context: CGContext) {
  let side = CGFloat(context.width)
  let radius = side * cornerRatio
  context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
    cornerWidth: radius, cornerHeight: radius, transform: nil))
  context.clip()
}

for preset in presets {
  if let draw = preset.drawForeground {
    let artwork = canvas(size)
    draw(artwork)
    save(artwork, "\(appMedia)/\(preset.foreground).png")
  }
  let background = canvas(size)
  preset.background(background)
  save(background, "\(appMedia)/\(preset.resource)_bg.png")
  let layered = "{\n  \"layered-image\":\n  {\n    \"background\" : \"$media:\(preset.resource)_bg\",\n" +
    "    \"foreground\" : \"$media:\(preset.foreground)\"\n  }\n}\n"
  try! layered.write(toFile: "\(appMedia)/\(preset.resource).json", atomically: true, encoding: .utf8)
  print("wrote \(appMedia)/\(preset.resource).json")

  let preview = canvas(previewSize)
  let rect = CGRect(x: 0, y: 0, width: previewSize, height: previewSize)
  rounded(preview)
  preview.draw(background.makeImage()!, in: rect)
  preview.draw(load("\(appMedia)/\(preset.foreground).png"), in: rect)
  save(preview, "\(entryMedia)/icon_preview_\(preset.name).png")
}

// The default icon: the #007DFF background (background.svg) plus its full-bleed foreground.
let preview = canvas(previewSize)
let rect = CGRect(x: 0, y: 0, width: previewSize, height: previewSize)
rounded(preview)
preview.setFillColor(color(0x007DFF)); preview.fill(rect)
preview.draw(load("\(appMedia)/foreground.png"), in: rect)
save(preview, "\(entryMedia)/icon_preview_default.png")
