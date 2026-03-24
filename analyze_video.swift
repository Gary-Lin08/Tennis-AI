#!/usr/bin/env swift
// analyze_video.swift — 独立 macOS 脚本，复现 App 内 TrackNet 推理 + 视频叠加渲染
// 运行方式: swift analyze_video.swift

import AVFoundation
import CoreML
import CoreGraphics
import Foundation
import CoreText
import CoreImage

// MARK: - 数据类型

struct InferencePoint {
    let frameIndex: Int
    let x: Int
    let y: Int
    let confidence: Double
    let isVisible: Bool
}

struct DetectedAction {
    let frameIndex: Int
    let x: Int
    let y: Int
    let confidence: Double
    let type: ActionType
}

enum ActionType {
    case forehand, backhand, serve, unknown
    var label: String {
        switch self {
        case .forehand:  return "击球"   // 方案C：不再区分正/反手，统一标"击球"
        case .backhand:  return "反手"   // 保留枚举但当前不使用
        case .serve:     return "发球"
        case .unknown:   return "未知"
        }
    }
}

enum TensorOrder { case chw, hwc }

struct TensorLayout {
    let hasBatch: Bool
    let order: TensorOrder
    let channels: Int
    let height: Int
    let width: Int
}

enum InputAdapter {
    case image(name: String, width: Int, height: Int)
    case multiArray(name: String, shape: [Int], layout: TensorLayout, dataType: MLMultiArrayDataType)
}

// MARK: - 工具函数

func clampD(_ v: Double, lo: Double, hi: Double) -> Double { max(lo, min(hi, v)) }

func normalizedSignal(_ raw: Double) -> Double {
    guard raw.isFinite else { return 0.5 }
    if raw >= 0, raw <= 1 { return raw }
    return 1.0 / (1.0 + exp(-clampD(raw, lo: -20, hi: 20)))
}

func heatmapOffset(layout: TensorLayout, strides: [Int], channel: Int, y: Int, x: Int) -> Int {
    switch (layout.order, layout.hasBatch) {
    case (.chw, true):  return channel * strides[1] + y * strides[2] + x * strides[3]
    case (.chw, false): return channel * strides[0] + y * strides[1] + x * strides[2]
    case (.hwc, true):  return y * strides[1] + x * strides[2] + channel * strides[3]
    case (.hwc, false): return y * strides[0] + x * strides[1] + channel * strides[2]
    }
}

func makeValueReader(for array: MLMultiArray) -> (Int) -> Double {
    switch array.dataType {
    case .double:
        let p = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
        return { Double(p[$0]) }
    case .float32:
        let p = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        return { Double(p[$0]) }
    case .float16:
        let p = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
        return { Double(p[$0]) }
    case .int32:
        let p = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
        return { Double(p[$0]) / 32767.0 }
    case .int8:
        let p = array.dataPointer.bindMemory(to: Int8.self, capacity: array.count)
        return { Double(p[$0]) / 127.0 }
    @unknown default:
        let p = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        return { Double(p[$0]) }
    }
}

// MARK: - 布局推断

func inferLayout(from shape: [Int]) -> TensorLayout? {
    if shape.count == 4, shape[0] == 1 {
        if shape[1] > 0, shape[2] > 0, shape[3] > 0, shape[1] <= 128 {
            return TensorLayout(hasBatch: true, order: .chw, channels: shape[1], height: shape[2], width: shape[3])
        }
        if shape[1] > 0, shape[2] > 0, shape[3] > 0, shape[3] <= 128 {
            return TensorLayout(hasBatch: true, order: .hwc, channels: shape[3], height: shape[1], width: shape[2])
        }
    }
    if shape.count == 3 {
        if shape[0] > 0, shape[1] > 0, shape[2] > 0, shape[0] <= 128 {
            return TensorLayout(hasBatch: false, order: .chw, channels: shape[0], height: shape[1], width: shape[2])
        }
        if shape[0] > 0, shape[1] > 0, shape[2] > 0, shape[2] <= 128 {
            return TensorLayout(hasBatch: false, order: .hwc, channels: shape[2], height: shape[0], width: shape[1])
        }
    }
    return nil
}

func makeInputAdapter(for model: MLModel) throws -> InputAdapter {
    let inputs = model.modelDescription.inputDescriptionsByName
    let names = inputs.keys.sorted()
    for name in names {
        guard let desc = inputs[name] else { continue }
        if desc.type == .image {
            let c = desc.imageConstraint
            return .image(name: name, width: max(c?.pixelsWide ?? 224, 1), height: max(c?.pixelsHigh ?? 224, 1))
        }
    }
    for name in names {
        guard let desc = inputs[name] else { continue }
        if desc.type == .multiArray, let c = desc.multiArrayConstraint {
            let shape = c.shape.map { Int(truncating: $0) }
            guard let layout = inferLayout(from: shape) else {
                throw NSError(domain: "Analyze", code: 1, userInfo: [NSLocalizedDescriptionKey: "不支持的张量形状: \(shape)"])
            }
            return .multiArray(name: name, shape: shape, layout: layout, dataType: c.dataType)
        }
    }
    throw NSError(domain: "Analyze", code: 2, userInfo: [NSLocalizedDescriptionKey: "模型输入类型不支持"])
}

// MARK: - 像素缓冲区

func makePixelBuffer(from image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
          let pb else {
        throw NSError(domain: "Analyze", code: 3, userInfo: [NSLocalizedDescriptionKey: "CVPixelBuffer 创建失败"])
    }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else {
        throw NSError(domain: "Analyze", code: 3, userInfo: [NSLocalizedDescriptionKey: "CVPixelBuffer 基址为空"])
    }
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let cs = CGColorSpaceCreateDeviceRGB()
    let bmi = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: cs, bitmapInfo: bmi) else {
        throw NSError(domain: "Analyze", code: 3, userInfo: [NSLocalizedDescriptionKey: "CGContext 创建失败"])
    }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pb
}

func grayscalePixels(from image: CGImage, width: Int, height: Int) throws -> [Float] {
    let pb = try makePixelBuffer(from: image, width: width, height: height)
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else {
        throw NSError(domain: "Analyze", code: 3, userInfo: [NSLocalizedDescriptionKey: "灰度提取失败"])
    }
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let ptr = base.assumingMemoryBound(to: UInt8.self)
    var out = [Float](repeating: 0, count: width * height)
    for y in 0..<height {
        let row = ptr.advanced(by: y * bpr)
        for x in 0..<width {
            let px = row.advanced(by: x * 4)
            out[y * width + x] = (0.114 * Float(px[0]) + 0.587 * Float(px[1]) + 0.299 * Float(px[2])) / 255.0
        }
    }
    return out
}

func rgbPixels(from image: CGImage, width: Int, height: Int) throws -> [Float] {
    let pb = try makePixelBuffer(from: image, width: width, height: height)
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else {
        throw NSError(domain: "Analyze", code: 3, userInfo: [NSLocalizedDescriptionKey: "RGB 提取失败"])
    }
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let ptr = base.assumingMemoryBound(to: UInt8.self)
    var out = [Float](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        let row = ptr.advanced(by: y * bpr)
        for x in 0..<width {
            let px = row.advanced(by: x * 4)
            let idx = (y * width + x) * 3
            out[idx + 0] = Float(px[2]) / 255.0  // R
            out[idx + 1] = Float(px[1]) / 255.0  // G
            out[idx + 2] = Float(px[0]) / 255.0  // B
        }
    }
    return out
}

func fillFloatingGeneric<T: BinaryFloatingPoint>(
    data: UnsafeMutablePointer<T>, layout: TensorLayout, strides: [Int],
    valueProvider: (Int, Int, Int) -> Float
) {
    for c in 0..<layout.channels {
        for y in 0..<layout.height {
            for x in 0..<layout.width {
                let off = heatmapOffset(layout: layout, strides: strides, channel: c, y: y, x: x)
                data[off] = T(valueProvider(c, y, x))
            }
        }
    }
}

func fillIntegerGeneric<T: FixedWidthInteger>(
    data: UnsafeMutablePointer<T>, layout: TensorLayout, strides: [Int],
    valueProvider: (Int, Int, Int) -> Float, scaling: Float
) {
    let lo = Float(T.min), hi = Float(T.max)
    for c in 0..<layout.channels {
        for y in 0..<layout.height {
            for x in 0..<layout.width {
                let off = heatmapOffset(layout: layout, strides: strides, channel: c, y: y, x: x)
                data[off] = T(max(lo, min(hi, valueProvider(c, y, x) * scaling)).rounded())
            }
        }
    }
}

func fillArray(array: MLMultiArray, layout: TensorLayout, valueProvider: (Int, Int, Int) -> Float) {
    let strides = array.strides.map { Int(truncating: $0) }
    switch array.dataType {
    case .double:
        fillFloatingGeneric(data: array.dataPointer.bindMemory(to: Double.self, capacity: array.count),
                            layout: layout, strides: strides, valueProvider: valueProvider)
    case .float32:
        fillFloatingGeneric(data: array.dataPointer.bindMemory(to: Float32.self, capacity: array.count),
                            layout: layout, strides: strides, valueProvider: valueProvider)
    case .float16:
        fillFloatingGeneric(data: array.dataPointer.bindMemory(to: Float16.self, capacity: array.count),
                            layout: layout, strides: strides, valueProvider: valueProvider)
    case .int32:
        fillIntegerGeneric(data: array.dataPointer.bindMemory(to: Int32.self, capacity: array.count),
                           layout: layout, strides: strides, valueProvider: valueProvider, scaling: 255.0)
    case .int8:
        fillIntegerGeneric(data: array.dataPointer.bindMemory(to: Int8.self, capacity: array.count),
                           layout: layout, strides: strides, valueProvider: valueProvider, scaling: 127.0)
    @unknown default:
        fillFloatingGeneric(data: array.dataPointer.bindMemory(to: Float32.self, capacity: array.count),
                            layout: layout, strides: strides, valueProvider: valueProvider)
    }
}

// MARK: - 输入 Provider 构建

func makeProvider(forFrames frames: [CGImage], using adapter: InputAdapter) throws -> MLDictionaryFeatureProvider {
    switch adapter {
    case .image(let name, let width, let height):
        guard let frame = frames.last else { throw NSError(domain: "Analyze", code: 4, userInfo: nil) }
        let pb = try makePixelBuffer(from: frame, width: width, height: height)
        return try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(pixelBuffer: pb)])

    case .multiArray(let name, let shape, let layout, let dataType):
        guard let frame = frames.last else { throw NSError(domain: "Analyze", code: 4, userInfo: nil) }
        let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: dataType)
        if layout.channels >= 9, layout.channels % 3 == 0, frames.count >= 3 {
            let fc = max(1, layout.channels / 3)
            var selectedFrames: [CGImage]
            if frames.count >= fc { selectedFrames = Array(frames.suffix(fc)) }
            else if let last = frames.last { selectedFrames = frames + Array(repeating: last, count: fc - frames.count) }
            else { throw NSError(domain: "Analyze", code: 4, userInfo: nil) }
            var rgbFrames = [[Float]]()
            for f in selectedFrames { rgbFrames.append(try rgbPixels(from: f, width: layout.width, height: layout.height)) }
            fillArray(array: array, layout: layout) { channel, y, x in
                let fi = min(channel / 3, rgbFrames.count - 1)
                let ci = channel % 3
                return rgbFrames[fi][(y * layout.width + x) * 3 + ci]
            }
        } else {
            let gray = try grayscalePixels(from: frame, width: layout.width, height: layout.height)
            fillArray(array: array, layout: layout) { _, y, x in gray[y * layout.width + x] }
        }
        return try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(multiArray: array)])
    }
}

// MARK: - 输出解码

func firstMultiArray(from provider: MLFeatureProvider) -> MLMultiArray? {
    for name in provider.featureNames.sorted() {
        if let v = provider.featureValue(for: name), v.type == .multiArray { return v.multiArrayValue }
    }
    return nil
}

// 原版 GridTrackNet 训练时的决策边界是 0.50（sigmoid 输出）
let detectionThreshold = 0.50

func decodeTrackNetOutput(_ provider: MLFeatureProvider, sourceWidth: Int, sourceHeight: Int,
                          baseFrameIndex: Int) -> [InferencePoint] {
    guard let array = firstMultiArray(from: provider),
          let layout = inferLayout(from: array.shape.map { Int(truncating: $0) }) else { return [] }
    let strides = array.strides.map { Int(truncating: $0) }
    let valueAt = makeValueReader(for: array)
    let isGrid = layout.channels >= 6 && layout.channels % 3 == 0
    let framesOut = isGrid ? layout.channels / 3 : min(layout.channels, 5)
    var points = [InferencePoint]()
    let cellW = Double(sourceWidth) / Double(max(layout.width, 1))
    let cellH = Double(sourceHeight) / Double(max(layout.height, 1))

    for fi in 0..<framesOut {
        let confCh = isGrid ? fi * 3 : fi
        let xOffCh = isGrid ? fi * 3 + 1 : -1
        let yOffCh = isGrid ? fi * 3 + 2 : -1
        var best = -Double.infinity, bCol = 0, bRow = 0
        for row in 0..<layout.height {
            for col in 0..<layout.width {
                let v = valueAt(heatmapOffset(layout: layout, strides: strides, channel: confCh, y: row, x: col))
                if v > best { best = v; bCol = col; bRow = row }
            }
        }
        let conf = normalizedSignal(best)
        let xOff: Double
        let yOff: Double
        if xOffCh >= 0 && yOffCh >= 0 {
            xOff = clampD(valueAt(heatmapOffset(layout: layout, strides: strides, channel: xOffCh, y: bRow, x: bCol)), lo: 0, hi: 1)
            yOff = clampD(valueAt(heatmapOffset(layout: layout, strides: strides, channel: yOffCh, y: bRow, x: bCol)), lo: 0, hi: 1)
        } else {
            xOff = 0.5; yOff = 0.5
        }
        let px = max(0, min(Int(((Double(bCol) + xOff) * cellW).rounded()), sourceWidth - 1))
        let py = max(0, min(Int(((Double(bRow) + yOff) * cellH).rounded()), sourceHeight - 1))
        points.append(InferencePoint(frameIndex: baseFrameIndex + fi, x: px, y: py,
                                     confidence: conf, isVisible: conf >= detectionThreshold))
    }
    return points
}

// MARK: - 帧采样

func generateFrame(generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
    try await withCheckedThrowingContinuation { cont in
        generator.generateCGImageAsynchronously(for: time) { img, _, err in
            if let img { cont.resume(returning: img) }
            else { cont.resume(throwing: err ?? NSError(domain: "Analyze", code: 5, userInfo: nil)) }
        }
    }
}

func sampleWindowedFrames(asset: AVAsset, videoTrack: AVAssetTrack,
                          maxWindows: Int, framesPerWindow: Int) async throws -> [[CGImage]] {
    let n = max(2, framesPerWindow)
    let duration = try await asset.load(.duration)
    let durationSec = max(CMTimeGetSeconds(duration), 0.1)
    let fps = max(Double(try await videoTrack.load(.nominalFrameRate)), 1.0)
    let interval = 1.0 / fps
    let windowSpan = interval * Double(n - 1)
    let maxFitting = max(1, Int((durationSec - windowSpan) / (windowSpan + interval)))
    let windowCount = max(1, min(maxWindows, maxFitting))
    let usable = max(durationSec - windowSpan, interval)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    let tol = CMTime(seconds: interval * 0.45, preferredTimescale: 6000)
    gen.requestedTimeToleranceAfter = tol; gen.requestedTimeToleranceBefore = tol
    var windows = [[CGImage]]()
    for idx in 0..<windowCount {
        let ratio = windowCount == 1 ? 0.5 : Double(idx) / Double(windowCount - 1)
        let start = ratio * usable
        var window = [CGImage]()
        for fo in 0..<n {
            let t = max(0, min(start + Double(fo) * interval, durationSec - 0.001))
            if let f = try? await generateFrame(generator: gen, at: CMTime(seconds: t, preferredTimescale: 6000)) {
                window.append(f)
            }
        }
        if window.count == n { windows.append(window) }
    }
    if windows.isEmpty {
        throw NSError(domain: "Analyze", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法采样帧"])
    }
    return windows
}

// MARK: - 平滑轨迹

func smoothTrajectory(points: [InferencePoint], radius: Int) -> [InferencePoint] {
    let sorted = points.sorted { $0.frameIndex < $1.frameIndex }
    guard sorted.count >= 3 else { return sorted }
    var out = [InferencePoint]()
    out.reserveCapacity(sorted.count)
    for i in sorted.indices {
        let lo = max(sorted.startIndex, i - radius)
        let hi = min(sorted.endIndex - 1, i + radius)
        var wx = 0.0, wy = 0.0, wc = 0.0, ws = 0.0
        for j in lo...hi {
            let d = abs(j - i)
            let tw = Double((radius + 1) - d)
            let cw = max(sorted[j].confidence, 0.12)
            let w = tw * (0.55 + cw)
            wx += Double(sorted[j].x) * w; wy += Double(sorted[j].y) * w
            wc += sorted[j].confidence * w; ws += w
        }
        guard ws > 0 else { out.append(sorted[i]); continue }
        out.append(InferencePoint(frameIndex: sorted[i].frameIndex,
                                  x: Int((wx / ws).rounded()), y: Int((wy / ws).rounded()),
                                  confidence: clampD(wc / ws, lo: 0.12, hi: 0.99), isVisible: true))
    }
    return out
}

// MARK: - 弹跳检测

// 弹跳检测：速度零穿越 + Y 局部极大，使用原始未平滑数据
func detectBounces(from points: [InferencePoint], sourceHeight: Int) -> [InferencePoint] {
    // points 已按 frameIndex 排序（调用方保证）
    guard points.count >= 5 else { return [] }
    let s = points

    // 速度门槛：宽松阈值，保证检出率（TrackNet 输出坐标有±5px噪声）
    let minVyDown   = Double(sourceHeight) * 0.0012  // 降低：允许更慢的入射速度
    let minVyUp     = Double(sourceHeight) * 0.0008  // 降低：允许更慢的反弹速度
    // 落点最小间隔（0.3 秒 @ 60fps = 18 帧，0.3 秒 @ 50fps = 15 帧）
    let minGap      = 15
    let minConf     = 0.25   // 稍低，避免漏掉弱置信度落点

    // 用 3 点差分算每帧 Y 速度（dt 用实际帧号差，处理帧号不连续情况）
    var vyArr = [Double](repeating: 0, count: s.count)
    for i in 1..<(s.count - 1) {
        let dt = Double(max(s[i+1].frameIndex - s[i-1].frameIndex, 1))
        vyArr[i] = Double(s[i+1].y - s[i-1].y) / dt
    }
    vyArr[0]             = vyArr[1]
    vyArr[s.count - 1]   = vyArr[s.count - 2]

    var bounces = [InferencePoint]()
    for i in 2..<(s.count - 2) {
        guard s[i].confidence >= minConf else { continue }

        // 零穿越：前一帧向下、后一帧向上
        let vyPrev = vyArr[i - 1]
        let vyNext = vyArr[i + 1]
        guard vyPrev >= minVyDown, vyNext <= -minVyUp else { continue }

        // Y 坐标是局部极大（允许 ±6px 容差，应对一帧延迟）
        let yMax = max(s[i-1].y, s[i].y, s[i+1].y)
        guard s[i].y >= yMax - 6 else { continue }

        if let last = bounces.last, s[i].frameIndex - last.frameIndex < minGap {
            // 同一次弹跳，保留 Y 值更大（更接近地面）的那个
            if s[i].y > last.y { bounces[bounces.count - 1] = s[i] }
        } else {
            bounces.append(s[i])
        }
    }
    return bounces
}

// MARK: - 动作检测

func angleBetween(dx0: Double, dy0: Double, dx1: Double, dy1: Double) -> Double {
    let m0 = hypot(dx0, dy0), m1 = hypot(dx1, dy1)
    guard m0 > 1e-6, m1 > 1e-6 else { return 0 }
    return acos(clampD((dx0 * dx1 + dy0 * dy1) / (m0 * m1), lo: -1, hi: 1))
}

// 方案C：只检测"击球"和"发球"，放弃不可靠的正/反手分类
func detectActions(from points: [InferencePoint], sourceWidth: Int, sourceHeight: Int) -> [DetectedAction] {
    let s = points.sorted { $0.frameIndex < $1.frameIndex }
    guard s.count >= 7 else { return [] }

    // 击球：速度方向改变 > 45°，且有足够速度
    let minSpeed  = Double(max(sourceWidth, sourceHeight)) * 0.009
    let minAngle  = 0.78   // ~45°
    // 发球区域：球在帧高上方35%，且击打后快速向下
    let serveTop  = Int(Double(sourceHeight) * 0.35)
    let minGap    = 12   // 两次击球最少间隔帧（0.24秒@50fps）

    var actions = [DetectedAction]()
    for i in 2..<(s.count - 2) {
        let p0 = s[i-2], p2 = s[i], p4 = s[i+2]
        let dtIn  = max(p2.frameIndex - p0.frameIndex, 1)
        let dtOut = max(p4.frameIndex - p2.frameIndex, 1)
        let vxI = Double(p2.x - p0.x) / Double(dtIn),  vyI = Double(p2.y - p0.y) / Double(dtIn)
        let vxO = Double(p4.x - p2.x) / Double(dtOut), vyO = Double(p4.y - p2.y) / Double(dtOut)
        let spdI = hypot(vxI, vyI), spdO = hypot(vxO, vyO)
        guard max(spdI, spdO) >= minSpeed else { continue }
        let angle = angleBetween(dx0: vxI, dy0: vyI, dx1: vxO, dy1: vyO)
        guard angle >= minAngle else { continue }

        let aType: ActionType
        let aConf: Double

        if p2.y <= serveTop && vyO > 0 && vyO > abs(vxO) * 0.7 && spdO >= minSpeed * 0.8 {
            // 发球：球在上方 + 击打后向下弧线
            aType  = .serve
            aConf  = min(0.92, 0.60 + (angle / .pi) * 0.20 + s[i].confidence * 0.12)
        } else {
            // 统一标为"击球"，不区分正/反手
            aType  = .forehand   // 复用 forehand 枚举，显示文字改为"击球"
            aConf  = min(0.88, 0.52 + (angle / .pi) * 0.22 + s[i].confidence * 0.14)
        }

        let cand = DetectedAction(frameIndex: p2.frameIndex, x: p2.x, y: p2.y, confidence: aConf, type: aType)
        if let last = actions.last, p2.frameIndex - last.frameIndex < minGap {
            if cand.confidence > last.confidence { actions[actions.count - 1] = cand }
        } else {
            actions.append(cand)
        }
    }
    return actions
}

// MARK: - 叠加渲染 (CoreGraphics, 无 UIKit)

func drawOverlays(
    on pb: CVPixelBuffer,
    renderSize: CGSize,
    modelFrame: Int,
    trajectory: [InferencePoint],
    bounces: [InferencePoint],
    actions: [DetectedAction],
    courtCalib: CourtBoundsCalibration
) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return }

    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)

    // ── 1. 轨迹尾迹：只显示最近 tailFrames 帧，遇大跳跃(切镜/新球)断开 ──
    // frameSkip=2 → 每2帧一个检测点，tailFrames=8 ≈ 4个检测点 ≈ 160ms，短而不延迟
    let tailFrames = 8
    let maxJump: CGFloat = 120   // 像素跳跃超过此值则断线（折角处自然断开重连）
    let recentPts = trajectory
        .filter { $0.frameIndex <= modelFrame && $0.frameIndex > modelFrame - tailFrames }
        .sorted { $0.frameIndex < $1.frameIndex }

    if recentPts.count >= 2 {
        // 将连续点分成若干段（跳跃则断开）
        var segments: [[CGPoint]] = []
        var cur: [CGPoint] = []
        for pt in recentPts {
            let cgpt = CGPoint(x: CGFloat(pt.x), y: CGFloat(pt.y))
            if let last = cur.last, hypot(cgpt.x - last.x, cgpt.y - last.y) > maxJump {
                if cur.count >= 2 { segments.append(cur) }
                cur = [cgpt]
            } else {
                cur.append(cgpt)
            }
        }
        if cur.count >= 2 { segments.append(cur) }

        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for seg in segments {
            // 黑色描边（增强可读性）
            ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            ctx.setLineWidth(5.0)
            ctx.beginPath(); ctx.addLines(between: seg); ctx.strokePath()
            // 黄色主线
            ctx.setStrokeColor(CGColor(red: 0.97, green: 0.91, blue: 0.12, alpha: 0.95))
            ctx.setLineWidth(2.8)
            ctx.beginPath(); ctx.addLines(between: seg); ctx.strokePath()
        }
        // 当前帧球位白点
        if let last = recentPts.last {
            let p = CGPoint(x: CGFloat(last.x), y: CGFloat(last.y))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
            ctx.fillEllipse(in: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
        }
    }

    // ── 2. 弹跳点：在弹跳帧前后 bounceFade 帧内渐显/渐隐（约1秒）──
    let bounceFade = 50   // 50帧 @50fps ≈ 1秒可见
    for bp in bounces {
        let dist = abs(bp.frameIndex - modelFrame)
        guard dist <= bounceFade else { continue }
        // 出现时快速淡入（0~5帧），消失时慢慢淡出
        let alpha: CGFloat
        if dist <= 5 {
            alpha = 0.6 + CGFloat(5 - dist) / 5.0 * 0.4    // 0.6→1.0
        } else {
            alpha = CGFloat(1.0) - CGFloat(dist - 5) / CGFloat(bounceFade - 5)
        }
        let pulse: CGFloat = dist <= 5 ? 12 : 9
        let p = CGPoint(x: CGFloat(bp.x), y: CGFloat(bp.y))
        // 橙色外圈
        ctx.setStrokeColor(CGColor(red: 0.95, green: 0.42, blue: 0.08, alpha: alpha))
        ctx.setLineWidth(2.8)
        ctx.strokeEllipse(in: CGRect(x: p.x-pulse, y: p.y-pulse, width: pulse*2, height: pulse*2))
        // 内实心点
        ctx.setFillColor(CGColor(red: 1.0, green: 0.65, blue: 0.10, alpha: alpha))
        ctx.fillEllipse(in: CGRect(x: p.x-4, y: p.y-4, width: 8, height: 8))
        // 落地瞬间：额外一圈扩散环（dist<=8）
        if dist <= 8 {
            let expand: CGFloat = pulse + CGFloat(dist) * 2.0
            ctx.setStrokeColor(CGColor(red: 1.0, green: 0.70, blue: 0.20, alpha: alpha * 0.5))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: p.x-expand, y: p.y-expand, width: expand*2, height: expand*2))
        }
    }

    // ── 3. 动作标签：带背景框，显示 labelFade 帧 ──
    let labelFade = 20
    if let nearest = actions.min(by: { abs($0.frameIndex - modelFrame) < abs($1.frameIndex - modelFrame) }),
       abs(nearest.frameIndex - modelFrame) <= labelFade {
        let dist = abs(nearest.frameIndex - modelFrame)
        let alpha = 1.0 - Double(dist) / Double(labelFade)
        let p = CGPoint(x: CGFloat(nearest.x), y: CGFloat(nearest.y))

        // 圆点颜色：发球=红色，击球=青色
        let dotColor: CGColor = nearest.type == .serve
            ? CGColor(red: 0.95, green: 0.20, blue: 0.20, alpha: CGFloat(alpha))
            : CGColor(red: 0.00, green: 0.85, blue: 1.00, alpha: CGFloat(alpha))
        ctx.setFillColor(dotColor)
        ctx.fillEllipse(in: CGRect(x: p.x-5, y: p.y-5, width: 10, height: 10))

        // 背景圆角框（发球=深红，击球=深青）
        let label = "\(nearest.type.label)  \(String(format: "%.0f", nearest.confidence * 100))%"
        let boxW: CGFloat = 108, boxH: CGFloat = 30
        let bx = min(max(p.x - 54, 4), CGFloat(w) - boxW - 4)
        let by = max(p.y - 48, 4)
        let boxRect = CGRect(x: bx, y: by, width: boxW, height: boxH)
        let bgColor: CGColor = nearest.type == .serve
            ? CGColor(red: 0.55, green: 0.05, blue: 0.05, alpha: CGFloat(alpha) * 0.85)
            : CGColor(red: 0.00, green: 0.28, blue: 0.42, alpha: CGFloat(alpha) * 0.85)
        ctx.setFillColor(bgColor)
        ctx.addPath(CGPath(roundedRect: boxRect, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.fillPath()
        // 标签文字
        drawText(label, at: CGPoint(x: bx + 9, y: by + 7), in: ctx, size: 13, bold: true)
    }

    // ── 4. 迷你球场（右上角）──
    drawMiniCourt(bounces: bounces.filter { $0.frameIndex <= modelFrame },
                  calib: courtCalib, in: ctx, renderSize: renderSize)

    ctx.restoreGState()
}

func drawText(_ text: String, at point: CGPoint, in ctx: CGContext, size: CGFloat, bold: Bool) {
    let font = CTFontCreateWithName("Helvetica\(bold ? "-Bold" : "")" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attrStr)
    ctx.saveGState()
    ctx.translateBy(x: point.x, y: point.y + size)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - 球场坐标自动校准（从弹跳点分布推断球场区域）

struct CourtBoundsCalibration {
    let xLow: Double   // 视频 x 低端（对应球场一侧边线）
    let xHigh: Double  // 视频 x 高端（对应球场另一侧边线）
    let yNear: Double  // 视频 y 大端（近端底线：离相机近 → 视频下方）
    let yFar: Double   // 视频 y 小端（远端底线：离相机远 → 视频上方）
}

/// 从弹跳点分布自动估算球场在视频里的坐标范围
/// 使用 5–95 百分位数去掉离群点，再留 8% 余量
func estimateCourtBounds(bounces: [InferencePoint], videoW: Int, videoH: Int) -> CourtBoundsCalibration {
    guard bounces.count >= 3 else {
        return CourtBoundsCalibration(xLow: 0, xHigh: Double(videoW),
                                      yNear: Double(videoH), yFar: 0)
    }
    let xs = bounces.map { Double($0.x) }.sorted()
    let ys = bounces.map { Double($0.y) }.sorted()
    let n  = xs.count
    let p05 = Int(Double(n) * 0.05); let p95 = Int(Double(n) * 0.95)
    let xLo = xs[max(0, p05)];       let xHi = xs[min(n-1, p95)]
    let yLo = ys[max(0, p05)];       let yHi = ys[min(n-1, p95)]

    let xMargin = max((xHi - xLo) * 0.08, Double(videoW) * 0.02)
    let yMargin = max((yHi - yLo) * 0.08, Double(videoH) * 0.02)

    return CourtBoundsCalibration(
        xLow:  max(0,            xLo - xMargin),
        xHigh: min(Double(videoW), xHi + xMargin),
        yNear: min(Double(videoH), yHi + yMargin),   // 大 y = 近端
        yFar:  max(0,            yLo - yMargin)       // 小 y = 远端
    )
}

/// 将视频坐标映射到球场俯视图的归一化坐标 [0,1]×[0,1]
/// ─ x 方向：线性映射（xLow→0, xHigh→1）
/// ─ y 方向：透视校正（1/y 线性插值），将远端压缩还原
///   yFar（视频上方 / 小y） → court_y=0 (球场顶端/远端)
///   yNear（视频下方 / 大y）→ court_y=1 (球场底端/近端)
func mapVideoToCourtNorm(_ pt: CGPoint, calib: CourtBoundsCalibration) -> CGPoint {
    let xRange = max(calib.xHigh - calib.xLow, 1)
    let nx = (Double(pt.x) - calib.xLow) / xRange

    // 透视校正：使用倒数插值
    let invY     = 1.0 / max(Double(pt.y), 1.0)
    let invNear  = 1.0 / max(calib.yNear,  1.0)
    let invFar   = 1.0 / max(calib.yFar,   1.0)
    let invRange = invFar - invNear     // invFar > invNear（因为 yFar < yNear）
    let ny: Double
    if abs(invRange) > 1e-9 {
        ny = (invY - invNear) / invRange  // 0 = near, 1 = far
    } else {
        ny = (Double(pt.y) - calib.yFar) / max(calib.yNear - calib.yFar, 1)
    }
    return CGPoint(x: max(0, min(1, nx)), y: max(0, min(1, ny)))
}

func drawMiniCourt(bounces: [InferencePoint], calib: CourtBoundsCalibration,
                   in ctx: CGContext, renderSize: CGSize) {
    // ── 外框 ───────────────────────────────────────────────────
    let mapW: CGFloat = 132, mapH: CGFloat = 208, pad: CGFloat = 12
    let mapX = renderSize.width - mapW - pad
    let mapY = pad
    let bgRect = CGRect(x: mapX, y: mapY, width: mapW, height: mapH)
    ctx.setFillColor(CGColor(red: 0.04, green: 0.10, blue: 0.20, alpha: 0.92))
    ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.fillPath()

    // ── 球场区域（真实比例 23.77×10.97，宽:长≈0.461）─────────────
    let cw: CGFloat = mapW - 26
    let ch: CGFloat = cw / 0.461
    let cx = mapX + (mapW - cw) / 2
    let cy = mapY + (mapH - ch) / 2
    let courtRect = CGRect(x: cx, y: cy, width: cw, height: ch)

    // 底色
    ctx.setFillColor(CGColor(red: 0.14, green: 0.33, blue: 0.62, alpha: 0.95))
    ctx.fill(courtRect)

    // ── 线条 ──────────────────────────────────────────────────
    let doublesW: CGFloat = 10.97, singlesW: CGFloat = 8.23
    let courtLen: CGFloat = 23.77, serviceD: CGFloat = 6.40
    let scaleX = cw / doublesW, scaleY = ch / courtLen
    let sideM  = (doublesW - singlesW) / 2 * scaleX

    ctx.setLineCap(.square)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.setLineWidth(1.5); ctx.stroke(courtRect)

    ctx.setLineWidth(1.0)
    let lx = cx + sideM, rx = cx + cw - sideM
    ctx.move(to: CGPoint(x: lx, y: cy)); ctx.addLine(to: CGPoint(x: lx, y: cy + ch))
    ctx.move(to: CGPoint(x: rx, y: cy)); ctx.addLine(to: CGPoint(x: rx, y: cy + ch))
    ctx.strokePath()

    let netY = cy + ch / 2
    ctx.setLineWidth(2.5)
    ctx.setStrokeColor(CGColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 0.45))
    ctx.move(to: CGPoint(x: cx-1, y: netY+1.5)); ctx.addLine(to: CGPoint(x: cx+cw+1, y: netY+1.5))
    ctx.strokePath()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.move(to: CGPoint(x: cx, y: netY)); ctx.addLine(to: CGPoint(x: cx+cw, y: netY))
    ctx.strokePath()

    ctx.setLineWidth(1.0)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.90))
    let srvOff = serviceD * scaleY
    let srvTop = netY - srvOff, srvBot = netY + srvOff
    let midX = cx + cw / 2
    ctx.move(to: CGPoint(x: lx, y: srvTop)); ctx.addLine(to: CGPoint(x: rx, y: srvTop))
    ctx.move(to: CGPoint(x: lx, y: srvBot)); ctx.addLine(to: CGPoint(x: rx, y: srvBot))
    ctx.move(to: CGPoint(x: midX, y: srvTop)); ctx.addLine(to: CGPoint(x: midX, y: srvBot))
    ctx.strokePath()

    ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 0.8))
    ctx.fill(CGRect(x: cx-2.5, y: netY-3, width: 4, height: 6))
    ctx.fill(CGRect(x: cx+cw-1.5, y: netY-3, width: 4, height: 6))

    // ── 落点（使用透视校正后的坐标）─────────────────────────────
    let recent = Array(bounces.suffix(60))
    let total  = recent.count
    for (i, b) in recent.enumerated() {
        let norm = mapVideoToCourtNorm(CGPoint(x: b.x, y: b.y), calib: calib)
        // 在球场图中，court_y=0 → 近端(视图下方)，court_y=1 → 远端(视图上方)
        // 但球场图 cy 是顶端 → 需要翻转 y：pt.y = cy + (1 - norm.y) * ch
        let pt = CGPoint(x: cx + norm.x * cw, y: cy + (1.0 - CGFloat(norm.y)) * ch)

        let isLast = (i == total - 1)
        let age    = total > 1 ? CGFloat(i) / CGFloat(total - 1) : 1.0
        let alpha: CGFloat = 0.50 + age * 0.50
        let r: CGFloat = isLast ? 4.8 : (1.6 + age * 1.8)

        // 颜色：橙 → 黄绿渐变，最新=亮黄
        ctx.setFillColor(CGColor(red: 1.0, green: CGFloat(0.40 + age * 0.55),
                                 blue: CGFloat(age * 0.12), alpha: alpha))
        ctx.fillEllipse(in: CGRect(x: pt.x-r, y: pt.y-r, width: r*2, height: r*2))

        if isLast {
            // 最新落点：白色外圈 + 闪光扩散环
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: pt.x-7, y: pt.y-7, width: 14, height: 14))
        }

        // 序号标签（最近 8 个）
        let seqStart = max(0, total - 8)
        if i >= seqStart {
            let seq = total - recent.count + i + 1   // 全局落点序号（从1开始）
            let label = "\(seq)"
            // 黑色小圆底
            let badgeR: CGFloat = isLast ? 8 : 7
            let badgeX = min(max(pt.x + 6, cx + badgeR), cx + cw - badgeR)
            let badgeY = min(max(pt.y - 6, cy + badgeR), cy + ch - badgeR)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
            ctx.fillEllipse(in: CGRect(x: badgeX-badgeR, y: badgeY-badgeR,
                                       width: badgeR*2, height: badgeR*2))
            drawText(label, at: CGPoint(x: badgeX - (isLast ? 4 : 3.5),
                                        y: badgeY - (isLast ? 5 : 4.5)),
                     in: ctx, size: isLast ? 8.5 : 7.5, bold: true)
        }
    }
}

// MARK: - 主流程

func run() async throws {
    let videoURL = URL(fileURLWithPath: "/Users/kl/Desktop/Tennisvisionclone/Tennis 测试视频2.mp4")
    let outputURL = URL(fileURLWithPath: "/Users/kl/Desktop/Tennisvisionclone/Tennis 分析结果2.mp4")
    let modelURL = URL(fileURLWithPath: "/Users/kl/Desktop/Tennisvisionclone/Tennis AI/Tennis AI/TrackNet.mlpackage")

    // 新视频共 63 秒，全部分析
    let analyzeSegmentSec = 63.0

    fputs("加载模型...\n", stderr)
    let compiledURL = try await MLModel.compileModel(at: modelURL)
    let model = try MLModel(contentsOf: compiledURL)
    let adapter = try makeInputAdapter(for: model)
    fputs("模型已加载。\n", stderr)

    switch adapter {
    case .image(let name, let w, let h):
        fputs("输入类型: image  name=\(name) \(w)x\(h)\n", stderr)
    case .multiArray(let name, let shape, let layout, _):
        fputs("输入类型: multiArray  name=\(name) shape=\(shape) channels=\(layout.channels) HxW=\(layout.height)x\(layout.width)\n", stderr)
    }

    let asset = AVURLAsset(url: videoURL)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    guard let videoTrack = videoTracks.first else {
        throw NSError(domain: "Analyze", code: 6, userInfo: [NSLocalizedDescriptionKey: "无视频轨道"])
    }
    let duration = try await asset.load(.duration)
    let fullDurationSec = max(CMTimeGetSeconds(duration), 0.1)
    let fps = max(Double(try await videoTrack.load(.nominalFrameRate)), 1.0)
    let naturalSize = try await videoTrack.load(.naturalSize)
    let transform = try await videoTrack.load(.preferredTransform)
    let tSize = naturalSize.applying(transform)
    let videoW = Int(max(abs(tSize.width), 1))
    let videoH = Int(max(abs(tSize.height), 1))

    let segmentSec = min(analyzeSegmentSec, fullDurationSec)
    fputs("视频: \(videoW)x\(videoH)  总时长: \(String(format: "%.1f", fullDurationSec))s  fps: \(String(format: "%.1f", fps))\n", stderr)
    fputs("分析区间: 前 \(String(format: "%.0f", segmentSec)) 秒\n", stderr)

    // ── 原版 GridTrackNet 参数：保持5帧跨度约0.167秒 ──
    // 30fps → frameSkip=1（每帧），60fps → frameSkip=2（隔帧）
    // 50fps → frameSkip=2（隔帧，5帧跨200ms，最接近训练分布）
    let framesPerWindow: Int
    if case .multiArray(_, _, let layout, _) = adapter, layout.channels >= 9, layout.channels % 3 == 0 {
        framesPerWindow = max(3, layout.channels / 3)   // = 5
    } else {
        framesPerWindow = 1
    }
    // 按 fps 选择帧间隔，与原版保持一致
    let frameSkip: Int
    if fps >= 45 {
        frameSkip = 2   // 50/60fps → 隔帧采样，5帧跨约0.2s
    } else {
        frameSkip = 1   // 25/30fps → 每帧，5帧跨约0.17s
    }
    // stride=1（相对于有效采样帧），中心帧精度最高
    let centerIdx = framesPerWindow / 2   // = 2
    let totalSegFrames = Int(segmentSec * fps)
    // 有效采样帧序号（每 frameSkip 个物理帧取一个）
    let sampledCount   = totalSegFrames / frameSkip
    let firstCenter    = centerIdx
    let lastCenter     = sampledCount - 1 - centerIdx
    let windowCount    = max(1, lastCenter - firstCenter + 1)
    fputs("总帧数: \(totalSegFrames)  帧间隔: \(frameSkip)  有效推理帧: \(windowCount)  模式: stride=1·中心帧\n", stderr)

    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    let tol = CMTime(seconds: 0.5 / fps, preferredTimescale: 6000)
    gen.requestedTimeToleranceAfter = tol
    gen.requestedTimeToleranceBefore = tol

    var allPoints = [InferencePoint]()
    var successCount = 0

    for wi in 0..<windowCount {
        // sampledCenter = 在"采样帧"序列中的中心索引
        let sampledCenter  = firstCenter + wi
        // 对应物理帧号
        let physicalCenter = sampledCenter * frameSkip
        // 窗口的物理帧：center ± 2 * frameSkip
        var window = [CGImage]()
        for fo in 0..<framesPerWindow {
            // 原版：[center-2, center-1, center, center+1, center+2] * frameSkip
            let offset = fo - centerIdx               // -2,-1,0,+1,+2
            let fi     = physicalCenter + offset * frameSkip
            let t = CMTime(seconds: Double(max(fi, 0)) / fps, preferredTimescale: 6000)
            if let f = try? await generateFrame(generator: gen, at: t) { window.append(f) }
        }
        guard window.count == framesPerWindow else { continue }
        do {
            let provider = try makeProvider(forFrames: window, using: adapter)
            let output   = try await model.prediction(from: provider, options: MLPredictionOptions())
            let ref      = window[centerIdx]
            let allPts   = decodeTrackNetOutput(output, sourceWidth: ref.width, sourceHeight: ref.height,
                                                baseFrameIndex: sampledCenter * framesPerWindow)
            // 只取中心帧输出（index = centerIdx），记录为物理帧号
            if allPts.indices.contains(centerIdx) {
                var pt = allPts[centerIdx]
                // 用物理帧号让渲染和弹跳检测对齐
                pt = InferencePoint(frameIndex: physicalCenter,
                                    x: pt.x, y: pt.y,
                                    confidence: pt.confidence, isVisible: pt.isVisible)
                allPoints.append(pt)
                successCount += 1
            }
        } catch { /* 单帧失败静默跳过 */ }
        if (wi + 1) % 100 == 0 || wi == windowCount - 1 {
            fputs("  推理进度: \(wi + 1)/\(windowCount)\n", stderr)
        }
    }

    fputs("推理完成: \(allPoints.count) 个点，成功 \(successCount) 次\n", stderr)
    let visible = allPoints.filter(\.isVisible)
    fputs("  阈值 \(detectionThreshold) 以上: \(visible.count) 个\n", stderr)

    // 打印 Top-10 置信度以便诊断
    let top10 = allPoints.sorted { $0.confidence > $1.confidence }.prefix(10)
    fputs("  Top-10 置信度: \(top10.map { String(format: "%.3f", $0.confidence) }.joined(separator: ", "))\n", stderr)

    // 可见点不足时自适应降低阈值
    let effectivePoints: [InferencePoint]
    if visible.count < 5 && !allPoints.isEmpty {
        let best = allPoints.max(by: { $0.confidence < $1.confidence })?.confidence ?? 0
        let fallback = max(best * 0.50, 0.05)
        fputs("  可见点不足，降低阈值至 \(String(format: "%.3f", fallback))\n", stderr)
        effectivePoints = allPoints.filter { $0.confidence >= fallback }
    } else {
        effectivePoints = visible
    }

    // 三级数据策略：
    //   raw effectivePoints   → 保留落地瞬间的速度突变，用于弹跳检测
    //   轻平滑（radius=2）    → 保留击球时的方向改变，用于动作检测
    //   微平滑（radius=1）    → 轨迹显示：只做3点去噪，保留直线段和折角
    let rawPoints      = effectivePoints.sorted { $0.frameIndex < $1.frameIndex }
    let lightSmoothed  = smoothTrajectory(points: effectivePoints, radius: 2)
    let smoothed       = smoothTrajectory(points: effectivePoints, radius: 1)
    let bounces        = detectBounces(from: rawPoints, sourceHeight: videoH)
    let actionsDetected = detectActions(from: lightSmoothed, sourceWidth: videoW, sourceHeight: videoH)

    // 从所有弹跳点自动校准球场坐标范围
    let courtCalib = estimateCourtBounds(bounces: bounces, videoW: videoW, videoH: videoH)
    fputs("球场自动校准: x[\(Int(courtCalib.xLow))–\(Int(courtCalib.xHigh))] y远=\(Int(courtCalib.yFar))  y近=\(Int(courtCalib.yNear))\n", stderr)
    fputs("球轨迹: \(smoothed.count) 点  弹跳: \(bounces.count)  动作: \(actionsDetected.count)\n", stderr)
    let fwd = actionsDetected.filter { $0.type == .forehand }.count
    let bwd = actionsDetected.filter { $0.type == .backhand }.count
    let srv = actionsDetected.filter { $0.type == .serve }.count
    fputs("动作分布: 正手 \(fwd) / 反手 \(bwd) / 发球 \(srv)\n", stderr)

    // 渲染输出视频（只渲染前 60 秒）
    let segmentDuration = CMTime(seconds: segmentSec, preferredTimescale: 600)
    fputs("\n渲染输出视频（前 \(String(format: "%.0f", segmentSec)) 秒）...\n", stderr)
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }

    let renderSize = CGSize(width: videoW, height: videoH)
    let nomFPS = fps > 1 ? fps : 30.0
    let frameDur = CMTime(seconds: 1.0 / nomFPS, preferredTimescale: 600)

    let vc = AVMutableVideoComposition()
    vc.renderSize = renderSize; vc.frameDuration = frameDur
    let inst = AVMutableVideoCompositionInstruction()
    inst.timeRange = CMTimeRange(start: .zero, duration: segmentDuration)
    let li = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
    li.setTransform(transform, at: .zero)
    inst.layerInstructions = [li]; vc.instructions = [inst]

    guard let reader = try? AVAssetReader(asset: asset) else {
        throw NSError(domain: "Analyze", code: 7, userInfo: [NSLocalizedDescriptionKey: "AVAssetReader 初始化失败"])
    }
    reader.timeRange = CMTimeRange(start: .zero, duration: segmentDuration)
    let ro = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack],
        videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
    ro.videoComposition = vc; ro.alwaysCopiesSampleData = false
    guard reader.canAdd(ro) else {
        throw NSError(domain: "Analyze", code: 7, userInfo: [NSLocalizedDescriptionKey: "无法添加 ReaderOutput"])
    }
    reader.add(ro)

    guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
        throw NSError(domain: "Analyze", code: 8, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter 初始化失败"])
    }
    let wi = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: videoW, AVVideoHeightKey: videoH
    ])
    wi.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: wi, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: videoW, kCVPixelBufferHeightKey as String: videoH
    ])
    guard writer.canAdd(wi) else {
        throw NSError(domain: "Analyze", code: 8, userInfo: [NSLocalizedDescriptionKey: "无法添加 WriterInput"])
    }
    writer.add(wi)
    guard reader.startReading() else {
        throw NSError(domain: "Analyze", code: 7, userInfo: [NSLocalizedDescriptionKey: "Reader 启动失败"])
    }
    guard writer.startWriting() else {
        throw NSError(domain: "Analyze", code: 8, userInfo: [NSLocalizedDescriptionKey: "Writer 启动失败"])
    }
    writer.startSession(atSourceTime: .zero)

    let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
    let cs = CGColorSpaceCreateDeviceRGB()
    var frameCount = 0
    let totalRenderFrames = max(Int(segmentSec * nomFPS), 1)

    while reader.status == .reading {
        guard let sb = ro.copyNextSampleBuffer() else { break }
        guard let srcPB = CMSampleBufferGetImageBuffer(sb) else { continue }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let ptsSec = CMTimeGetSeconds(pts)
        if ptsSec > segmentSec { break }
        // 将时间戳直接转换为帧索引，与推理时保持一致
        let modelFrame = Int((ptsSec * fps).rounded())
        while !wi.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
        guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "Analyze", code: 9, userInfo: [NSLocalizedDescriptionKey: "PixelBufferPool 不可用"])
        }
        var outPBRef: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPBRef) == kCVReturnSuccess, let outPB = outPBRef else {
            throw NSError(domain: "Analyze", code: 9, userInfo: [NSLocalizedDescriptionKey: "创建输出帧失败"])
        }
        let srcImg = CIImage(cvPixelBuffer: srcPB)
        ciCtx.render(srcImg, to: outPB, bounds: CGRect(origin: .zero, size: renderSize), colorSpace: cs)
        drawOverlays(on: outPB, renderSize: renderSize, modelFrame: modelFrame,
                     trajectory: smoothed, bounces: bounces, actions: actionsDetected,
                     courtCalib: courtCalib)
        if !adaptor.append(outPB, withPresentationTime: pts) { break }
        frameCount += 1
        if frameCount % 150 == 0 {
            fputs("  渲染进度: \(frameCount)/~\(totalRenderFrames)\n", stderr)
        }
    }
    if reader.status == .failed {
        fputs("读取失败: \(reader.error?.localizedDescription ?? "未知")\n", stderr)
    }
    wi.markAsFinished()
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        writer.finishWriting { cont.resume() }
    }

    if writer.status == .completed {
        fputs("\n完成！共渲染 \(frameCount) 帧\n", stderr)
        print(outputURL.path)
        fputs("输出文件: \(outputURL.path)\n", stderr)
    } else {
        throw NSError(domain: "Analyze", code: 8,
                      userInfo: [NSLocalizedDescriptionKey: "写入失败: \(writer.error?.localizedDescription ?? "未知")"])
    }
}

// MARK: - 入口

let mainSema = DispatchSemaphore(value: 0)
Task {
    do {
        try await run()
    } catch {
        fputs("Fatal: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    mainSema.signal()
}
mainSema.wait()
