# PetEyes

폰을 IoT 기기(펫의 몸)에 꽂으면 화면에 펫의 두 눈이 뜬다. 전면 카메라로 사용자 얼굴을 추적해서 눈동자가 사용자를 쳐다보듯 따라가고, 사용자가 손가락으로 어딘가를 가리키면 그쪽을 본다.

시선 우선순위: **손가락 가리키기 > 얼굴 > 아이들(두리번)**

## 구조

```
전면 카메라(AVCaptureVideoDataOutput, 640×480, 20fps)
  → VisionDetector (videoQueue) : 얼굴(VNDetectFaceRectanglesRequest) + 손 포즈(VNDetectHumanHandPoseRequest)
                                  가장 큰 얼굴 / PointingGesture로 가리키는 손 판정 → DetectionResult
  → GazeTracker (MainActor)     : 가리키기 > 얼굴 순으로 목표점 선택 → gaze(-1...1), 얼굴 폭 → closeness, EMA 스무딩
  → EyesScreen                  : 목표 있으면 tracker.gaze, 없으면 idleGaze / 깜빡임 루프 / scenePhase
  → EyeView ×2                  : gaze만 받아서 레이어별 패럴랙스로 이동 (순수 뷰)
```

| 파일 | 역할 |
|---|---|
| `PetEyes/EyeView.swift` | 눈 하나. `gaze`(화면 기준 오른쪽 +x, 위쪽 +y)와 `size`만 받는다. 소리 방향·감정 표현 확장 시 파라미터만 추가 |
| `PetEyes/VisionDetector.swift` | 카메라 세션 + Vision 요청(얼굴·손). `nonisolated`, 백그라운드 큐 |
| `PetEyes/PointingGesture.swift` | 손 관절 21개에서 "검지로 가리키기" 판정하는 순수 함수. 검지 끝 + 방향 반환 |
| `PetEyes/GazeTracker.swift` | `@MainActor @Observable`. 가리키기/얼굴 우선순위, gaze·closeness 계산, 히스테리시스, 튜닝값 |
| `PetEyes/EyesScreen.swift` | 전체 화면 구성, 아이들/깜빡임 루프, 백그라운드 시 카메라 정지·복귀 시 재개 |
| `PetEyes/PetEyesApp.swift` | 진입점. 상태바·홈 인디케이터 숨김, 화면 자동 꺼짐 방지 |

- 지원 방향: **가로 한 방향(LandscapeRight)** 고정 — 기기에 꽂으면 회전하지 않으므로 Vision orientation 매핑을 안전하게 유지. 반대 방향으로 꽂아야 하면 `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`을 `UIInterfaceOrientationLandscapeLeft`로 바꾸면 된다 (`GazeTracker.updateOrientation()`이 방향별 매핑을 처리).
- 시뮬레이터에는 카메라가 없어서 아이들 모드(두리번 + 깜빡임)만 동작한다. 얼굴 추적은 실기기에서 확인.

## 손가락 가리키기 판정 (`PointingGesture`)

손목 기준 거리 비율로 판정한다 (`ratio = 손가락 끝↔손목 / PIP↔손목`):

- 검지 `ratio ≥ 1.15` → 펴짐
- 중지·약지·새끼 `ratio ≤ 1.0` → 굽힘
- 엄지는 무시
- 검지 2D 길이가 손바닥 길이의 0.5배 미만이면 카메라 축 방향(펫 쪽/반대쪽)을 가리키는 것 → 방향 신뢰 불가로 무시
- 관절 신뢰도 0.4 미만은 없는 것으로 취급

시선 목표 = `검지 끝 + 방향 × pointReach`. 3프레임 연속 인식되면 진입, 8프레임 놓치면 이탈.

## 실기기 튜닝 체크리스트 (`GazeTracker`)

실기기에 붙여보고 아래 값을 조정한다. 전부 `GazeTracker`의 `var`라 인스턴스 생성 후 바로 바꿀 수 있다.

| 값 | 기본 | 조정 기준 |
|---|---|---|
| `invertX` | `false` | 사용자가 **오른쪽**으로 갔는데 눈이 **왼쪽**을 보면 `true` |
| `cameraOffset` | `(-0.065, 0)` m | 카메라 렌즈 ↔ 화면 중심 거리(사용자 기준 오른쪽 +x, 위쪽 +y). 가로 거치 시 카메라가 왼쪽 끝이라 -6.5cm. **반대로 꽂으면 +0.065**. 실제 거치대에서 자로 재서 넣을 것 |
| `faceWidthMeters` | `0.15` | 얼굴 실제 폭. 거리 추정 기준. 아이가 주 사용자면 0.12 정도 |
| `bias` | `(0, 0)` | `cameraOffset`으로도 남는 치우침을 손으로 잡는 상수 (-1...1 단위) |
| `gain` | `1.8` | 조금만 움직여도 끝까지 가면 ↓, 덜 따라오면 ↑ |
| `smoothing` | `0.35` | 떨리면 ↓, 느리면 ↑ |
| `closenessRange` | `0.12...0.32` | 얼굴 박스 폭(0...1) 기준. HUD의 `width` 값을 보고: 팔 길이 거리의 width ≈ 하한, 가장 가까운 거리의 width ≈ 상한 |
| `convergeStrength` (`EyesScreen`) | `0.6` | closeness 1일 때 동공이 안쪽으로 가는 양. 몰림이 약하면 ↑ |
| `missedFrameLimit` | `8` | 20fps 기준 약 0.4초. 잠깐 놓쳐도 아이들로 안 빠지게 하려면 ↑ (얼굴·가리키기 공통) |
| `pointReach` | `0.35` | 가리킬 때 손가락 방향으로 얼마나 멀리 볼지 (프레임 폭 단위). 손 위치만 따라오면 ↑, 너무 끝으로 튀면 ↓ |
| `PointingGesture.indexExtendedRatio` | `1.15` | 검지를 폈는데 인식 안 되면 ↓ |
| `PointingGesture.curledRatio` | `1.0` | 손을 펴고 있는데도 가리키기로 오인하면 ↓ |
| `PointingGesture.minDirectionRatio` | `0.5` | 비스듬히 가리켜도 무시되면 ↓ |

**디버그 HUD**: 화면을 3번 탭하면 좌상단에 `mode(idle/face/pointing) / gaze / 검지 끝·방향 / width → closeness → converge / 현재 튜닝값`이 표시된다. 다시 3번 탭하면 사라짐.

확인 순서:

1. **상하좌우 방향** — 좌/우/위/아래로 움직여 눈이 같은 방향을 보는지. 좌우가 뒤집히면 `invertX`, 상하가 뒤집히면 `updateOrientation()`의 `.upMirrored`/`.downMirrored` 매핑 확인. (`invertX`는 시차 보정보다 먼저 적용되므로 방향을 먼저 맞출 것)
2. **정면 치우침** — 카메라 정면에 섰을 때 시선이 쏠리면 `bias`
3. **감도** — `gain`, 떨림은 `smoothing`
4. **가까이 갔을 때 모임** — HUD로 `width`를 보면서 `closenessRange`를 실제 거리 범위에 맞춤. 양은 `convergeStrength`
5. **여러 명** — 가장 가까운(큰) 얼굴을 보는지
5-1. **가리키기** — 검지로 좌/우/위/아래를 가리키면 HUD `mode`가 `pointing`으로 바뀌고 눈이 그쪽을 보는지. 손을 펴거나 주먹을 쥐면 `face`로 돌아오는지. 펫 쪽을 똑바로 가리키면 무시(`face`)되는지
5-2. **우선순위** — 얼굴이 보이는 상태에서 가리키면 가리키는 쪽을 먼저 보는지
6. **백그라운드/복귀** — 홈으로 나갔다 오면 카메라가 다시 켜지는지
7. **발열** — 오래 켜두고 온도 확인. 손 포즈 검출이 얼굴보다 무거우니 특히 확인. 심하면 `VisionDetector.fps`를 15로

`EyesScreen`의 연출 상수: 몰림 `closeness × 0.6`, 아이들 1~3초 / x ±0.8, y ±0.5, 깜빡임 2.5~6초.
`EyeView`의 패럴랙스: 눈 전체 `0.10d`, 홍채 `+0.07d`, 반사광 `-0.06p`, 원근 `1 − 0.08|g|`.
