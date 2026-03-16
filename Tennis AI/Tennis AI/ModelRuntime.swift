//
//  ModelRuntime.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/11.
//

import CoreML
import CoreVideo
import Foundation

struct LoadedOnDeviceModel {
    let name: String
    let model: MLModel
}

struct ModelIODescriptor: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let detail: String

    init(name: String, type: String, detail: String) {
        self.id = "\(name)|\(type)|\(detail)"
        self.name = name
        self.type = type
        self.detail = detail
    }
}

struct LoadedModelDiagnostics: Equatable {
    let modelName: String
    let inputDescriptors: [ModelIODescriptor]
    let outputDescriptors: [ModelIODescriptor]

    static func from(modelName: String, model: MLModel) -> LoadedModelDiagnostics {
        let description = model.modelDescription
        var inputDescriptors: [ModelIODescriptor] = []
        for name in description.inputDescriptionsByName.keys.sorted() {
            if let feature = description.inputDescriptionsByName[name] {
                inputDescriptors.append(describe(name: name, feature: feature))
            }
        }

        var outputDescriptors: [ModelIODescriptor] = []
        for name in description.outputDescriptionsByName.keys.sorted() {
            if let feature = description.outputDescriptionsByName[name] {
                outputDescriptors.append(describe(name: name, feature: feature))
            }
        }

        return LoadedModelDiagnostics(
            modelName: modelName,
            inputDescriptors: inputDescriptors,
            outputDescriptors: outputDescriptors
        )
    }

    private static func describe(name: String, feature: MLFeatureDescription) -> ModelIODescriptor {
        switch feature.type {
        case .image:
            let width = feature.imageConstraint?.pixelsWide ?? 0
            let height = feature.imageConstraint?.pixelsHigh ?? 0
            let channels = feature.imageConstraint?.pixelFormatType == kCVPixelFormatType_OneComponent8 ? "灰度" : "彩色"
            return ModelIODescriptor(
                name: name,
                type: "image",
                detail: "\(max(width, 1))x\(max(height, 1)) \(channels)"
            )
        case .multiArray:
            if let constraint = feature.multiArrayConstraint {
                let shape = constraint.shape.map { String(Int(truncating: $0)) }.joined(separator: "x")
                return ModelIODescriptor(
                    name: name,
                    type: "multiArray",
                    detail: "shape \(shape), \(constraint.dataType.label)"
                )
            }
            return ModelIODescriptor(name: name, type: "multiArray", detail: "未声明约束")
        case .string:
            return ModelIODescriptor(name: name, type: "string", detail: "文本")
        case .int64:
            return ModelIODescriptor(name: name, type: "int64", detail: "整数")
        case .double:
            return ModelIODescriptor(name: name, type: "double", detail: "浮点")
        case .dictionary:
            return ModelIODescriptor(name: name, type: "dictionary", detail: "字典")
        case .sequence:
            return ModelIODescriptor(name: name, type: "sequence", detail: "序列")
        case .state:
            return ModelIODescriptor(name: name, type: "state", detail: "状态")
        case .invalid:
            return ModelIODescriptor(name: name, type: "invalid", detail: "无效")
        @unknown default:
            return ModelIODescriptor(name: name, type: "unknown", detail: "未知")
        }
    }
}

extension MLMultiArrayDataType {
    var label: String {
        switch self {
        case .double:
            return "double"
        case .float32:
            return "float32"
        case .float16:
            return "float16"
        case .int32:
            return "int32"
        case .int8:
            return "int8"
        @unknown default:
            return "unknown"
        }
    }
}

enum OnDeviceModelStatus: Equatable {
    case checking
    case ready(modelName: String)
    case missing(expectedNames: [String])
    case failed(message: String)

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    var summaryTitle: String {
        switch self {
        case .checking:
            return "本地模型初始化中"
        case .ready:
            return "本地模型已就绪"
        case .missing:
            return "未检测到本地模型"
        case .failed:
            return "本地模型加载失败"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            return "正在从 App Bundle 加载 Core ML 模型，请稍后重试。"
        case .ready(let modelName):
            return "已加载 \(modelName).mlmodelc，后续任务将使用本地推理。"
        case .missing(let expectedNames):
            let preferredName = expectedNames.first ?? "TrackNet"
            return "请把 \(preferredName).mlmodel 加入 Tennis AI target（Xcode 会自动编译为 .mlmodelc）。"
        case .failed(let message):
            return message
        }
    }

    var uploadBlockedMessage: String? {
        switch self {
        case .ready:
            return nil
        case .checking:
            return "本地模型正在初始化，请稍后再试。"
        case .missing(let expectedNames):
            let preferredName = expectedNames.first ?? "TrackNet"
            return "未找到本地模型。请将 \(preferredName).mlmodel 放入 App 并勾选 Tennis AI target。"
        case .failed(let message):
            return "本地模型加载失败：\(message)"
        }
    }
}

enum OnDeviceModelLoaderError: LocalizedError {
    case noModelFound(expectedNames: [String])
    case loadFailed(modelName: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noModelFound(let expectedNames):
            let names = expectedNames.joined(separator: ", ")
            return "Bundle 中未找到可用模型（候选: \(names)）。"
        case .loadFailed(let modelName, let reason):
            return "\(modelName).mlmodelc 加载失败：\(reason)"
        }
    }
}

struct OnDeviceModelLoader {
    let bundle: Bundle
    let expectedModelNames: [String]

    init(
        bundle: Bundle = .main,
        expectedModelNames: [String] = ["TrackNet", "TrackNetTennis", "TennisTrackNet"]
    ) {
        self.bundle = bundle
        self.expectedModelNames = expectedModelNames
    }

    func loadFirstAvailableModel() throws -> LoadedOnDeviceModel {
        for modelName in expectedModelNames {
            if let url = bundle.url(forResource: modelName, withExtension: "mlmodelc") {
                return try loadModel(at: url, modelName: modelName)
            }
        }

        if let fallbackURL = bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil)?.first {
            let fallbackName = fallbackURL.deletingPathExtension().lastPathComponent
            return try loadModel(at: fallbackURL, modelName: fallbackName)
        }

        throw OnDeviceModelLoaderError.noModelFound(expectedNames: expectedModelNames)
    }

    private func loadModel(at url: URL, modelName: String) throws -> LoadedOnDeviceModel {
        do {
            let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
            return LoadedOnDeviceModel(name: modelName, model: model)
        } catch {
            throw OnDeviceModelLoaderError.loadFailed(
                modelName: modelName,
                reason: error.localizedDescription
            )
        }
    }
}
