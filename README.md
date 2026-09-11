# PetEyes

폰을 IoT 기기(펫의 몸)에 꽂으면 화면에 펫의 두 눈이 뜬다. 전면 카메라로 사용자 얼굴을 추적해서 눈동자가 사용자를 쳐다보듯 따라간다.

## 구조

```
전면 카메라(AVCaptureVideoDataOutput, 640×480, 20fps)
  → FaceDetector (videoQueue) : Vision VNDetectFaceRectanglesRequest, 가장 큰 얼굴 선택
  → FaceTracker (MainActor)   : 박스 중심 → gaze(-1...1), 박스 폭 → closeness(0...1), EMA 스무딩
  → EyesScreen                : 얼굴 있으면 tracker.gaze, 없으면 idleGaze / 깜빡임 루프 / scenePhase
  → EyeView ×2                : gaze만 받아서 레이어별 패럴랙스로 이동 (순수 뷰)
```

| 파일 | 역할 |
|---|---|
| `PetEyes/EyeView.swift` | 눈 하나. `gaze`(화면 기준 오른쪽 +x, 위쪽 +y)와 `size`만 받는다. 소리 방향·감정 표현 확장 시 파라미터만 추가 |
| `PetEyes/FaceTracker.swift` | `FaceTracker`(@MainActor @Observable) + `FaceDetector`(nonisolated, 카메라/Vision) |
| `PetEyes/EyesScreen.swift` | 전체 화면 구성, 아이들/깜빡임 루프, 백그라운드 시 카메라 정지·복귀 시 재개 |
| `PetEyes/PetEyesApp.swift` | 진입점. 상태바·홈 인디케이터 숨김, 화면 자동 꺼짐 방지 |

- 지원 방향: **가로 한 방향(LandscapeRight)** 고정 — 기기에 꽂으면 회전하지 않으므로 Vision orientation 매핑을 안전하게 유지. 반대 방향으로 꽂아야 하면 `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`을 `UIInterfaceOrientationLandscapeLeft`로 바꾸면 된다 (`FaceTracker.updateOrientation()`이 방향별 매핑을 처리).
- 시뮬레이터에는 카메라가 없어서 아이들 모드(두리번 + 깜빡임)만 동작한다. 얼굴 추적은 실기기에서 확인.

## 실기기 튜닝 체크리스트 (`FaceTracker`)

실기기에 붙여보고 아래 값을 조정한다. 전부 `FaceTracker`의 `var`라 인스턴스 생성 후 바로 바꿀 수 있다.

| 값 | 기본 | 조정 기준 |
|---|---|---|
| `invertX` | `false` | 사용자가 **오른쪽**으로 갔는데 눈이 **왼쪽**을 보면 `true` |
| `bias` | `(0, 0)` | 가로 모드에선 카메라가 화면 한쪽 끝에 있음 → 정면에 서도 시선이 한쪽으로 쏠리면 반대 방향으로 보정 (-1...1 단위) |
| `gain` | `1.8` | 조금만 움직여도 끝까지 가면 ↓, 덜 따라오면 ↑ |
| `smoothing` | `0.35` | 떨리면 ↓, 느리면 ↑ |
| `closenessRange` | `0.12...0.32` | 얼굴 박스 폭(0...1) 기준. HUD의 `width` 값을 보고: 팔 길이 거리의 width ≈ 하한, 가장 가까운 거리의 width ≈ 상한 |
| `convergeStrength` (`EyesScreen`) | `0.6` | closeness 1일 때 동공이 안쪽으로 가는 양. 몰림이 약하면 ↑ |
| `missedFrameLimit` | `8` | 20fps 기준 약 0.4초. 잠깐 놓쳐도 아이들로 안 빠지게 하려면 ↑ |

**디버그 HUD**: 화면을 3번 탭하면 좌상단에 `face / gaze / width → closeness → converge / 현재 튜닝값`이 표시된다. 다시 3번 탭하면 사라짐.

확인 순서:

1. **상하좌우 방향** — 좌/우/위/아래로 움직여 눈이 같은 방향을 보는지. 좌우가 뒤집히면 `invertX`, 상하가 뒤집히면 `updateOrientation()`의 `.upMirrored`/`.downMirrored` 매핑 확인
2. **정면 치우침** — 카메라 정면에 섰을 때 시선이 쏠리면 `bias`
3. **감도** — `gain`, 떨림은 `smoothing`
4. **가까이 갔을 때 모임** — HUD로 `width`를 보면서 `closenessRange`를 실제 거리 범위에 맞춤. 양은 `convergeStrength`
5. **여러 명** — 가장 가까운(큰) 얼굴을 보는지
6. **백그라운드/복귀** — 홈으로 나갔다 오면 카메라가 다시 켜지는지
7. **발열** — 오래 켜두고 온도 확인. 심하면 `FaceDetector.fps`를 15로

`EyesScreen`의 연출 상수: 몰림 `closeness × 0.6`, 아이들 1~3초 / x ±0.8, y ±0.5, 깜빡임 2.5~6초.
`EyeView`의 패럴랙스: 눈 전체 `0.10d`, 홍채 `+0.07d`, 반사광 `-0.06p`, 원근 `1 − 0.08|g|`.
