//
//  GazeTracker.swift
//  PetEyes
//

import AVFoundation
import UIKit
import Observation

/// 전면 카메라에서 얻은 얼굴·손 정보를 "눈이 볼 방향"으로 바꿔준다.
///
/// 우선순위: 손가락 가리키기 > 얼굴 > (없음 → 뷰가 아이들 처리)
@MainActor
@Observable
final class GazeTracker {
    enum Mode: String { case idle, face, pointing }

    /// 눈동자가 볼 방향. -1...1 (화면 기준 오른쪽 +x, 위쪽 +y)
    private(set) var gaze: CGPoint = .zero
    /// 0...1, 얼굴이 가까울수록 1 (가운데로 몰린 눈 연출용)
    private(set) var closeness: CGFloat = 0
    private(set) var hasFace = false
    private(set) var isPointing = false
    /// 마지막으로 검출된 얼굴 박스 폭(0...1, Vision 정규화). closenessRange 튜닝용 원시값
    private(set) var faceWidth: CGFloat = 0
    /// 마지막으로 인식한 가리키기 (HUD용)
    private(set) var lastPointing: Pointing?

    /// 지금 시선을 결정하는 입력
    var mode: Mode { isPointing ? .pointing : hasFace ? .face : .idle }
    /// 볼 대상이 있는가 (없으면 뷰가 아이들 시선을 쓴다)
    var hasTarget: Bool { isPointing || hasFace }

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
    /// 가리키기: 검지 끝에서 방향으로 얼마나 뻗은 지점을 볼지 (프레임 폭 단위).
    /// 클수록 손가락 방향에 가깝게, 작을수록 손 위치에 가깝게 본다
    var pointReach: CGFloat = 0.35

    /// 20fps 기준 약 0.4초 동안 못 찾으면 '없음'으로 판정
    private let missedFrameLimit = 8
    /// 가리키기는 이만큼 연속으로 잡혀야 진입 (한 프레임 오검출로 튀지 않게)
    private let pointingEnterFrames = 3

    private let detector = VisionDetector()
    private var faceMissed = 0
    private var pointingSeen = 0
    private var pointingMissed = 0

    /// 카메라 권한을 요청하고 추적을 시작한다. 거부되면 아무것도 하지 않는다 (아이들 애니메이션만 동작).
    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        detector.onResult = { [weak self] result in
            guard let self else { return }
            Task { @MainActor in self.handle(result) }
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

    // MARK: - 프레임 처리

    private func handle(_ result: DetectionResult) {
        updateFace(result.face)
        updatePointing(result.pointing)

        // 우선순위: 가리키기 > 얼굴. 둘 다 없으면 gaze는 마지막 값 유지 (뷰가 아이들로 전환)
        let targetPoint: CGPoint?
        if isPointing, let p = lastPointing {
            // 손가락이 가리키는 지점 = 검지 끝에서 방향으로 pointReach만큼 뻗은 곳
            targetPoint = CGPoint(x: p.tip.x + p.direction.dx * pointReach,
                                  y: p.tip.y + p.direction.dy * pointReach)
        } else if hasFace, let box = result.face {
            targetPoint = CGPoint(x: box.midX, y: box.midY)
        } else {
            targetPoint = nil
        }

        if let targetPoint {
            let target = mapToGaze(targetPoint)
            gaze = CGPoint(x: gaze.x + (target.x - gaze.x) * smoothing,
                           y: gaze.y + (target.y - gaze.y) * smoothing)
        }
    }

    private func updateFace(_ box: CGRect?) {
        guard let box else {
            faceMissed += 1
            if faceMissed > missedFrameLimit {
                hasFace = false
                closeness = 0
                faceWidth = 0
            }
            return
        }
        faceMissed = 0
        hasFace = true
        faceWidth = box.width

        // 얼굴 박스 폭으로 거리 근사
        let span = closenessRange.upperBound - closenessRange.lowerBound
        let near = clamp((box.width - closenessRange.lowerBound) / span, 0, 1)
        closeness += (near - closeness) * smoothing
    }

    private func updatePointing(_ pointing: Pointing?) {
        if let pointing {
            lastPointing = pointing
            pointingMissed = 0
            pointingSeen += 1
            if pointingSeen >= pointingEnterFrames { isPointing = true }
        } else {
            pointingMissed += 1
            if pointingMissed > missedFrameLimit {
                isPointing = false
                pointingSeen = 0
                lastPointing = nil
            }
        }
    }

    /// Vision 정규화 좌표(0...1, 원점 좌하단) → gaze(-1...1). 얼굴·손 공통.
    private func mapToGaze(_ p: CGPoint) -> CGPoint {
        var x = (p.x - 0.5) * 2 + bias.x
        let y = (p.y - 0.5) * 2 + bias.y
        if invertX { x = -x }
        return CGPoint(x: clamp(x * gain), y: clamp(y * gain))
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat = -1, _ hi: CGFloat = 1) -> CGFloat {
        min(max(v, lo), hi)
    }
}
