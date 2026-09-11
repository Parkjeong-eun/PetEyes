//
//  VisionDetector.swift
//  PetEyes
//

import AVFoundation
import Vision

/// 한 프레임에서 뽑은 결과. 백그라운드 큐 → 메인으로 넘어가는 유일한 값.
nonisolated struct DetectionResult: Sendable {
    /// 가장 큰 얼굴의 boundingBox (Vision 정규화 좌표). 없으면 nil
    var face: CGRect?
    /// 가리키는 손 (여러 손이면 가장 큰 손). 없으면 nil
    var pointing: Pointing?
}

/// 카메라 + Vision. 백그라운드 큐에서 동작한다.
///
/// 프로젝트가 기본 MainActor 격리(SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor)라서
/// `nonisolated`를 명시해야 한다. 카메라 델리게이트가 videoQueue에서 불리기 때문.
nonisolated final class VisionDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// 프레임마다 videoQueue에서 호출.
    var onResult: (@Sendable (DetectionResult) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pet.eyes.session")
    private let videoQueue = DispatchQueue(label: "pet.eyes.video")
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private let handler = VNSequenceRequestHandler()
    private var orientation: CGImagePropertyOrientation = .leftMirrored
    private var configured = false
    /// 얼굴·손 위치만 필요하니 20fps면 충분 (발열·배터리)
    private let fps: Double = 20

    func setOrientation(_ o: CGImagePropertyOrientation) {
        videoQueue.async { self.orientation = o }
    }

    func start() {
        sessionQueue.async {
            if !self.configured { self.configure() }
            if self.configured, !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        // 얼굴 '위치'만 필요하니 저해상도로 충분 (발열·배터리 절약)
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        // 프레임레이트 제한 — 지원 범위 밖이면 예외가 나므로 범위 확인 후 설정
        let supported = device.activeFormat.videoSupportedFrameRateRanges
            .contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        if supported {
            do {
                try device.lockForConfiguration()
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMaxFrameDuration = duration
                device.activeVideoMinFrameDuration = duration
                device.unlockForConfiguration()
            } catch {
                // 실패해도 기본 프레임레이트로 동작
            }
        }
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        do {
            // 얼굴과 손을 같은 프레임에서 한 번에
            try handler.perform([faceRequest, handRequest], on: pixelBuffer, orientation: orientation)
        } catch {
            return
        }

        // 여러 명이면 가장 큰 얼굴(= 가장 가까운 사람)을 본다
        let face = faceRequest.results?.max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }

        // 가리키는 손이 여럿이면 가장 큰(= 가까운) 손
        let pointing = handRequest.results?
            .compactMap { PointingGesture.detect(in: $0) }
            .max { $0.palmLength < $1.palmLength }

        onResult?(DetectionResult(face: face?.boundingBox, pointing: pointing))
    }
}
