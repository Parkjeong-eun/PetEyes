//
//  FaceTracker.swift
//  PetEyes
//

import AVFoundation
import Vision
import UIKit
import Observation

// MARK: - FaceTracker (UI가 구독하는 쪽)

/// 전면 카메라로 사용자 얼굴 위치를 읽어서 "눈이 볼 방향"으로 바꿔준다.
@MainActor
@Observable
final class FaceTracker {
    /// 눈동자가 볼 방향. -1...1 (화면 기준 오른쪽 +x, 위쪽 +y)
    private(set) var gaze: CGPoint = .zero
    /// 0...1, 얼굴이 가까울수록 1 (가운데로 몰린 눈 연출용)
    private(set) var closeness: CGFloat = 0
    private(set) var hasFace = false
    /// 마지막으로 검출된 얼굴 박스 폭(0...1, Vision 정규화). closenessRange 튜닝용 원시값
    private(set) var faceWidth: CGFloat = 0

    // MARK: 튜닝 값 — 실제 기기에 붙여보고 조정 (README 체크리스트 참고)
    /// 카메라 화각 대비 눈 움직임 증폭. 클수록 조금만 움직여도 끝까지 봄
    var gain: CGFloat = 1.8
    /// 카메라가 화면 정중앙에 있지 않아서 생기는 치우침 보정 (-1...1 단위)
    var bias = CGPoint(x: 0, y: 0)
    /// 사용자가 오른쪽으로 갔는데 눈이 왼쪽을 보면 true
    var invertX = false
    /// 0...1, 클수록 즉각 반응(대신 떨림 증가)
    var smoothing: CGFloat = 0.35
    /// 얼굴 박스 폭(0...1)을 closeness 0...1로 옮기는 구간. 이하 → 멀다, 이상 → 아주 가깝다.
    /// 640×480 전면 카메라 기준 팔 길이(~50cm)에서 폭 ≈ 0.12~0.18, 얼굴을 바짝 대면 ≈ 0.35+
    var closenessRange: ClosedRange<CGFloat> = 0.12...0.32

    /// 20fps 기준 약 0.4초 동안 못 찾으면 '없음'으로 판정
    private let missedFrameLimit = 8

    private let detector = FaceDetector()
    private var missedFrames = 0

    /// 카메라 권한을 요청하고 추적을 시작한다. 거부되면 아무것도 하지 않는다 (아이들 애니메이션만 동작).
    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        detector.onResult = { [weak self] box in
            guard let self else { return }
            Task { @MainActor in self.handle(box) }
        }
        updateOrientation()
        detector.start()
    }

    /// 백그라운드에서 돌아왔을 때. 권한이 이미 있을 때만 재개.
    func resume() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        updateOrientation()
        detector.start()
    }

    func stop() { detector.stop() }

    /// 화면 방향이 바뀌면 호출. Vision에 "이 버퍼가 어느 쪽이 위인지" 알려줘야 좌표가 맞음.
    func updateOrientation() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let interface = scene?.effectiveGeometry.interfaceOrientation ?? .portrait
        // 전면 카메라 기준 (Apple 샘플 "Tracking the User's Face in Real Time").
        // *Mirrored → 셀카 화면처럼 좌우가 뒤집힌 좌표가 나와서
        // "사용자가 오른쪽으로 가면 x도 +"가 된다. 실기기에서 뒤집히면 invertX로 보정.
        let exif: CGImagePropertyOrientation = switch interface {
        case .portraitUpsideDown: .rightMirrored
        case .landscapeLeft:      .upMirrored
        case .landscapeRight:     .downMirrored
        default:                  .leftMirrored
        }
        detector.setOrientation(exif)
    }

    private func handle(_ box: CGRect?) {
        guard let box else {
            missedFrames += 1
            if missedFrames > missedFrameLimit {
                hasFace = false
                closeness = 0
                faceWidth = 0
            }
            return
        }
        missedFrames = 0
        hasFace = true
        faceWidth = box.width

        // Vision 좌표: 0...1, 원점은 좌하단 → 중심 기준 -1...1
        var x = (box.midX - 0.5) * 2 + bias.x
        let y = (box.midY - 0.5) * 2 + bias.y
        if invertX { x = -x }

        let target = CGPoint(x: clamp(x * gain), y: clamp(y * gain))
        gaze = CGPoint(x: gaze.x + (target.x - gaze.x) * smoothing,
                       y: gaze.y + (target.y - gaze.y) * smoothing)

        // 얼굴 박스 폭으로 거리 근사
        let span = closenessRange.upperBound - closenessRange.lowerBound
        let near = clamp((box.width - closenessRange.lowerBound) / span, 0, 1)
        closeness += (near - closeness) * smoothing
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat = -1, _ hi: CGFloat = 1) -> CGFloat {
        min(max(v, lo), hi)
    }
}

// MARK: - FaceDetector (카메라 + Vision, 백그라운드 큐에서 동작)

/// 프로젝트가 기본 MainActor 격리(SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor)라서
/// `nonisolated`를 명시해야 한다. 카메라 델리게이트가 videoQueue에서 불리기 때문.
nonisolated final class FaceDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// 프레임마다 videoQueue에서 호출. 가장 큰 얼굴의 boundingBox(Vision 정규화 좌표) 또는 nil.
    var onResult: (@Sendable (CGRect?) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pet.eyes.session")
    private let videoQueue = DispatchQueue(label: "pet.eyes.video")
    private let request = VNDetectFaceRectanglesRequest()
    private let handler = VNSequenceRequestHandler()
    private var orientation: CGImagePropertyOrientation = .leftMirrored
    private var configured = false
    /// 얼굴 위치만 필요하니 20fps면 충분 (발열·배터리)
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
            try handler.perform([request], on: pixelBuffer, orientation: orientation)
        } catch {
            return
        }
        // 여러 명이면 가장 큰 얼굴(= 가장 가까운 사람)을 본다
        let face = request.results?.max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        onResult?(face?.boundingBox)
    }
}
