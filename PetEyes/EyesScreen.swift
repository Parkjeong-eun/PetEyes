//
//  EyesScreen.swift
//  PetEyes
//

import SwiftUI

/// 검은 전체 화면에 눈 두 개. 손가락이 가리키는 곳 > 얼굴 순으로 쳐다보고, 둘 다 없으면 혼자 두리번거리며, 항상 불규칙하게 깜빡인다.
struct EyesScreen: View {
    @State private var tracker = GazeTracker()
    @State private var idleGaze: CGPoint = .zero
    @State private var blink = false
    @State private var showDebug = false
    @Environment(\.scenePhase) private var scenePhase

    /// 얼굴이 가장 가까울 때(closeness 1) 각 눈의 동공이 안쪽으로 이동하는 gaze 단위량
    private let convergeStrength: CGFloat = 0.6

    /// 볼 대상(가리키기 또는 얼굴)이 있으면 그쪽을, 없으면 혼자 두리번
    private var gaze: CGPoint { tracker.hasTarget ? tracker.gaze : idleGaze }

    /// 가까이 오면 두 눈이 안쪽으로 모임 → "나를 보고 있다" 느낌이 강해짐.
    /// 가리키는 곳을 볼 때는 먼 곳이니 모이지 않는다.
    private var converge: CGFloat { tracker.mode == .face ? tracker.closeness * convergeStrength : 0 }

    private var leftGaze: CGPoint { CGPoint(x: gaze.x + converge, y: gaze.y) }
    private var rightGaze: CGPoint { CGPoint(x: gaze.x - converge, y: gaze.y) }

    private let spring = Animation.interpolatingSpring(stiffness: 180, damping: 20)

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                let eyeSize = min(geo.size.width * 0.34, geo.size.height * 0.8)

                HStack(spacing: eyeSize * 0.22) {
                    EyeView(gaze: leftGaze, size: eyeSize)
                        .animation(spring, value: leftGaze)
                    EyeView(gaze: rightGaze, size: eyeSize)
                        .animation(spring, value: rightGaze)
                }
                .scaleEffect(x: 1, y: blink ? 0.06 : 1)
                .frame(width: geo.size.width, height: geo.size.height)
                .onChange(of: geo.size) { tracker.updateOrientation() }
            }
            .background(Color.black)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(count: 3) { showDebug.toggle() }   // 실기기 튜닝용 HUD 토글

            // 안전 영역 안쪽(노치/다이나믹 아일랜드 피해서)에 표시
            if showDebug { debugHUD }
        }
        .task { await tracker.start() }
        .task { await idleLoop() }
        .task { await blinkLoop() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:     tracker.resume()
            case .background: tracker.stop()
            default:          break
            }
        }
    }

    /// 실기기 튜닝용. README 체크리스트의 invertX / bias / gain / closenessRange를 맞출 때 본다.
    private var debugHUD: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("mode: \(tracker.mode.rawValue)   face \(tracker.hasFace ? "Y" : "-")   pointing \(tracker.isPointing ? "Y" : "-")")
            Text(String(format: "gaze  x %+.2f  y %+.2f", gaze.x, gaze.y))
            if let p = tracker.lastPointing {
                Text(String(format: "finger tip (%.2f, %.2f)  dir (%+.2f, %+.2f)  reach %.2f",
                            p.tip.x, p.tip.y, p.direction.dx, p.direction.dy, tracker.pointReach))
            }
            Text(String(format: "width %.3f  →  closeness %.2f  →  converge %+.2f",
                        tracker.faceWidth, tracker.closeness, converge))
            Text(String(format: "range %.2f…%.2f  gain %.1f  smooth %.2f  invertX %@",
                        tracker.closenessRange.lowerBound, tracker.closenessRange.upperBound,
                        tracker.gain, tracker.smoothing, tracker.invertX ? "on" : "off"))
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.green)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(.top, 8)
        .padding(.leading, 12)
        .allowsHitTesting(false)
    }

    /// 얼굴 없을 때 1~3초마다 정면 또는 랜덤 방향
    private func idleLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 1.0...3.0)))
            guard !tracker.hasTarget else { continue }
            idleGaze = Bool.random()
                ? .zero
                : CGPoint(x: .random(in: -0.8...0.8), y: .random(in: -0.5...0.5))
        }
    }

    /// 2.5~6초마다 60ms 닫고 100ms 열기
    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.5...6.0)))
            withAnimation(.easeIn(duration: 0.06)) { blink = true }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeOut(duration: 0.10)) { blink = false }
        }
    }
}

#Preview(traits: .landscapeLeft) {
    EyesScreen()
}
