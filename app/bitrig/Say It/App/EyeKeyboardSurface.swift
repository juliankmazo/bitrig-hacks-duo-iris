import SwiftUI

struct EyeKeyboardSurface: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @AppStorage("gazeDwellTime") private var gazeDwellTime = 1.2
  var store: CommunicationStore
  var speech: SpeechService
  var rate: Double
  var tracker: GazeTracker
  var isTapSimulation: Bool

  @State private var keyFrames: [String: CGRect] = [:]
  @State private var hoveredKey: String?
  @State private var hoverStarted = Date()
  @State private var hoverProgress = 0.0
  @State private var didActivateHover = false
  @State private var showingPreview = false

  private var columns: [GridItem] {
    let count = horizontalSizeClass == .regular ? 7 : 5
    return Array(repeating: GridItem(.flexible(minimum: 52), spacing: 8), count: count)
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label(
            tracker.outerDisplayPresented ? "Showing outside" : (isTapSimulation ? "Tap simulation" : (tracker.outerDisplayAvailable ? "Outside display ready" : "Outside display connects when available")),
            systemImage: tracker.outerDisplayPresented ? "checkmark.circle.fill" : (isTapSimulation ? "hand.tap" : "eye")
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
          Spacer()
          if isTapSimulation {
            Button("Preview message", systemImage: "rectangle.expand.vertical") {
              showingPreview = true
            }
            .labelStyle(.iconOnly)
            .disabled(store.message.isEmpty)
          } else {
            Button("Stop eye control", systemImage: "eye.slash") { tracker.stop() }
              .labelStyle(.iconOnly)
          }
        }

        ScrollView {
          Text(store.message.isEmpty ? (isTapSimulation ? "Tap a key to start a message" : "Look at a key to start a message") : store.message)
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        }
        .frame(maxHeight: 126)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

        Text(isTapSimulation ? "Tap letters below to test the keyboard." : (tracker.gazePoint == nil ? "Look toward the inner camera" : "Hold your gaze on a key to select it"))
          .font(.subheadline)
          .foregroundStyle(.secondary)

        ScrollView {
          LazyVGrid(columns: columns, spacing: 8) {
            ForEach(EyeKey.keys) { key in
              EyeKeyButton(
                key: key,
                isTapSimulation: isTapSimulation,
                isHovered: hoveredKey == key.id,
                progress: hoveredKey == key.id ? hoverProgress : 0,
                action: { activate(key) },
                onFrame: { keyFrames[key.id] = $0 }
              )
            }
          }
          .padding(.bottom, 12)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .coordinateSpace(name: "eyeSurface")
      .onChange(of: tracker.gazePoint) { _, point in
        if !isTapSimulation {
          processGaze(point, size: geometry.size)
        }
      }
    }
    .fullScreenCover(isPresented: $showingPreview) {
      MessageDisplayView(message: store.message)
    }
  }

  private func processGaze(_ point: CGPoint?, size: CGSize) {
    guard let point else {
      hoveredKey = nil
      hoverProgress = 0
      didActivateHover = false
      return
    }

    let location = CGPoint(x: point.x * size.width, y: point.y * size.height)
    let keyID = keyFrames.first { $0.value.contains(location) }?.key
    if keyID != hoveredKey {
      hoveredKey = keyID
      hoverStarted = Date()
      hoverProgress = 0
      didActivateHover = false
      return
    }

    guard let keyID, !didActivateHover else { return }
    hoverProgress = min(Date().timeIntervalSince(hoverStarted) / gazeDwellTime, 1)
    if hoverProgress >= 1, let key = EyeKey.keys.first(where: { $0.id == keyID }) {
      activate(key)
      didActivateHover = true
    }
  }

  private func activate(_ key: EyeKey) {
    switch key.action {
    case .character(let value):
      store.message.append(value)
    case .space:
      if !store.message.isEmpty && !store.message.hasSuffix(" ") {
        store.message.append(" ")
      }
    case .delete:
      if !store.message.isEmpty { store.message.removeLast() }
    case .clear:
      store.message = ""
    case .speak:
      speech.speak(store.message, rate: rate)
    }
  }
}

private struct EyeKeyButton: View {
  var key: EyeKey
  var isTapSimulation: Bool
  var isHovered: Bool
  var progress: Double
  var action: () -> Void
  var onFrame: (CGRect) -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        if let symbol = key.symbol {
          Image(systemName: symbol)
            .font(.title2.bold())
        } else {
          Text(key.title)
            .font(.title2.bold())
        }
        if isHovered {
          ProgressView(value: progress)
            .tint(.accentColor)
        }
      }
      .foregroundStyle(.primary)
      .frame(maxWidth: .infinity, minHeight: 66)
      .background(
        isHovered ? Color.accentColor.opacity(0.2) : Color(uiColor: .secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 14)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .strokeBorder(isHovered ? Color.accentColor : .clear, lineWidth: 2)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(key.title)
    .accessibilityHint(isTapSimulation ? "Tap to select" : "Hold your gaze or tap to select")
    .onGeometryChange(for: CGRect.self) { geometry in
      geometry.frame(in: .named("eyeSurface"))
    } action: { frame in
      onFrame(frame)
    }
  }
}

private struct EyeKey: Identifiable {
  enum Action {
    case character(String)
    case space
    case delete
    case clear
    case speak
  }

  var id: String
  var title: String
  var symbol: String?
  var action: Action

  static let keys: [EyeKey] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map { letter in
    EyeKey(id: String(letter), title: String(letter), action: .character(String(letter).lowercased()))
  } + [
    EyeKey(id: "period", title: ".", action: .character(".")),
    EyeKey(id: "question", title: "?", action: .character("?")),
    EyeKey(id: "space", title: "Space", symbol: "space", action: .space),
    EyeKey(id: "delete", title: "Delete", symbol: "delete.left", action: .delete),
    EyeKey(id: "clear", title: "Clear", symbol: "xmark", action: .clear),
    EyeKey(id: "speak", title: "Speak", symbol: "speaker.wave.2.fill", action: .speak)
  ]
}
