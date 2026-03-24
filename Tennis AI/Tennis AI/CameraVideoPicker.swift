//
//  CameraVideoPicker.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/11.
//

import SwiftUI

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

struct CameraVideoPicker: UIViewControllerRepresentable {
    let onCapture: (URL) -> Void
    let onError: (String) -> Void

    static var isSupported: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 120
        picker.modalPresentationStyle = .fullScreen
        picker.cameraOverlayView = context.coordinator.makeGuideOverlay(frame: UIScreen.main.bounds)
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraVideoPicker
        private var overlayHost: UIHostingController<CameraGuideOverlay>?

        init(parent: CameraVideoPicker) {
            self.parent = parent
        }

        func makeGuideOverlay(frame: CGRect) -> UIView {
            let host = UIHostingController(rootView: CameraGuideOverlay())
            host.view.frame = frame
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlayHost = host
            return host.view
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            defer {
                picker.dismiss(animated: true)
            }

            guard let capturedURL = info[.mediaURL] as? URL else {
                parent.onError("未获取到录制视频，请重试。")
                return
            }

            do {
                let copiedURL = try copyCapturedVideoToTemp(sourceURL: capturedURL)
                parent.onCapture(copiedURL)
            } catch {
                parent.onError("保存拍摄视频失败：\(error.localizedDescription)")
            }
        }

        private func copyCapturedVideoToTemp(sourceURL: URL) throws -> URL {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let fileName = "record_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6)).mov"
            let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }
    }
}

private struct CameraGuideOverlay: View {
    @State private var blink = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                Path { path in
                    let topInset = height * 0.14
                    let bottomInset = height * 0.22
                    let guideHeight = max(100, height - topInset - bottomInset)
                    let y0 = topInset
                    let xThird = width / 3
                    let yThird = guideHeight / 3

                    path.move(to: CGPoint(x: xThird, y: y0))
                    path.addLine(to: CGPoint(x: xThird, y: y0 + guideHeight))
                    path.move(to: CGPoint(x: xThird * 2, y: y0))
                    path.addLine(to: CGPoint(x: xThird * 2, y: y0 + guideHeight))

                    path.move(to: CGPoint(x: 0, y: y0 + yThird))
                    path.addLine(to: CGPoint(x: width, y: y0 + yThird))
                    path.move(to: CGPoint(x: 0, y: y0 + yThird * 2))
                    path.addLine(to: CGPoint(x: width, y: y0 + yThird * 2))
                }
                .stroke(Color.white.opacity(0.26), lineWidth: 1)

                VStack(spacing: 0) {
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 9, height: 9)
                            .opacity(blink ? 0.35 : 1)
                        Text("REC READY")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.95))
                        Spacer()
                        Text("1080P / 60FPS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.90))
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .background(Color.black.opacity(0.28))

                    Spacer()

                    Text("保持横屏稳定，并尽量拍完整球场线")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.32))
                        .clipShape(Capsule())
                        .padding(.bottom, 130)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    blink = true
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

#else

struct CameraVideoPicker: View {
    let onCapture: (URL) -> Void
    let onError: (String) -> Void

    static var isSupported: Bool { false }

    var body: some View {
        Color.clear
            .onAppear {
                onError("当前平台不支持系统相机录制。")
            }
    }
}

#endif
