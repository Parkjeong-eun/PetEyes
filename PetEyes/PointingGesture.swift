//
//  PointingGesture.swift
//  PetEyes
//

import Vision

/// 검지로 어딘가를 가리키는 손. 좌표는 Vision 정규화(0...1, 원점 좌하단).
nonisolated struct Pointing: Sendable, Equatable {
    /// 검지 끝
    var tip: CGPoint
    /// 검지 MCP → 끝 방향의 단위 벡터
    var direction: CGVector
    /// 손 크기 근사 (손목 ↔ 검지 MCP 거리). 여러 손 중 가까운 손을 고를 때 씀
    var palmLength: CGFloat
}

/// 손 포즈 관측에서 "가리키기" 제스처를 판정한다. 순수 함수 — 어느 스레드에서든 호출 가능.
///
/// 판정 규칙:
///  - 검지는 펴져 있다: 끝이 PIP보다 손목에서 멀다 (`indexExtendedRatio` 이상)
///  - 중지·약지·새끼는 굽혀 있다: 끝이 PIP보다 손목에 가깝다 (`curledRatio` 이하)
///  - 엄지는 무시 (펴고 가리키는 사람도, 접고 가리키는 사람도 있음)
///  - 검지의 2D 길이가 손바닥 길이 대비 너무 짧으면(카메라 쪽/반대쪽을 가리킴) 방향을 신뢰할 수 없어 nil
nonisolated enum PointingGesture {
    /// 관절 신뢰도 하한. 이보다 낮으면 그 관절은 없는 것으로 본다
    static var minConfidence: Float = 0.4
    /// 검지 끝↔손목 / 검지 PIP↔손목 비율이 이 이상이면 "펴짐"
    static var indexExtendedRatio: CGFloat = 1.15
    /// 나머지 손가락은 이 비율 이하면 "굽힘"
    static var curledRatio: CGFloat = 1.0
    /// 검지 2D 길이 / 손바닥 길이가 이 이하면 카메라 축 방향으로 가리키는 것 → 무시
    static var minDirectionRatio: CGFloat = 0.5

    static func detect(in hand: VNHumanHandPoseObservation) -> Pointing? {
        guard let points = try? hand.recognizedPoints(.all) else { return nil }

        func p(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let pt = points[name], pt.confidence >= minConfidence else { return nil }
            return pt.location
        }
        guard let wrist = p(.wrist),
              let indexMCP = p(.indexMCP), let indexPIP = p(.indexPIP), let indexTip = p(.indexTip),
              let middlePIP = p(.middlePIP), let middleTip = p(.middleTip),
              let ringPIP = p(.ringPIP), let ringTip = p(.ringTip),
              let littlePIP = p(.littlePIP), let littleTip = p(.littleTip)
        else { return nil }

        func extensionRatio(tip: CGPoint, pip: CGPoint) -> CGFloat {
            let dPIP = distance(pip, wrist)
            guard dPIP > 0 else { return 0 }
            return distance(tip, wrist) / dPIP
        }

        guard extensionRatio(tip: indexTip, pip: indexPIP) >= indexExtendedRatio,
              extensionRatio(tip: middleTip, pip: middlePIP) <= curledRatio,
              extensionRatio(tip: ringTip, pip: ringPIP) <= curledRatio,
              extensionRatio(tip: littleTip, pip: littlePIP) <= curledRatio
        else { return nil }

        let palm = distance(indexMCP, wrist)
        let dx = indexTip.x - indexMCP.x
        let dy = indexTip.y - indexMCP.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard palm > 0, length / palm >= minDirectionRatio else { return nil }

        return Pointing(tip: indexTip,
                        direction: CGVector(dx: dx / length, dy: dy / length),
                        palmLength: palm)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
