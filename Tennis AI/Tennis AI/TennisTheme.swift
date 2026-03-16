//
//  TennisTheme.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/11.
//

import Combine
import SwiftUI

enum CourtSurfaceTheme: String, CaseIterable, Identifiable {
    case hard
    case clay
    case grass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hard:
            return "硬地蓝"
        case .clay:
            return "红土橙"
        case .grass:
            return "草地绿"
        }
    }

    var scoreboardCode: String {
        switch self {
        case .hard:
            return "HARD"
        case .clay:
            return "CLAY"
        case .grass:
            return "GRASS"
        }
    }

    var icon: String {
        switch self {
        case .hard:
            return "square.grid.3x3.fill"
        case .clay:
            return "flame.fill"
        case .grass:
            return "leaf.fill"
        }
    }

    var palette: TennisPalette {
        switch self {
        case .hard:
            return TennisPalette(
                courtDeepGreen: Color(red: 0.08, green: 0.23, blue: 0.45),
                courtGreen: Color(red: 0.11, green: 0.39, blue: 0.66),
                courtLightGreen: Color(red: 0.24, green: 0.59, blue: 0.84),
                lineWhite: Color(red: 0.92, green: 0.96, blue: 1.00),
                ballYellow: Color(red: 0.90, green: 0.95, blue: 0.23),
                clayOrange: Color(red: 0.94, green: 0.56, blue: 0.31),
                skyMint: Color(red: 0.84, green: 0.92, blue: 0.99),
                pageTop: Color(red: 0.90, green: 0.95, blue: 0.99),
                pageBottom: Color(red: 0.83, green: 0.90, blue: 0.97)
            )
        case .clay:
            return TennisPalette(
                courtDeepGreen: Color(red: 0.48, green: 0.22, blue: 0.12),
                courtGreen: Color(red: 0.67, green: 0.34, blue: 0.18),
                courtLightGreen: Color(red: 0.82, green: 0.49, blue: 0.27),
                lineWhite: Color(red: 1.00, green: 0.93, blue: 0.84),
                ballYellow: Color(red: 0.95, green: 0.89, blue: 0.24),
                clayOrange: Color(red: 0.91, green: 0.43, blue: 0.22),
                skyMint: Color(red: 0.98, green: 0.89, blue: 0.78),
                pageTop: Color(red: 0.98, green: 0.93, blue: 0.86),
                pageBottom: Color(red: 0.95, green: 0.87, blue: 0.77)
            )
        case .grass:
            return TennisPalette(
                courtDeepGreen: Color(red: 0.09, green: 0.33, blue: 0.19),
                courtGreen: Color(red: 0.16, green: 0.49, blue: 0.26),
                courtLightGreen: Color(red: 0.26, green: 0.63, blue: 0.34),
                lineWhite: Color(red: 0.95, green: 0.98, blue: 0.93),
                ballYellow: Color(red: 0.86, green: 0.94, blue: 0.20),
                clayOrange: Color(red: 0.86, green: 0.45, blue: 0.20),
                skyMint: Color(red: 0.80, green: 0.93, blue: 0.84),
                pageTop: Color(red: 0.92, green: 0.97, blue: 0.91),
                pageBottom: Color(red: 0.86, green: 0.94, blue: 0.87)
            )
        }
    }
}

struct TennisPalette {
    let courtDeepGreen: Color
    let courtGreen: Color
    let courtLightGreen: Color
    let lineWhite: Color
    let ballYellow: Color
    let clayOrange: Color
    let skyMint: Color
    let pageTop: Color
    let pageBottom: Color
}

@MainActor
final class ThemeStore: ObservableObject {
    static let selectedSurfaceDefaultsKey = "court_surface_theme"

    @Published var selectedSurface: CourtSurfaceTheme {
        didSet {
            guard oldValue != selectedSurface else { return }
            defaults.set(selectedSurface.rawValue, forKey: Self.selectedSurfaceDefaultsKey)
            TennisTheme.currentSurface = selectedSurface
        }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedSurface = defaults.string(forKey: Self.selectedSurfaceDefaultsKey)
        self.selectedSurface = CourtSurfaceTheme(rawValue: storedSurface ?? "") ?? .grass
        TennisTheme.currentSurface = selectedSurface
    }

    var palette: TennisPalette {
        selectedSurface.palette
    }

    func select(_ surface: CourtSurfaceTheme) {
        guard selectedSurface != surface else { return }
        selectedSurface = surface
    }

    static func resetPersistedSelection(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: selectedSurfaceDefaultsKey)
    }
}

enum TennisTheme {
    static var currentSurface: CourtSurfaceTheme = .grass

    static var palette: TennisPalette {
        currentSurface.palette
    }

    static var courtDeepGreen: Color { palette.courtDeepGreen }
    static var courtGreen: Color { palette.courtGreen }
    static var courtLightGreen: Color { palette.courtLightGreen }
    static var lineWhite: Color { palette.lineWhite }
    static var ballYellow: Color { palette.ballYellow }
    static var clayOrange: Color { palette.clayOrange }
    static var skyMint: Color { palette.skyMint }

    static var pageBackground: LinearGradient {
        LinearGradient(
            colors: [palette.pageTop, palette.pageBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct CourtSurfaceBackground: View {
    var body: some View {
        ZStack {
            TennisTheme.pageBackground

            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                let pad = min(width, height) * 0.08

                Path { path in
                    path.addRoundedRect(
                        in: CGRect(
                            x: pad,
                            y: pad * 1.8,
                            width: width - 2 * pad,
                            height: height - (pad * 2.8)
                        ),
                        cornerSize: CGSize(width: 18, height: 18)
                    )

                    let centerX = width / 2
                    path.move(to: CGPoint(x: centerX, y: pad * 1.8))
                    path.addLine(to: CGPoint(x: centerX, y: height - pad))

                    let serviceY = pad * 1.8 + (height - (pad * 2.8)) * 0.38
                    path.move(to: CGPoint(x: pad, y: serviceY))
                    path.addLine(to: CGPoint(x: width - pad, y: serviceY))

                    let baselineY = height - pad
                    path.move(to: CGPoint(x: pad, y: baselineY))
                    path.addLine(to: CGPoint(x: width - pad, y: baselineY))
                }
                .stroke(TennisTheme.lineWhite.opacity(0.22), lineWidth: 1.2)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func tennisCard() -> some View {
        self
            .background(Color.white.opacity(0.90))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(TennisTheme.lineWhite.opacity(0.40), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: TennisTheme.courtDeepGreen.opacity(0.08), radius: 10, x: 0, y: 6)
    }
}
