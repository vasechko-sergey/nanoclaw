import SwiftUI

// MARK: – OrbSatellite

/// One satellite around the hub orb.
struct OrbSatellite: Identifiable {
    let id: String
    /// SF Symbol name for suggestion/action satellites. `nil` → render as a colored agent orb.
    let icon: String?
    let label: String
    /// Tint color — `Theme.accent` for home satellites; per-agent accent for agent satellites.
    let accent: Color
    /// Whether the satellite receives the active/"continue" visual emphasis.
    let isHighlighted: Bool
    let action: () -> Void
}

// MARK: – OrbOrbit

/// Orbit geometry helpers — single source of orbit math for all satellite rings.
enum OrbOrbit {
    /// Returns the (x, y) offset for satellite at `index` out of `count`,
    /// arranged top-anchored (12 o'clock) clockwise around a circle of `radius` points.
    static func position(index: Int, count: Int, radius: CGFloat) -> CGPoint {
        let angle = -.pi / 2 + (2 * .pi / Double(max(count, 1))) * Double(index)
        return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }
}

// MARK: – OrbHub

/// Reusable orb-cluster view — a central `OrbView` surrounded by two rings of
/// injectable `OrbSatellite`s. The default ring is always visible; the action
/// ring is revealed on long-press (state is owned here).
///
/// `OrbHomeView` uses this with suggestion satellites in the default ring and
/// mic/camera/photo/file in the action ring. A future iPad canvas task will
/// reuse it with agent satellites in the default ring.
struct OrbHub: View {
    /// Default ring — always visible (suggestions or agent orbs).
    let satellites: [OrbSatellite]
    /// Action ring — revealed on long-press (mic, keyboard, camera, photo, file).
    let actionSatellites: [OrbSatellite]
    /// Emotional state of the central orb.
    var mood: OrbMood = .welcoming
    /// Tint color for the central orb (unused by `OrbView` directly, reserved for future tinting).
    var coreAccent: Color = Theme.accent
    @Binding var showSatellites: Bool
    /// Called when the central orb is tapped and the action ring is not showing.
    var onOrbTap: () -> Void


    // Radius is based on the default-ring count, matching the original orbCluster
    // behaviour where `defaultSatellites.count` drove the radius for BOTH rings.
    private var orbitRadius: CGFloat {
        Theme.scaled(satellites.count > 6 ? 150 : 130)
    }

    var body: some View {
        ZStack {
            // Default ring — visible when action ring is hidden
            ForEach(Array(satellites.enumerated()), id: \.offset) { index, sat in
                let pos = OrbOrbit.position(index: index, count: satellites.count,
                                            radius: orbitRadius)
                HomeSatelliteOrb(
                    icon: sat.icon,
                    label: sat.label,
                    accent: sat.accent,
                    isHighlighted: sat.isHighlighted,
                    action: sat.action
                )
                .offset(x: showSatellites ? 0 : pos.x, y: showSatellites ? 0 : pos.y)
                .scaleEffect(showSatellites ? 0.3 : 1.0)
                .opacity(showSatellites ? 0 : 1.0)
                .allowsHitTesting(!showSatellites)
                .animation(
                    .spring(duration: 0.4, bounce: 0.25).delay(Double(index) * 0.06),
                    value: showSatellites
                )
            }

            // Action ring — revealed on long-press
            ForEach(Array(actionSatellites.enumerated()), id: \.offset) { index, sat in
                let pos = OrbOrbit.position(index: index, count: actionSatellites.count,
                                            radius: orbitRadius)
                HomeSatelliteOrb(
                    icon: sat.icon,
                    label: sat.label,
                    accent: sat.accent,
                    isHighlighted: sat.isHighlighted,
                    action: {
                        sat.action()
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                            showSatellites = false
                        }
                    }
                )
                .offset(x: showSatellites ? pos.x : 0, y: showSatellites ? pos.y : 0)
                .scaleEffect(showSatellites ? 1.0 : 0.3)
                .opacity(showSatellites ? 1.0 : 0)
                .allowsHitTesting(showSatellites)
                .animation(
                    // Skip animation in UITesting so satellites jump to final position
                    // immediately — lets XCUITest tap them at the correct coordinate.
                    JarvisApp.isUITesting ? nil : .spring(duration: 0.4, bounce: 0.25).delay(Double(index) * 0.06),
                    value: showSatellites
                )
            }

            // Central orb
            VStack(spacing: Theme.scaled(8)) {
                ZStack {
                    OrbView(size: Theme.orbSize, mood: showSatellites ? .heroic : mood)
                        .scaleEffect(showSatellites ? 1.08 : 1.0)
                        .animation(.spring(duration: 0.3), value: showSatellites)
                        .onTapGesture {
                            if showSatellites {
                                withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                                    showSatellites = false
                                }
                            } else {
                                Theme.hapticSend()
                                onOrbTap()
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.3) {
                            Theme.hapticMedium()
                            withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
                                showSatellites.toggle()
                            }
                        }
                        .accessibilityLabel("Начать диалог")
                        .accessibilityIdentifier("home-orb")

                    // UI-test-only: reliable Button tap target that opens the voice
                    // fullscreen. The OrbView's `.onTapGesture` is not always picked
                    // up by XCUITest (TimelineView + custom rendering + parent
                    // identifier propagation interfere with hit-test discovery).
                    if JarvisApp.isUITesting && !showSatellites {
                        Button(action: {
                            onOrbTap()
                        }) {
                            Rectangle()
                                .fill(Color.white.opacity(0.01))
                                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                        }
                        .accessibilityLabel("uitest-home-orb")
                        .accessibilityIdentifier("home-orb-uitest")
                    }
                }
            }

            // UI-test-only: tap target to reveal action satellites.
            // Offset off the central orb so taps on the orb itself (which open the
            // voice fullscreen) are not intercepted by this overlay. Only present
            // when satellites are hidden — once visible, action satellites must
            // receive taps directly.
            if JarvisApp.isUITesting && !showSatellites {
                Button(action: {
                    withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
                        showSatellites = true
                    }
                }) {
                    Rectangle()
                        .fill(Color.white.opacity(0.01))
                        .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                }
                .accessibilityLabel("Toggle satellite menu")
                .accessibilityIdentifier("orb-satellites-toggle")
                // Park near the top of the cluster, clear of the central orb's hit area.
                .offset(y: -Theme.scaled(170))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.scaled(360))
        .contentShape(Rectangle())
        .onTapGesture {
            if showSatellites {
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                    showSatellites = false
                }
            }
        }
    }
}

// MARK: – HomeSatelliteOrb

/// Satellite button rendered in both rings of `OrbHub`.
///
/// When `icon` is non-nil, renders an SF Symbol in the ring (suggestion/action style).
/// When `icon` is nil, renders a filled agent-orb (colored core + ring) for future
/// agent-satellite use — the home screen always passes non-nil icons so that path is
/// pixel-identical to the original `HomeSatelliteOrb` in `OrbHomeView`.
struct HomeSatelliteOrb: View {
    let icon: String?
    let label: String
    /// Tint for the ring stroke, glow, and icon. Defaults to `Theme.accent`.
    var accent: Color = Theme.accent
    /// Highlighted state — used for the "Продолжить" satellite (stronger ring + icon).
    var isHighlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.scaled(6)) {
                ZStack {
                    // Outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    accent.opacity(isHighlighted ? 0.12 : 0.06),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: Theme.scaled(20),
                                endRadius: Theme.scaled(36)
                            )
                        )
                        .frame(width: Theme.scaled(60), height: Theme.scaled(60))

                    // Main circle
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Theme.surface.opacity(0.9),
                                    Theme.background.opacity(0.7)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: Theme.scaled(50), height: Theme.scaled(50))
                        .overlay(
                            Circle().stroke(
                                isHighlighted ? accent.opacity(0.5) : accent.opacity(0.15),
                                lineWidth: Theme.lineHairline
                            )
                        )

                    if let icon {
                        // SF Symbol path (suggestion / action satellites)
                        Image(systemName: icon)
                            .font(.system(size: Theme.scaled(20), weight: .light))
                            .foregroundStyle(isHighlighted ? accent : Theme.accentMedium.opacity(0.8))
                    } else {
                        // Agent-orb path: filled colored core (no SF Symbol)
                        Circle()
                            .fill(accent.opacity(0.85))
                            .frame(width: Theme.scaled(22), height: Theme.scaled(22))
                    }
                }
                Text(label)
                    .font(.system(size: Theme.scaled(10), weight: .medium))
                    .foregroundStyle(Theme.accentMedium.opacity(0.7))
            }
        }
        .accessibilityLabel(label)
    }
}
