import SwiftUI
import UIKit

/// The outside display: a quiet opening screen until there is a message to show.
struct IdleView: View {
    let model: GazeModel
    var followsDeviceOrientation = false

    @State private var deviceOrientation: UIDeviceOrientation = .unknown
    @State private var sceneOrientation: UIInterfaceOrientation = .portrait

    var body: some View {
        GeometryReader { geometry in
            let turn = followsDeviceOrientation
                ? AudienceRotation.degrees(device: deviceOrientation, scene: sceneOrientation)
                : 0
            let contentSize = turn % 180 == 0
                ? geometry.size
                : CGSize(width: geometry.size.height, height: geometry.size.width)

            Group {
                if model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    IrisOpeningView(size: contentSize)
                } else {
                    AudienceMessageView(text: model.text, size: contentSize)
                }
            }
            .frame(width: contentSize.width, height: contentSize.height)
            .rotationEffect(.degrees(Double(turn)))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(.black)
        .overlay {
            if followsDeviceOrientation {
                AudienceSceneOrientationReader(orientation: $sceneOrientation)
                    .frame(width: 0, height: 0)
            }
        }
        .onAppear {
            guard followsDeviceOrientation else { return }
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            deviceOrientation = UIDevice.current.orientation
        }
        .onDisappear {
            if followsDeviceOrientation {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard followsDeviceOrientation else { return }
            let current = UIDevice.current.orientation
            if current.isValidInterfaceOrientation {
                deviceOrientation = current
            }
        }
    }
}

private enum AudienceRotation {
    static func degrees(device: UIDeviceOrientation, scene: UIInterfaceOrientation) -> Int {
        let desired: Int
        switch device {
        case .portrait: desired = 0
        case .landscapeLeft: desired = 270
        case .portraitUpsideDown: desired = 180
        case .landscapeRight: desired = 90
        default: return 0
        }

        let current: Int
        switch scene {
        case .portrait: current = 0
        case .landscapeRight: current = 270
        case .portraitUpsideDown: current = 180
        case .landscapeLeft: current = 90
        default: return 0
        }
        return (desired - current + 360) % 360
    }
}

private struct AudienceSceneOrientationReader: UIViewRepresentable {
    @Binding var orientation: UIInterfaceOrientation

    func makeUIView(context: Context) -> SceneOrientationView {
        let view = SceneOrientationView()
        let binding = $orientation
        view.onOrientationChange = { newValue in
            DispatchQueue.main.async {
                if binding.wrappedValue != newValue {
                    binding.wrappedValue = newValue
                }
            }
        }
        return view
    }

    func updateUIView(_ uiView: SceneOrientationView, context: Context) {}
}

private final class SceneOrientationView: UIView {
    var onOrientationChange: ((UIInterfaceOrientation) -> Void)?
    private weak var observedScene: UIWindowScene?
    private var geometryObservation: NSKeyValueObservation?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scene = window?.windowScene
        if observedScene !== scene {
            geometryObservation = nil
            observedScene = scene
            geometryObservation = scene?.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] scene, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.onOrientationChange?(scene.effectiveGeometry.interfaceOrientation)
                }
            }
        }
        reportOrientation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportOrientation()
    }

    private func reportOrientation() {
        guard let scene = window?.windowScene else { return }
        onOrientationChange?(scene.effectiveGeometry.interfaceOrientation)
    }
}

private struct IrisOpeningView: View {
    var size: CGSize

    var body: some View {
        let artworkSize = min(size.width * 0.72, size.height * 0.58, 390)
        let titleSize = min(size.width * 0.20, 72)

        VStack(spacing: 0) {
            Image("IrisOrb")
                .resizable()
                .scaledToFit()
                .frame(width: artworkSize, height: artworkSize)
                .accessibilityHidden(true)

            Text("Iris")
                .font(.custom("Inter-Regular", size: titleSize, relativeTo: .largeTitle).weight(.bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 0.78, green: 0.82, blue: 1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 8)

            Text("Open to talk")
                .font(.custom("Inter-Regular", size: 15, relativeTo: .body))
                .tracking(0.6)
                .foregroundStyle(Color(red: 0.55, green: 0.58, blue: 0.68))
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open the device to start talking with Iris")
    }
}

private struct AudienceMessageView: View {
    var text: String
    var size: CGSize

    private var textSize: CGFloat {
        let base = min(size.width * 0.14, 60)
        if text.count > 160 { return max(30, base * 0.65) }
        if text.count > 80 { return max(34, base * 0.8) }
        return max(38, base)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Image("IrisOrb")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)
                Text("Iris")
                    .font(.custom("Inter-Regular", size: 25, relativeTo: .title2).weight(.bold))
                    .foregroundStyle(Color(red: 0.84, green: 0.87, blue: 1))
            }
            .padding(.top, 28)
            .accessibilityHidden(true)

            ScrollViewReader { scroll in
                ScrollView {
                    Text(text)
                        .font(.custom("Inter-Regular", size: textSize, relativeTo: .largeTitle).weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: max(0, size.height - 118), alignment: .center)

                    Color.clear.frame(height: 1).id("messageEnd")
                }
                .scrollIndicators(.hidden)
                .onAppear { scroll.scrollTo("messageEnd", anchor: .bottom) }
                .onChange(of: text) { _, _ in scroll.scrollTo("messageEnd", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 26)
        .background(.black)
    }
}
