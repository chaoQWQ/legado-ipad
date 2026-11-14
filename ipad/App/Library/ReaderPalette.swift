import SwiftUI

enum ReaderPalette {
    static let accent = Color(red: 0.66, green: 0.29, blue: 0.19)

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.09, green: 0.09, blue: 0.08)
            : Color(red: 0.97, green: 0.95, blue: 0.91)
    }

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.16, green: 0.15, blue: 0.13)
            : Color(red: 1.00, green: 0.99, blue: 0.96)
    }

    static func cover(for title: String) -> Color {
        let colors: [(Double, Double, Double)] = [
            (0.34, 0.22, 0.17), (0.21, 0.31, 0.27), (0.24, 0.29, 0.37),
            (0.53, 0.24, 0.20), (0.33, 0.26, 0.31), (0.39, 0.33, 0.20)
        ]
        let value = title.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % colors.count }
        let (red, green, blue) = colors[value]
        return Color(red: red, green: green, blue: blue)
    }
}

struct BookCover: View {
    let title: String
    let author: String
    let url: URL?

    var body: some View {
        Color.clear
            .aspectRatio(0.73, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            paperCover
                        }
                    }
                } else {
                    paperCover
                }
            }
            .clipShape(.rect(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 10, topTrailingRadius: 10))
            .accessibilityHidden(true)
    }

    private var paperCover: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let ink = Color(red: 0.99, green: 0.94, blue: 0.83)

            ZStack(alignment: .leading) {
                ReaderPalette.cover(for: title)
                LinearGradient(colors: [.white.opacity(0.1), .clear, .black.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle()
                    .fill(.black.opacity(0.22))
                    .frame(width: max(2, width * 0.04))

                VStack(alignment: .leading, spacing: width * 0.09) {
                    Image(systemName: "book.closed")
                        .font(.system(size: width * 0.12, weight: .light))
                    Rectangle()
                        .fill(ink.opacity(0.35))
                        .frame(width: width * 0.25, height: 1)
                    Text(title)
                        .font(.system(size: max(12, width * 0.13), weight: .semibold, design: .serif))
                        .lineLimit(4)
                        .minimumScaleFactor(0.7)
                    if !author.isEmpty {
                        Text(author)
                            .font(.system(size: max(9, width * 0.07)))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ink)
                .padding(width * 0.16)
            }
        }
    }
}
