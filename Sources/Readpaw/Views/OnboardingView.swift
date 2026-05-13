import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        ZStack {
            ReadpawBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 32)

                MoonView()
                    .frame(width: 520, height: 520)
                    .shadow(color: Color(red: 0.78, green: 0.86, blue: 1.0).opacity(0.30),
                            radius: 90, x: 0, y: 0)
                    .shadow(color: Color(red: 0.95, green: 0.96, blue: 1.0).opacity(0.18),
                            radius: 30, x: 0, y: 0)

                Spacer(minLength: 24)

                VStack(spacing: 8) {
                    Text("A reader for every story.")
                        .font(.system(size: 17, weight: .regular, design: .serif))
                        .italic()
                        .foregroundStyle(Color.white.opacity(0.78))
                    Text("Comics, manga, and ebooks — all in one quiet place.")
                        .font(.system(size: 17, weight: .regular, design: .serif))
                        .italic()
                        .foregroundStyle(Color.white.opacity(0.78))
                }
                .multilineTextAlignment(.center)

                Spacer(minLength: 36)

                Button {
                    library.promptForFolder()
                } label: {
                    Text("Choose your library")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.04, green: 0.06, blue: 0.14))
                        .padding(.horizontal, 44)
                        .padding(.vertical, 16)
                        .background(
                            Capsule()
                                .fill(Color.white)
                                .shadow(color: Color(red: 0.70, green: 0.82, blue: 1.0).opacity(0.55),
                                        radius: 30, x: 0, y: 0)
                                .shadow(color: Color.white.opacity(0.22), radius: 12, x: 0, y: 0)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Spacer(minLength: 60)
            }
            .padding(.horizontal, 60)
        }
    }
}

struct ReadpawBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.040, green: 0.075, blue: 0.180), location: 0.0),
                    .init(color: Color(red: 0.020, green: 0.040, blue: 0.110), location: 0.55),
                    .init(color: Color(red: 0.005, green: 0.015, blue: 0.060), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Subtle radial vignette/highlight near top-center
            RadialGradient(
                colors: [
                    Color(red: 0.15, green: 0.28, blue: 0.55).opacity(0.30),
                    Color.clear
                ],
                center: UnitPoint(x: 0.5, y: 0.18),
                startRadius: 0,
                endRadius: 520
            )
            .blendMode(.screen)
        }
    }
}
