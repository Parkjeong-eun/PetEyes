# 핸드오프: AI 펫 눈 — 얼굴 트래킹으로 사용자를 쳐다보는 눈 (iOS)

> Claude Code에게: 이 문서는 구현 브리프다. 아래 **레퍼런스 코드는 아직 한 번도 빌드된 적 없는 초안**이니 그대로 복붙하지 말고, 현재 Xcode 프로젝트 구조·Swift 버전·동시성 설정에 맞춰 옮기고 빌드로 검증해줘.

---

## 1. 목표

폰을 IoT 기기(펫의 몸)에 꽂으면 화면에 펫의 두 눈이 뜬다. 전면 카메라로 사용자 얼굴을 추적해서 **눈동자가 사용자를 쳐다보듯 따라간다.**

- 레퍼런스 이미지: `reference/pet-eyes.png` (검은 배경, 가로 화면에 눈 2개)
- 타깃: 1인 가구 사용자, 기기에 폰을 꽂아두고 오래 켜두는 상황

## 2. 완료 조건

- [ ] 레퍼런스 이미지와 같은 눈 2개가 검은 전체 화면에 표시됨 (상태바·홈 인디케이터 숨김)
- [ ] 사용자가 좌/우/위/아래로 움직이면 눈이 그쪽을 봄 (방향이 뒤집히지 않음)
- [ ] 얼굴이 가까워지면 두 눈이 안쪽으로 살짝 모임
- [ ] 얼굴이 없으면 혼자 두리번거림, 항상 불규칙하게 깜빡임
- [ ] 여러 명이면 가장 가까운(가장 큰) 얼굴을 봄
- [ ] 화면 자동 꺼짐 방지, 백그라운드 가면 카메라 정지 / 복귀 시 재개
- [ ] 떨림 없이 부드럽게 따라감 (스무딩 + 스프링)
- [ ] 발열 고려: 저해상도(640×480) + 20fps 제한

## 3. 기술 결정과 근거

| 결정 | 선택 | 근거 |
|---|---|---|
| 얼굴 추적 | **Vision `VNDetectFaceRectanglesRequest` + AVCaptureSession** | 전 기종 지원, 방 안 먼 거리에서도 검출, 가벼움. ARKit 얼굴 추적은 TrueDepth/A12+ 필요·근거리 최적화·발열 큼 |
| 렌더링 | **SwiftUI 레이어 (Circle/Ellipse + Gradient)** | 이미지 에셋 없이 해상도 독립, 레이어별 offset으로 입체감 연출 쉬움 |
| 상태 | `@Observable` `FaceTracker` (MainActor) + 백그라운드 큐 `FaceDetector` | 카메라/Vision은 백그라운드, UI 값만 메인에서 갱신 |
| 화면 방향 | **가로 한 방향으로 고정 권장** | 기기에 꽂으면 회전 안 함. 방향 따라 Vision orientation이 달라져서 고정이 안전 |

## 4. 아키텍처

```
전면 카메라(AVCaptureVideoDataOutput, 20fps)
  → FaceDetector (videoQueue) : VNSequenceRequestHandler로 얼굴 박스 검출, 가장 큰 얼굴 선택
  → FaceTracker (MainActor)   : 박스 중심 → gaze(-1...1), 박스 폭 → closeness(0...1), EMA 스무딩
  → EyesScreen                : 얼굴 있으면 tracker.gaze, 없으면 idleGaze / 깜빡임 루프
  → EyeView ×2                : gaze만 받아서 레이어별로 이동
```

좌표 규칙: `gaze`는 **화면 기준 오른쪽 +x, 위쪽 +y**, 범위 -1...1. SwiftUI offset에 넣을 때 y 부호 반전.

## 5. 디자인 스펙 (레퍼런스 이미지에서 추출)

`d` = 흰자 지름, `p` = 동공(남색) 지름 = `0.81d`

| 요소 | 크기 | 색 |
|---|---|---|
| 흰자 | d | `#EDEDED`, 외곽선 `#555555` (d×0.006) |
| 홍채 링(청록) | 0.90d | 세로 그라데이션 `#5B8E9A` → `#63BFAF` |
| 동공(남색) | 0.81d | 세로 그라데이션 `#13070F` → `#1B1D50` → `#2C3698` |
| 큰 흰 반사광 | 0.33p × 0.27p, 30° 회전, 약한 블러 | 흰색, 중심 (+0.22p, −0.25p) |
| 작은 흰 점 | 0.058p | 흰색, 중심 (+0.055p, −0.145p) |
| 반투명 반사들 | 타원 0.21p×0.25p @(−0.37p, −0.02p) / 원 0.08p @(−0.375p, +0.18p), (+0.27p, −0.02p), (−0.07p, +0.43p) / 캡슐 0.17p×0.07p −25° @(+0.12p, +0.42p) | 흰색 22% |

(좌표는 동공 중심 기준, SwiftUI 방향: 아래가 +y)

## 6. "쳐다보는 느낌" 연출 규칙 (중요)

1. **레이어 패럴랙스** — 이동량을 층마다 다르게
   - 눈 전체: `gaze × 0.10d`
   - 홍채+동공: 추가로 `gaze × 0.07d`, 흰자 원 밖으로 나가면 clip
   - 반사광: 홍채 기준 **반대로** `gaze × 0.06p` → 화면상 거의 제자리 (광원은 안 움직이니까)
2. **원근 찌그러짐** — 홍채 `scaleEffect(x: 1 − 0.08|gx|, y: 1 − 0.08|gy|)`
3. **몰린 눈** — `converge = closeness × 0.35`, 왼쪽 눈 `gx + converge`, 오른쪽 눈 `gx − converge`
4. **움직임** — 트래커 EMA(`smoothing 0.35`) + 뷰에서 `.interpolatingSpring(stiffness: 180, damping: 20)`
5. **아이들** — 얼굴 없음(약 8프레임 연속 미검출) 시 1~3초마다 정면 또는 랜덤 방향 (x ±0.8, y ±0.5)
6. **깜빡임** — 2.5~6초마다 `scaleEffect(y: 0.06)` 60ms 닫고 100ms 열기

## 7. 구현 순서

1. 프로젝트 확인: Xcode/Swift 버전, `SWIFT_DEFAULT_ACTOR_ISOLATION`, Swift 6 모드 여부, 기존 `@main` 존재 여부
2. Info.plist `NSCameraUsageDescription` 추가 / 지원 방향을 가로 1개로 제한
3. `EyeView` 먼저 구현 → `#Preview`로 레퍼런스 이미지와 비교 (gaze 0,0일 때 이미지와 최대한 같게)
4. `FaceDetector` / `FaceTracker` 구현
5. `EyesScreen` 연결 (idle, blink, scenePhase)
6. `xcodebuild`로 빌드 에러 0 확인
7. 실기기 테스트는 사람이 한다 → 아래 튜닝 체크리스트를 README나 PR 설명에 남길 것

## 8. 알려진 리스크 — 반드시 확인

- **빌드 미검증**: 레퍼런스 코드는 Linux에서 작성돼 컴파일된 적 없음
- **`nonisolated final class`**: Swift 6.2(Xcode 26) 문법. 그 이전이면 `nonisolated` 제거. 프로젝트가 기본 MainActor 격리면 `FaceDetector`가 MainActor로 추론되지 않게 반드시 처리 (카메라 델리게이트가 백그라운드 큐에서 불리므로 크래시 위험)
- **Vision orientation 매핑** (전면 카메라, interface orientation 기준): portrait `.leftMirrored` / upsideDown `.rightMirrored` / landscapeLeft `.upMirrored` / landscapeRight `.downMirrored`. Apple 샘플 "Tracking the User's Face in Real Time" 기준이지만 실기기에서 좌우·상하 확인 필요 → 뒤집히면 `invertX`로 보정
- **`effectiveGeometry`**: iOS 16+. 최소 타깃 확인 (`@Observable`, `onChange` 2-파라미터 버전은 iOS 17+)
- **프레임레이트 설정**: `activeVideoMin/MaxFrameDuration`은 지원 범위 밖이면 예외 → 범위 체크 후 설정
- **`@main` 충돌**: 기존 앱 진입점이 있으면 `PetEyesApp` 제거하고 `EyesScreen`만 붙이기

## 9. 실기기 튜닝 체크리스트 (`FaceTracker`)

| 값 | 기본 | 조정 기준 |
|---|---|---|
| `invertX` | false | 사용자가 오른쪽으로 갔는데 눈이 왼쪽 보면 true |
| `bias` | (0, 0) | 가로 모드에선 카메라가 화면 한쪽 끝 → 정면에 서도 시선이 쏠리면 보정 |
| `gain` | 1.8 | 조금만 움직여도 끝까지 가면 ↓, 덜 따라오면 ↑ |
| `smoothing` | 0.35 | 떨리면 ↓, 느리면 ↑ |
| closeness 기준 | 박스 폭 0.15~0.5 | 실제 거리 보고 조정 |

## 10. 확장 예정 (지금 구현 X, 구조만 열어두기)

- 사용자가 **말하는 쪽으로 고개(시선)를 돌리는 기능**과 합칠 예정 → 소리 방향도 같은 `gaze` 입력으로 넣을 수 있게 `EyeView`는 gaze만 받는 순수 뷰로 유지
- 감정 표현(눈 모양 변화)이 붙을 수 있으니 `EyeView` 파라미터 추가가 쉬운 구조로

---

## 부록: 레퍼런스 코드 (초안, 미빌드)


### `FaceTracker.swift`

```swift
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

    // MARK: 튜닝 값 — 실제 기기에 붙여보고 조정
    /// 카메라 화각 대비 눈 움직임 증폭. 클수록 조금만 움직여도 끝까지 봄
    var gain: CGFloat = 1.8
    /// 카메라가 화면 정중앙에 있지 않아서 생기는 치우침 보정 (-1...1 단위)
    var bias = CGPoint(x: 0, y: 0)
    /// 사용자가 오른쪽으로 갔는데 눈이 왼쪽을 보면 true
    var invertX = false
    /// 0...1, 클수록 즉각 반응(대신 떨림 증가)
    var smoothing: CGFloat = 0.35

    private let detector = FaceDetector()
    private var missedFrames = 0

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }
        detector.onResult = { [weak self] box in
            Task { @MainActor in self?.handle(box) }
        }
        updateOrientation()
        detector.start()
    }

    func resume() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        updateOrientation()
        detector.start()
    }

    func stop() { detector.stop() }

    /// 화면 방향이 바뀌면 호출. Vision에 "이 버퍼가 어느 쪽이 위인지" 알려줘야 좌표가 맞음
    func updateOrientation() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let interface = scene?.effectiveGeometry.interfaceOrientation ?? .portrait
        // 전면 카메라 기준. *Mirrored → 셀카 화면처럼 좌우가 뒤집힌 좌표가 나와서
        // "사용자가 오른쪽으로 가면 x도 +"가 된다.
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
            if missedFrames > 8 {          // 20fps 기준 약 0.4초 동안 못 찾으면 '없음'
                hasFace = false
                closeness = 0
            }
            return
        }
        missedFrames = 0
        hasFace = true

        // Vision 좌표: 0...1, 원점은 좌하단
        var x = (box.midX - 0.5) * 2 + bias.x
        let y = (box.midY - 0.5) * 2 + bias.y
        if invertX { x = -x }

        let target = CGPoint(x: clamp(x * gain), y: clamp(y * gain))
        gaze = CGPoint(x: gaze.x + (target.x - gaze.x) * smoothing,
                       y: gaze.y + (target.y - gaze.y) * smoothing)

        // 얼굴 박스 폭으로 거리 근사 (0.15 이하 → 멀다, 0.5 이상 → 아주 가깝다). 기기 보고 조정
        let near = clamp((box.width - 0.15) / 0.35, 0, 1)
        closeness += (near - closeness) * smoothing
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat = -1, _ hi: CGFloat = 1) -> CGFloat {
        min(max(v, lo), hi)
    }
}

// MARK: - FaceDetector (카메라 + Vision, 백그라운드 큐에서 동작)

/// Xcode 26(Swift 6.2) 기준. 이전 Xcode라면 `nonisolated` 키워드를 지우면 된다.
nonisolated final class FaceDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onResult: (@Sendable (CGRect?) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pet.eyes.session")
    private let videoQueue = DispatchQueue(label: "pet.eyes.video")
    private let request = VNDetectFaceRectanglesRequest()
    private let handler = VNSequenceRequestHandler()
    private var orientation: CGImagePropertyOrientation = .leftMirrored
    private var configured = false
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

        // 프레임레이트 제한 (지원 범위일 때만)
        let supported = device.activeFormat.videoSupportedFrameRateRanges
            .contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        if supported, (try? device.lockForConfiguration()) != nil {
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
            device.unlockForConfiguration()
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
```

### `EyeView.swift`

```swift
import SwiftUI

/// 눈 하나. gaze(-1...1)만 넣으면 그쪽을 쳐다본다.
///
/// "쳐다보는 느낌"은 레이어마다 움직이는 양을 다르게 줘서 만든다.
///  1) 눈 전체      : 조금 이동  (머리 안에서 안구가 도는 느낌)
///  2) 홍채 + 동공  : 더 많이 이동 + 진행 방향으로 살짝 납작해짐 (구체가 회전하는 원근감)
///  3) 반사광       : 거의 제자리 (광원은 안 움직이니까) → 입체감이 확 산다
struct EyeView: View {
    var gaze: CGPoint
    var size: CGFloat = 160

    var body: some View {
        let d = size
        let gx = gaze.x
        let gy = -gaze.y              // SwiftUI는 아래쪽이 +y

        ZStack {
            // 1) 흰자
            Circle()
                .fill(Color(hex: 0xEDEDED))
                .overlay(Circle().stroke(Color(hex: 0x555555), lineWidth: d * 0.006))

            // 2) 홍채 + 동공 — 흰자 밖으로 나가는 부분은 잘림
            iris(d: d, gx: gx, gy: gy)
                .scaleEffect(x: 1 - 0.08 * abs(gx), y: 1 - 0.08 * abs(gy))
                .offset(x: gx * d * 0.07, y: gy * d * 0.07)
                .frame(width: d, height: d)
                .clipShape(Circle())
        }
        .frame(width: d, height: d)
        .offset(x: gx * d * 0.10, y: gy * d * 0.10)
    }

    private func iris(d: CGFloat, gx: CGFloat, gy: CGFloat) -> some View {
        let ring = d * 0.90
        let p = d * 0.81              // 동공(남색) 지름

        return ZStack {
            // 청록 링
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0x5B8E9A), Color(hex: 0x63BFAF)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: ring, height: ring)

            // 남색 동공
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0x13070F), Color(hex: 0x1B1D50), Color(hex: 0x2C3698)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: p, height: p)

            // 3) 반사광 — 홍채와 반대로 조금 밀어서 '제자리에 있는 것처럼' 보이게
            highlights(p: p)
                .offset(x: -gx * p * 0.06, y: -gy * p * 0.06)
                .frame(width: p, height: p)
                .clipShape(Circle())
        }
        .frame(width: ring, height: ring)
    }

    /// 원본 이미지에서 위치·크기를 동공 지름 비율로 옮긴 값
    private func highlights(p: CGFloat) -> some View {
        let soft = Color.white.opacity(0.22)

        return ZStack {
            // 큰 흰 반사광 (오른쪽 위)
            Ellipse()
                .fill(.white)
                .frame(width: p * 0.33, height: p * 0.27)
                .rotationEffect(.degrees(30))
                .blur(radius: p * 0.012)
                .offset(x: p * 0.22, y: -p * 0.25)

            // 작은 흰 점
            Circle()
                .fill(.white)
                .frame(width: p * 0.058, height: p * 0.058)
                .blur(radius: p * 0.004)
                .offset(x: p * 0.055, y: -p * 0.145)

            // 반투명 보조 반사들
            Ellipse().fill(soft)
                .frame(width: p * 0.21, height: p * 0.25)
                .offset(x: -p * 0.37, y: -p * 0.02)
            Circle().fill(soft)
                .frame(width: p * 0.08, height: p * 0.08)
                .offset(x: -p * 0.375, y: p * 0.18)
            Circle().fill(soft)
                .frame(width: p * 0.08, height: p * 0.08)
                .offset(x: p * 0.27, y: -p * 0.02)
            Circle().fill(soft)
                .frame(width: p * 0.08, height: p * 0.08)
                .offset(x: -p * 0.07, y: p * 0.43)
            Capsule().fill(soft)
                .frame(width: p * 0.17, height: p * 0.07)
                .rotationEffect(.degrees(-25))
                .offset(x: p * 0.12, y: p * 0.42)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

#Preview {
    HStack(spacing: 40) {
        EyeView(gaze: CGPoint(x: -0.8, y: 0.3))
        EyeView(gaze: CGPoint(x: 0.8, y: -0.5))
    }
    .padding(40)
    .background(.black)
}
```

### `EyesScreen.swift`

```swift
import SwiftUI

@main
struct PetEyesApp: App {
    var body: some Scene {
        WindowGroup {
            EyesScreen()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }   // 화면 안 꺼지게
        }
    }
}

struct EyesScreen: View {
    @State private var tracker = FaceTracker()
    @State private var idleGaze: CGPoint = .zero
    @State private var blink = false
    @Environment(\.scenePhase) private var scenePhase

    /// 얼굴이 보이면 얼굴을, 안 보이면 혼자 두리번
    private var gaze: CGPoint { tracker.hasFace ? tracker.gaze : idleGaze }

    var body: some View {
        GeometryReader { geo in
            let eyeSize = min(geo.size.width * 0.34, geo.size.height * 0.8)
            // 가까이 오면 두 눈이 안쪽으로 모임 → "나를 보고 있다" 느낌이 강해짐
            let converge = tracker.hasFace ? tracker.closeness * 0.35 : 0

            HStack(spacing: eyeSize * 0.22) {
                EyeView(gaze: CGPoint(x: gaze.x + converge, y: gaze.y), size: eyeSize)
                EyeView(gaze: CGPoint(x: gaze.x - converge, y: gaze.y), size: eyeSize)
            }
            .animation(.interpolatingSpring(stiffness: 180, damping: 20), value: gaze)
            .scaleEffect(x: 1, y: blink ? 0.06 : 1)
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: geo.size) { tracker.updateOrientation() }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .task { await tracker.start() }
        .task { await idleLoop() }
        .task { await blinkLoop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { tracker.resume() }
            if phase == .background { tracker.stop() }
        }
    }

    private func idleLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 1.0...3.0)))
            guard !tracker.hasFace else { continue }
            idleGaze = Bool.random()
                ? .zero
                : CGPoint(x: .random(in: -0.8...0.8), y: .random(in: -0.5...0.5))
        }
    }

    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.5...6.0)))
            withAnimation(.easeIn(duration: 0.06)) { blink = true }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeOut(duration: 0.10)) { blink = false }
        }
    }
}
```
