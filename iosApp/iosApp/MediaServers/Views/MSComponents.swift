#if !os(macOS)
import SwiftUI

enum MSMetrics {
    #if os(tvOS)
    static let posterWidth: CGFloat = 220
    static let thumbWidth: CGFloat = 400
    static let gridMin: CGFloat = 220
    static let rowSpacing: CGFloat = 40
    static let edge: CGFloat = 80
    static let titleFont: Font = .system(size: 26, weight: .semibold)
    static let captionFont: Font = .system(size: 22)
    #else
    static let posterWidth: CGFloat = 116
    static let thumbWidth: CGFloat = 230
    static let gridMin: CGFloat = 108
    static let rowSpacing: CGFloat = 12
    static let edge: CGFloat = 16
    static let titleFont: Font = .system(size: 13, weight: .semibold)
    static let captionFont: Font = .system(size: 12)
    #endif
}

extension View {
    /// Card buttons get the system lift-and-focus look on Apple TV and stay
    /// flat on iPhone and iPad.
    @ViewBuilder
    func msCardButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(.plain)
        #endif
    }
}

/// Remote artwork with a quiet placeholder.
struct MSArtwork: View {
    let url: URL?
    var systemImage: String = "film"

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
    }
}

/// Thin bar along the bottom of a card for partly watched items.
struct MSProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.5))
                Capsule().fill(Color.accentColor).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
    }
}

struct MSWatchedBadge: View {
    let item: MSItem

    var body: some View {
        if item.isWatched {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .font(.system(size: MSMetrics.edge > 40 ? 30 : 18))
                .padding(6)
        } else if let count = item.unwatchedCount, count > 0, item.kind == .series || item.kind == .season {
            Text("\(count)")
                .font(.caption.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
                .padding(6)
        }
    }
}

/// 2:3 poster with title underneath.
struct MSPosterCard: View {
    let item: MSItem
    var width: CGFloat = MSMetrics.posterWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MSArtwork(url: item.posterURL)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .topTrailing) { MSWatchedBadge(item: item) }
                .overlay(alignment: .bottom) {
                    if let fraction = item.progressFraction {
                        MSProgressBar(fraction: fraction).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(item.title)
                .font(MSMetrics.titleFont)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            if let year = item.year {
                Text(String(year))
                    .font(MSMetrics.captionFont)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 16:9 card for episodes and Continue Watching.
struct MSWideCard: View {
    let item: MSItem
    var width: CGFloat = MSMetrics.thumbWidth

    private var secondLine: String? {
        if item.kind == .episode {
            let parts = [item.episodeLabel, item.title].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        return item.subtitleLine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MSArtwork(url: item.thumbURL ?? item.backdropURL ?? item.posterURL, systemImage: "play.rectangle")
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .topTrailing) { MSWatchedBadge(item: item) }
                .overlay(alignment: .bottom) {
                    if let fraction = item.progressFraction {
                        MSProgressBar(fraction: fraction).padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(item.kind == .episode ? (item.seriesTitle ?? item.title) : item.title)
                .font(MSMetrics.titleFont)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            if let line = secondLine {
                Text(line)
                    .font(MSMetrics.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
    }
}

/// A titled horizontal row of cards.
struct MSShelf<Card: View>: View {
    let title: String
    let items: [MSItem]
    let card: (MSItem) -> Card
    let onSelect: (MSItem) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.title3.bold())
                    .padding(.horizontal, MSMetrics.edge)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: MSMetrics.rowSpacing) {
                        ForEach(items) { item in
                            Button { onSelect(item) } label: { card(item) }
                                .msCardButtonStyle()
                        }
                    }
                    .padding(.horizontal, MSMetrics.edge)
                    #if os(tvOS)
                    .padding(.vertical, 30)
                    #endif
                }
                #if os(tvOS)
                .scrollClipDisabled()
                #endif
            }
        }
    }
}

struct MSErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Error {
    var msMessage: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
#endif
