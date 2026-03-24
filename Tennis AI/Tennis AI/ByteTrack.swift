// ByteTrack.swift
// Tennis AI
//
// 轻量级 ByteTrack 实现：IoU 匹配 + 简单 Kalman 滤波
// 用于跨帧持续追踪人物 bounding box
//

import CoreGraphics
import Foundation

// MARK: - 数据结构

struct TrackedPerson: Identifiable {
    let trackID: Int
    var box: CGRect          // 归一化坐标 [0,1]
    var score: Float
    var age: Int             // 连续出现帧数
    var missedFrames: Int    // 连续丢失帧数
    var kalman: KalmanBox

    var id: Int { trackID }
    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

// MARK: - Kalman 滤波（匀速模型：状态 = [cx, cy, w, h, vx, vy, vw, vh]）

struct KalmanBox {
    // 状态向量 [cx, cy, w, h, vx, vy, vw, vh]
    var x: [Double]
    // 协方差对角阵（简化为向量）
    var P: [Double]

    static let Q: [Double] = [1e-2, 1e-2, 1e-4, 1e-4, 1e-1, 1e-1, 1e-3, 1e-3]
    static let R: [Double] = [1e-1, 1e-1, 1e-1, 1e-1]

    init(box: CGRect) {
        let cx = Double(box.midX)
        let cy = Double(box.midY)
        let w  = Double(box.width)
        let h  = Double(box.height)
        x = [cx, cy, w, h, 0, 0, 0, 0]
        P = [10, 10, 10, 10, 1e4, 1e4, 1e2, 1e2]
    }

    // 预测步骤（dt=1 帧）
    mutating func predict() {
        x[0] += x[4]; x[1] += x[5]; x[2] += x[6]; x[3] += x[7]
        for i in 0..<8 { P[i] += KalmanBox.Q[i] }
    }

    // 更新步骤（观测 = [cx, cy, w, h]）
    mutating func update(box: CGRect) {
        let z = [Double(box.midX), Double(box.midY), Double(box.width), Double(box.height)]
        for i in 0..<4 {
            let K = P[i] / (P[i] + KalmanBox.R[i])
            x[i] = x[i] + K * (z[i] - x[i])
            P[i] = (1 - K) * P[i]
        }
    }

    var predictedBox: CGRect {
        CGRect(
            x: x[0] - x[2] / 2,
            y: x[1] - x[3] / 2,
            width: max(x[2], 0.01),
            height: max(x[3], 0.01)
        )
    }
}

// MARK: - ByteTracker

final class ByteTracker {
    private var tracks: [TrackedPerson] = []
    private var nextID = 1
    private let maxMissedFrames = 30   // 丢失超过此帧数则删除
    private let highThreshold: Float = 0.5
    private let lowThreshold: Float  = 0.1
    private let iouThreshold: Double = 0.3

    /// 每帧调用：传入当前帧检测结果，返回所有活跃 track
    @discardableResult
    func update(detections: [(box: CGRect, score: Float)]) -> [TrackedPerson] {
        // 1. Kalman 预测
        for i in tracks.indices { tracks[i].kalman.predict() }

        // 2. 分高/低置信度检测
        let high = detections.filter { $0.score >= highThreshold }
        let low  = detections.filter { $0.score >= lowThreshold && $0.score < highThreshold }

        // 3. 第一轮：高置信度 vs 现有 track
        var unmatched: [TrackedPerson] = []
        var usedDets = Set<Int>()
        var matchedTrackIDs = Set<Int>()

        let costs = costMatrix(tracks: tracks, dets: high)
        let assignment = hungarianMin(costs: costs, rows: tracks.count, cols: high.count)

        for (ti, di) in assignment {
            guard iou(tracks[ti].kalman.predictedBox, high[di].box) >= iouThreshold else {
                unmatched.append(tracks[ti]); continue
            }
            tracks[ti].kalman.update(box: high[di].box)
            tracks[ti].box = tracks[ti].kalman.predictedBox
            tracks[ti].score = high[di].score
            tracks[ti].age += 1
            tracks[ti].missedFrames = 0
            matchedTrackIDs.insert(tracks[ti].trackID)
            usedDets.insert(di)
        }
        for i in tracks.indices where !matchedTrackIDs.contains(tracks[i].trackID) {
            unmatched.append(tracks[i])
        }

        // 4. 第二轮：低置信度 vs 未匹配 track
        let costs2 = costMatrix(tracks: unmatched, dets: low)
        let assignment2 = hungarianMin(costs: costs2, rows: unmatched.count, cols: low.count)
        var matchedUnmatched = Set<Int>()

        for (ti, di) in assignment2 {
            guard iou(unmatched[ti].kalman.predictedBox, low[di].box) >= iouThreshold else { continue }
            let origIdx = tracks.firstIndex(where: { $0.trackID == unmatched[ti].trackID })!
            tracks[origIdx].kalman.update(box: low[di].box)
            tracks[origIdx].box = tracks[origIdx].kalman.predictedBox
            tracks[origIdx].score = low[di].score
            tracks[origIdx].age += 1
            tracks[origIdx].missedFrames = 0
            matchedTrackIDs.insert(tracks[origIdx].trackID)
            matchedUnmatched.insert(ti)
        }

        // 5. 未匹配 track：增加 missedFrames
        for i in tracks.indices where !matchedTrackIDs.contains(tracks[i].trackID) {
            tracks[i].missedFrames += 1
            tracks[i].box = tracks[i].kalman.predictedBox
        }

        // 6. 未匹配检测 → 新建 track
        let allUsedHigh = Set((0..<high.count).filter { di in
            assignment.contains(where: { $0.1 == di })
        })
        for di in 0..<high.count where !allUsedHigh.contains(di) {
            let det = high[di]
            let kalman = KalmanBox(box: det.box)
            tracks.append(TrackedPerson(
                trackID: nextID, box: det.box, score: det.score,
                age: 1, missedFrames: 0, kalman: kalman
            ))
            nextID += 1
        }

        // 7. 清理过期 track
        tracks.removeAll { $0.missedFrames > maxMissedFrames }

        return tracks.filter { $0.missedFrames == 0 }
    }

    func reset() { tracks = []; nextID = 1 }

    // MARK: - 工具

    private func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = Double(inter.width * inter.height)
        let unionArea = Double(a.width * a.height + b.width * b.height) - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    private func costMatrix(tracks: [TrackedPerson], dets: [(box: CGRect, score: Float)]) -> [[Double]] {
        tracks.map { t in dets.map { d in 1.0 - iou(t.kalman.predictedBox, d.box) } }
    }

    /// 简化版匈牙利算法（贪心近似，足够实时用）
    private func hungarianMin(costs: [[Double]], rows: Int, cols: Int) -> [(Int, Int)] {
        guard rows > 0, cols > 0 else { return [] }
        var result: [(Int, Int)] = []
        var usedCols = Set<Int>()
        // 按最小代价贪心匹配
        var flat: [(Double, Int, Int)] = []
        for r in 0..<rows {
            for c in 0..<cols { flat.append((costs[r][c], r, c)) }
        }
        flat.sort { $0.0 < $1.0 }
        var usedRows = Set<Int>()
        for (cost, r, c) in flat {
            if cost >= 1.0 { break }
            if usedRows.contains(r) || usedCols.contains(c) { continue }
            result.append((r, c))
            usedRows.insert(r); usedCols.insert(c)
        }
        return result
    }
}
