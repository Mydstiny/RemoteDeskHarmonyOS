// Generates the preset application icons as layered images plus picker previews.
// Usage (from the repository root): swift scripts/generate_app_icons.swift
//
// Every alternate icon uses the same layered-image format as the default icon, so
// the launcher masks all choices identically. Inputs are the RD logo on a transparent
// 1024x1024 canvas (AppScope/resources/base/media/icon_rd_logo_color.png) and supplied
// logo artwork on white (design/app-icons/*.png).
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

// Supplied artwork (design/app-icons, not packaged): a logo on a white canvas.
func flattened(_ path: String) -> CGContext {
  let source = load(path)
  let raw = canvas(source.width)  // sources are square
  // Transparent source pixels read as the white canvas they were designed on.
  raw.setFillColor(color(0xFFFFFF)); raw.fill(CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
  raw.draw(source, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
  return raw
}

// The supplied image exactly as designed, only resized to the icon canvas.
func originalArtwork(_ path: String) -> (CGContext) -> Void {
  return { context in
    context.draw(flattened(path).makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))
  }
}

// The supplied logo in its original position and scale, with the white canvas keyed to
// transparency (anti-aliased edges un-mixed from white), optionally filled white.
func keyedArtwork(_ path: String, white: Bool = false) -> (CGContext) -> Void {
  return { context in
    let raw = flattened(path)
    let pixels = raw.data!.bindMemory(to: UInt8.self, capacity: raw.bytesPerRow * raw.height)
    for y in 0..<raw.height {
      for x in 0..<raw.width {
        let i = y * raw.bytesPerRow + x * 4
        let r = CGFloat(pixels[i]), g = CGFloat(pixels[i + 1]), b = CGFloat(pixels[i + 2])
        // Distance from white; 245+ is background, 185- is fully logo.
        let alpha = max(0, min(1, (245 - min(r, g, b)) / 60))
        func channel(_ value: CGFloat) -> UInt8 {
          white ? UInt8(255 * alpha) : UInt8(max(0, min(255, (value - (1 - alpha) * 255) / max(alpha, 0.001))) * alpha)
        }
        pixels[i] = channel(r); pixels[i + 1] = channel(g); pixels[i + 2] = channel(b)
        pixels[i + 3] = UInt8(alpha * 255)
      }
    }
    if white { context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: color(0x001A4D, 0.28)) }
    context.draw(raw.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))
  }
}

func whiteBackground(_ context: CGContext) {
  context.setFillColor(color(0xFFFFFF)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
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
  Preset(name: "rd_vivid", resource: "icon_rd_vivid", foreground: "icon_rd_vivid_fg",
    background: whiteBackground, drawForeground: originalArtwork("design/app-icons/rd_vivid.png")),
  Preset(name: "rd_soft", resource: "icon_rd_soft", foreground: "icon_rd_soft_fg",
    background: whiteBackground, drawForeground: originalArtwork("design/app-icons/rd_soft.png")),
  Preset(name: "rd_glow", resource: "icon_rd_glow", foreground: "icon_rd_glow_fg",
    background: whiteBackground, drawForeground: originalArtwork("design/app-icons/rd_glow.png")),
  Preset(name: "rd_glow_mist", resource: "icon_rd_glow_mist", foreground: "icon_rd_glow_mist_fg",
    background: whiteBackground, drawForeground: originalArtwork("design/app-icons/rd_glow_mist.png")),
  Preset(name: "rd_glow_night", resource: "icon_rd_glow_night", foreground: "icon_rd_glow_night_fg",
    background: whiteBackground, drawForeground: originalArtwork("design/app-icons/rd_glow_night.png")),
  Preset(name: "rd_glow_frost", resource: "icon_rd_glow_frost", foreground: "icon_rd_glow_frost_fg",
    background: whiteBackground, drawForeground: originalArtwork("design/app-icons/rd_glow_frost.png")),
  Preset(name: "rd_vivid_night", resource: "icon_rd_vivid_night", foreground: "icon_rd_vivid_keyed", background: { context in
    linear(context, [(0x17264F, 0), (0x0A1128, 0.6), (0x05081A, 1)], angle: 180)
    glow(context, x: 0.8, y: 0.2, radius: 0.55, 0x1FC8FF, 0.32)
    glow(context, x: 0.15, y: 0.85, radius: 0.5, 0x2F5BFF, 0.3)
  }, drawForeground: keyedArtwork("design/app-icons/rd_vivid.png")),
  Preset(name: "rd_vivid_ocean", resource: "icon_rd_vivid_ocean", foreground: "icon_rd_vivid_keyed_white", background: { context in
    linear(context, [(0x22D3F5, 0), (0x1C8BFF, 0.5), (0x0B4FE6, 1)], angle: 145)
    glow(context, x: 0.8, y: 0.15, radius: 0.5, 0xFFFFFF, 0.25)
  }, drawForeground: keyedArtwork("design/app-icons/rd_vivid.png", white: true)),
  Preset(name: "rd_vivid_aurora", resource: "icon_rd_vivid_aurora", foreground: "icon_rd_vivid_keyed", background: { context in
    linear(context, [(0xB9F3EA, 0), (0xCDC9FF, 0.35), (0xF4C8E5, 0.7), (0xF9E3B8, 1)], angle: 115)
    glow(context, x: 0.3, y: 0.18, radius: 0.6, 0xFFFFFF, 0.45)
  }, drawForeground: keyedArtwork("design/app-icons/rd_vivid.png"))
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
