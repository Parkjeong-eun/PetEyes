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

    /// 레퍼런스 이미지에서 위치·크기를 동공 지름(p) 비율로 옮긴 값. 좌표는 동공 중심 기준.
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

#Preview("정면 (레퍼런스 비교용)") {
    HStack(spacing: 160 * 0.22) {
        EyeView(gaze: .zero)
        EyeView(gaze: .zero)
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
