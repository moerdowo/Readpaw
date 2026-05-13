import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor),
                                    Color(nsColor: .underPageBackgroundColor)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "books.vertical.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .foregroundStyle(.tint)
                    .shadow(radius: 12, y: 6)

                Text("Welcome to Readpaw")
                    .font(.largeTitle.weight(.bold))

                Text("Your native macOS reader for comics and manga.\nSupports CBZ, CBR, ZIP, RAR, 7z, and PDF.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)

                Button {
                    library.promptForFolder()
                } label: {
                    Label("Choose Library Folder", systemImage: "folder.badge.plus")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Text("Pick a folder containing your comics. Subfolders are scanned automatically.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(40)
        }
    }
}
