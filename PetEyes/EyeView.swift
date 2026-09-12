//
//  EyeView.swift
//  PetEyes
//

import SwiftUI

/// 눈 하나. gaze(-1...1)만 넣으면 그쪽을 쳐다본다.
///
/// gaze 좌표 규칙: 화면 기준 오른쪽 +x, 위쪽 +y. (SwiftUI offset은 아래가 +y라 내부에서 반전)
///
/// "쳐다보는 느낌"은 레이어마다 움직이는 양을 다르게 줘서 만든다.
///  1) 눈 전체      : 조금 이동  (머리 안에서 안구가 도는 느낌)
///  2) 홍채 + 동공  : 더 많이 이동 + 진행 방향으로 살짝 납작해짐 (구체가 회전하는 원근감)
///  3) 반사광       : 거의 제자리 (광원은 안 움직이니까) → 입체감이 확 산다
///
/// 소리 방향·감정 표현 등이 붙어도 이 뷰는 입력 파라미터만 늘리는 순수 뷰로 유지한다.
struct EyeView: View {
    var gaze: CGPoint
    var size: CGFloat = 160
    /// 남색 원 안의 진짜 동공 지름 (남색 원 지름 대비). 감정 표현 시 확대/축소용
    var pupilSize: CGFloat = 0.68

    // MARK: 눈꺼풀 (EXPRESSIONS.md 참고)

    /// 위꺼풀이 흰자를 덮는 비율. 0 = 완전히 뜸, 1 = 완전히 감음. 졸림·화남·슬픔·의심 등
    var upperLid: CGFloat = 0
    /// 아래꺼풀이 흰자를 덮는 비율. 0 = 없음, 1 = 완전히 감음. 위쪽 가장자리가 둥글어서 올라올수록 눈웃음(초승달) 모양
    var lowerLid: CGFloat = 0
    /// 위꺼풀 기울기(도). + = 안쪽(코 쪽) 눈꼬리가 내려감(화남 ／＼), − = 바깥쪽이 내려감(슬픔 ＼／)
    var lidTilt: CGFloat = 0
    /// 오른쪽 눈이면 true. lidTilt의 안쪽/바깥쪽 기준을 좌우 대칭으로 맞추기 위해 필요
    var mirrored: Bool = false
    /// 별 반사광이 반짝이는지. 잠들 때처럼 눈이 죽어 보여야 하면 끈다
    var twinkle: Bool = true

    var body: some View {
        let d = size
        let gx = gaze.x
        let gy = -gaze.y              // SwiftUI는 아래쪽이 +y

        ZStack {
            // 1) 흰자 — 가운데가 밝고 가장자리로 갈수록 어두워서 구처럼 보이게
            Circle()
                .fill(RadialGradient(stops: [.init(color: .white, location: 0),
                                             .init(color: Color(hex: 0xF4F1EC), location: 0.7),
                                             .init(color: Color(hex: 0xCFC7BC), location: 1)],
                                     center: UnitPoint(x: 0.45, y: 0.42),
                                     startRadius: 0, endRadius: d * 0.5))
                .overlay(Circle().stroke(Color(hex: 0x3A332C), lineWidth: d * 0.006))

            // 2) 홍채 + 동공 — 흰자 밖으로 나가는 부분은 잘림
            iris(d: d, gx: gx, gy: gy)
                .scaleEffect(x: 1 - 0.08 * abs(gx), y: 1 - 0.08 * abs(gy))
                .offset(x: gx * d * 0.07, y: gy * d * 0.07)
                .frame(width: d, height: d)
                .clipShape(Circle())

            // 3) 눈꺼풀 그림자 + 유리 돔 — 안구 위에 얹힌 것들이라 시선을 따라가지 않음
            ZStack {
                // 위쪽 눈꺼풀이 안구에 드리우는 그림자
                LinearGradient(stops: [.init(color: .black.opacity(0.42), location: 0),
                                       .init(color: .black.opacity(0.12), location: 0.22),
                                       .init(color: .clear, location: 0.45)],
                               startPoint: .top, endPoint: .bottom)
                // 유리 표면에 비친 하늘 — 위쪽에 흐릿하게
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: d * 0.72, height: d * 0.38)
                    .offset(y: -d * 0.24)
                    .blur(radius: d * 0.02)
            }
            .frame(width: d, height: d)
            .clipShape(Circle())

            // 4) 눈꺼풀 — 배경색(검정)으로 흰자를 가려서 표현. 눈 밖으로 나가는 부분은 잘림
            eyelids(d: d)
                .frame(width: d, height: d)
                .clipShape(Circle())
        }
        .frame(width: d, height: d)
        .offset(x: gx * d * 0.10, y: gy * d * 0.10)
    }

    /// 위꺼풀은 직선 가장자리 + 기울기, 아래꺼풀은 둥근 가장자리(원의 윗부분).
    /// 두 꺼풀 모두 눈보다 훨씬 크게 그려서 기울여도 빈틈이 안 생기게 한다.
    private func eyelids(d: CGFloat) -> some View {
        let upper = min(max(upperLid, 0), 1)
        let lower = min(max(lowerLid, 0), 1)
        // SwiftUI 회전은 시계방향이 +. 왼쪽 눈은 오른쪽 끝(안쪽)이 내려가므로 그대로, 오른쪽 눈은 반전
        let tilt = mirrored ? -lidTilt : lidTilt

        return ZStack {
            // 위꺼풀: 아래 가장자리가 눈 세로 중심선에서 (-d/2 + upper*d)에 오도록 두고, 그 점을 축으로 기울임
            Rectangle()
                .fill(.black)
                .frame(width: d * 3, height: d * 2)
                .rotationEffect(.degrees(tilt), anchor: .bottom)
                .offset(y: -d * 1.5 + upper * d)

            // 아래꺼풀: 큰 원의 윗부분이 올라오면서 흰자가 초승달 모양으로 남는다
            Circle()
                .fill(.black)
                .frame(width: d * 1.6, height: d * 1.6)
                .offset(y: d * 1.3 - lower * d)
        }
    }

    private func iris(d: CGFloat, gx: CGFloat, gy: CGFloat) -> some View {
        let ring = d * 0.80           // 홍채 지름
        let p = d * 0.72              // 반사광·동공 크기의 기준 원 지름

        return ZStack {
            // 호박색 홍채 — 중심은 거의 검정, 바깥으로 갈수록 갈색 → 호박색 → 밝은 테두리, 맨 끝은 어두운 각막 가장자리
            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: Color(hex: 0x1A0A02), location: 0.00),
                    .init(color: Color(hex: 0x2E1506), location: 0.55),
                    .init(color: Color(hex: 0x5C2E0A), location: 0.64),
                    .init(color: Color(hex: 0xA5621A), location: 0.74),
                    .init(color: Color(hex: 0xD4923A), location: 0.84),
                    .init(color: Color(hex: 0xE9B85E), location: 0.92),
                    .init(color: Color(hex: 0x8A5320), location: 0.97),
                    .init(color: Color(hex: 0x3A2008), location: 1.00),
                ], center: .center, startRadius: 0, endRadius: ring / 2))
                .frame(width: ring, height: ring)

            // 홍채 섬유 결 — 방사형으로 미세하게 밝기 변화
            Circle()
                .fill(AngularGradient(colors: fiberColors, center: .center))
                .frame(width: ring, height: ring)
                .blendMode(.overlay)
                .opacity(0.25)

            // 위쪽은 눈꺼풀 그림자 때문에 살짝 어둡고, 아래쪽은 빛이 투과해 밝다
            Circle()
                .fill(LinearGradient(colors: [.black.opacity(0.45), .clear, Color(hex: 0xF0B85A).opacity(0.28)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: ring, height: ring)

            // 동공 — 가장자리는 부드럽게, 안쪽에 아주 미세한 밝기 차
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x050201), Color(hex: 0x120702)],
                                     center: .center, startRadius: 0, endRadius: p * pupilSize / 2))
                .frame(width: p * pupilSize, height: p * pupilSize)
                .blur(radius: p * 0.018)

            // 3) 반사광 — 홍채와 반대로 조금 밀어서 '제자리에 있는 것처럼' 보이게
            highlights(p: p)
                .offset(x: -gx * p * 0.06, y: -gy * p * 0.06)
                .frame(width: p, height: p)
                .clipShape(Circle())
        }
        .frame(width: ring, height: ring)
    }

    /// 홍채 결용 — 어두움/밝음이 불규칙하게 번갈아 나오는 각도 그라데이션
    private var fiberColors: [Color] {
        let pattern: [Double] = [0.5, 0.9, 0.3, 0.7, 1.0, 0.4, 0.8, 0.2, 0.6, 0.95, 0.35, 0.75,
                                 0.45, 0.85, 0.25, 0.65, 1.0, 0.5, 0.9, 0.3, 0.7, 0.55, 0.8, 0.5]
        // 두 번 반복해서 결을 더 촘촘하게
        return (pattern + pattern.reversed()).map { Color(white: $0) }
    }

    /// 위치·크기는 동공 기준 원 지름(p) 비율. 좌표는 홍채 중심 기준.
    private func highlights(p: CGFloat) -> some View {
        ZStack {
            // 큰 흰 반사광 (오른쪽 위) — 광원
            Ellipse()
                .fill(.white)
                .frame(width: p * 0.34, height: p * 0.28)
                .rotationEffect(.degrees(25))
                .blur(radius: p * 0.008)
                .offset(x: p * 0.24, y: -p * 0.27)

            // 광원 옆의 작은 점
            Circle()
                .fill(.white)
                .frame(width: p * 0.06, height: p * 0.06)
                .offset(x: p * 0.05, y: -p * 0.16)

            // 왼쪽 아래 흐릿한 반사 (창문/바닥)
            Ellipse()
                .fill(.white.opacity(0.32))
                .frame(width: p * 0.22, height: p * 0.17)
                .rotationEffect(.degrees(-20))
                .blur(radius: p * 0.015)
                .offset(x: -p * 0.22, y: p * 0.36)
            Circle()
                .fill(.white.opacity(0.22))
                .frame(width: p * 0.10, height: p * 0.10)
                .offset(x: p * 0.30, y: p * 0.20)

            // 반짝이 별들 — 큰 것 하나, 나머지는 작게 흩어서. 시간에 따라 각자 다른 리듬으로 반짝인다
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !twinkle)) { context in
                let t = twinkle ? context.date.timeIntervalSinceReferenceDate : 0
                ZStack {
                    sparkle(p: p, size: 0.30, at: CGPoint(x: -0.30, y: -0.04), pulse: pulse(t, period: 3.1, phase: 0.0))
                    sparkle(p: p, size: 0.15, at: CGPoint(x: 0.27, y: 0.33),  pulse: pulse(t, period: 2.3, phase: 1.7))
                    sparkle(p: p, size: 0.11, at: CGPoint(x: -0.10, y: 0.30), pulse: pulse(t, period: 4.0, phase: 3.9))
                    sparkle(p: p, size: 0.09, at: CGPoint(x: 0.04, y: -0.36), opacity: 0.85, pulse: pulse(t, period: 2.7, phase: 0.8))
                    sparkle(p: p, size: 0.07, at: CGPoint(x: -0.40, y: -0.30), opacity: 0.8, pulse: pulse(t, period: 3.6, phase: 2.6))
                    sparkle(p: p, size: 0.06, at: CGPoint(x: -0.42, y: 0.20), opacity: 0.7, pulse: pulse(t, period: 1.9, phase: 4.4))
                }
            }
        }
    }

    /// 0...1. 대부분의 시간은 0 근처에서 조용하다가 주기마다 한 번 짧게 확 튀는 파형.
    /// 서로 소수 비율인 두 주기를 섞어서 반복이 잘 안 보이게 한다.
    private func pulse(_ t: Double, period: Double, phase: Double) -> Double {
        let a = sin(t * 2 * .pi / period + phase)
        let b = sin(t * 2 * .pi / (period * 1.618) + phase * 0.7)
        let mixed = (a + b * 0.5) / 1.5       // -1...1
        return pow(max(0, mixed), 3)          // 양수 구간만, 뾰족하게
    }

    /// 4각 별 + 뒤에 흐린 글로우. `pulse`(0...1)가 클수록 커지고 밝아진다
    private func sparkle(p: CGFloat, size: CGFloat, at pos: CGPoint, opacity: Double = 1, pulse: Double = 0) -> some View {
        let s = p * size
        return ZStack {
            Sparkle()
                .fill(Color(hex: 0xFFE9A8))
                .frame(width: s * 1.6, height: s * 1.6)
                .blur(radius: s * 0.2)
                .opacity(0.5 + 0.5 * pulse)
            Sparkle()
                .fill(.white)
                .frame(width: s, height: s)
        }
        .scaleEffect(0.9 + 0.35 * pulse)
        .rotationEffect(.degrees(pulse * 12))
        .opacity(opacity * (0.8 + 0.2 * pulse))
        .offset(x: p * pos.x, y: p * pos.y)
    }
}

/// 4각 별 ✦. `inset`은 안쪽 꼭짓점 반지름 비율 — 작을수록 뾰족하다.
struct Sparkle: Shape {
    var inset: CGFloat = 0.28

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var path = Path()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4 - .pi / 2
            let radius = i.isMultiple(of: 2) ? r : r * inset
            let pt = CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

#Preview("정면 (레퍼런스 비교용)") {
    HStack(spacing: 160 * 0.22) {
        EyeView(gaze: .zero)
        EyeView(gaze: .zero)
    }
    .padding(40)
    .background(.black)
}

#Preview("눈꺼풀 표정") {
    VStack(spacing: 24) {
        // 기쁨: 아래꺼풀이 올라와 초승달
        HStack(spacing: 30) {
            EyeView(gaze: .zero, size: 120, pupilSize: 0.72, lowerLid: 0.4)
            EyeView(gaze: .zero, size: 120, pupilSize: 0.72, lowerLid: 0.4, mirrored: true)
        }
        // 화남: 위꺼풀 40% + 안쪽이 내려감
        HStack(spacing: 30) {
            EyeView(gaze: .zero, size: 120, pupilSize: 0.50, upperLid: 0.4, lidTilt: 18)
            EyeView(gaze: .zero, size: 120, pupilSize: 0.50, upperLid: 0.4, lidTilt: 18, mirrored: true)
        }
        // 슬픔: 위꺼풀 30% + 바깥쪽이 내려감, 시선 아래
        HStack(spacing: 30) {
            EyeView(gaze: CGPoint(x: 0, y: -0.5), size: 120, pupilSize: 0.72, upperLid: 0.3, lidTilt: -18)
            EyeView(gaze: CGPoint(x: 0, y: -0.5), size: 120, pupilSize: 0.72, upperLid: 0.3, lidTilt: -18, mirrored: true)
        }
        // 졸림: 위꺼풀 60%
        HStack(spacing: 30) {
            EyeView(gaze: CGPoint(x: 0, y: -0.3), size: 120, upperLid: 0.6)
            EyeView(gaze: CGPoint(x: 0, y: -0.3), size: 120, upperLid: 0.6, mirrored: true)
        }
    }
    .padding(40)
    .background(.black)
}

#Preview("시선 이동") {
    HStack(spacing: 40) {
        EyeView(gaze: CGPoint(x: -0.8, y: 0.3))
        EyeView(gaze: CGPoint(x: 0.8, y: -0.5))
    }
    .padding(40)
    .background(.black)
}
