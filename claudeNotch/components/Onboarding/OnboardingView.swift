//
//  OnboardingView.swift
//  claudeNotch
//
//  Created by Alexander on 2025-06-23.
//  Modified for ClaudeNotch by Harrison Riehle.
//

import SwiftUI

enum OnboardingStep {
    case welcome
    case claudeLogin
    case finished
}

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        step = .claudeLogin
                    }
                }
                .transition(.opacity)

            case .claudeLogin:
                ClaudeLoginView(
                    onSuccess: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            ClaudeViewCoordinator.shared.firstLaunch = false
                            step = .finished
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            ClaudeViewCoordinator.shared.firstLaunch = false
                            step = .finished
                        }
                    }
                )
                .transition(.opacity)

            case .finished:
                OnboardingFinishView(onFinish: onFinish, onOpenSettings: onOpenSettings)
            }
        }
        .frame(width: 400, height: 600)
    }
}
