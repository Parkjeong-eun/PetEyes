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
    /// 마지막 프레임에 적용된 카메라 시차 보정량 (-1...1 단위, HUD용)
    private(set) var parallaxCorrection: CGPoint = .zero

    /// 지금 시선을 결정하는 입력
    var mode: Mode { isPointing ? .pointing : hasFace ? .face : .idle }
    /// 볼 대상이 있는가 (없으면 뷰가 아이들 시선을 쓴다)
    var hasTarget: Bool { isPointing || hasFace }

    // MARK: 튜닝 값 — 실제 기기에 붙여보고 조정 (README 체크리스트 참고)
    /// 카메라 화각 대비 눈 움직임 증폭. 클수록 조금만 움직여도 끝까지 봄
    var gain: CGFloat = 1.8
    /// 카메라 렌즈가 화면 중심(두 눈 사이)에서 얼마나 떨어져 있는지 — 미터, 사용자가 화면을 볼 때 기준 오른쪽 +x, 위쪽 +y.
    /// 가로 거치 시 카메라는 폰 한쪽 끝에 있어서 화면 중심에서 약 6.5cm 벗어난다.
    /// 사용자가 화면(눈)을 똑바로 봐도 카메라에는 옆에 있는 것처럼 찍히므로, 거리에 비례해 되돌린다.
    /// 카메라가 화면 왼쪽이면 x 음수, 오른쪽이면 양수. 반대로 꽂으면 부호를 바꿀 것.
    var cameraOffset = CGSize(width: -0.065, height: 0)
    /// 성인 얼굴 실제 폭(미터). 얼굴 박스 폭 → 거리 추정에 쓴다
    var faceWidthMeters: CGFloat = 0.15
    /// cameraOffset으로도 남는 치우침을 손으로 잡는 상수 (-1...1 단위). 거치대 구조 등
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
        /// 거리 추정용 "얼굴 폭 상당" 값. 손만 보일 때는 손바닥 길이(≈9.5cm)를 얼굴 폭으로 환산
        let distanceWidth: CGFloat
        if isPointing, let p = lastPointing {
            // 손가락이 가리키는 지점 = 검지 끝에서 방향으로 pointReach만큼 뻗은 곳
            targetPoint = CGPoint(x: p.tip.x + p.direction.dx * pointReach,
                                  y: p.tip.y + p.direction.dy * pointReach)
            distanceWidth = hasFace ? faceWidth : p.palmLength * (faceWidthMeters / 0.095)
        } else if hasFace, let box = result.face {
            targetPoint = CGPoint(x: box.midX, y: box.midY)
            distanceWidth = box.width
        } else {
            targetPoint = nil
            distanceWidth = 0
        }

        if let targetPoint {
            let target = mapToGaze(targetPoint, distanceWidth: distanceWidth)
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
    ///
    /// - Parameter distanceWidth: 대상의 얼굴 폭 상당 값(정규화). 카메라 시차 보정의 크기를 정한다.
    ///
    /// 시차 보정: 카메라가 화면 중심에서 o(m) 떨어져 있으면, 화면 중심을 보는 사용자가
    /// 카메라에는 -o 만큼 옆에 찍힌다. 그 각도는 거리 d에 반비례하고, 얼굴 폭 w(정규화)는
    /// w = W / (2·d·tan(fov/2)) 이므로  보정(-1...1 단위) = o / (d·tan(fov/2)) = 2·o·w / W.
    private func mapToGaze(_ p: CGPoint, distanceWidth: CGFloat) -> CGPoint {
        var x = (p.x - 0.5) * 2
        var y = (p.y - 0.5) * 2
        if invertX { x = -x }

        let k = 2 * distanceWidth / faceWidthMeters
        let correction = CGPoint(x: cameraOffset.width * k, y: cameraOffset.height * k)
        parallaxCorrection = correction
        x += correction.x + bias.x
        y += correction.y + bias.y

        return CGPoint(x: clamp(x * gain), y: clamp(y * gain))
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat = -1, _ hi: CGFloat = 1) -> CGFloat {
        min(max(v, lo), hi)
    }
}
