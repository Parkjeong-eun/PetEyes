//
//  PetEyesApp.swift
//  PetEyes
//
//  Created by 박정은 on 9/11/26.
//

import SwiftUI

@main
struct PetEyesApp: App {
    var body: some Scene {
        WindowGroup {
            EyesScreen()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                // 기기에 꽂아두고 오래 켜두는 용도 → 화면 자동 꺼짐 방지
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
