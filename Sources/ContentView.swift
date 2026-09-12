import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    @State private var dragStartRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreviewView(cameraManager: viewModel.cameraManager)
                    .ignoresSafeArea()

                roiOverlay(in: geo.size)

                if viewModel.showOCROverlay {
                    VStack {
                        Spacer()
                        ocrTextOverlay
                            .padding(.bottom, 240)
                    }
                }

                VStack {
                    topBar
                    Spacer()
                }
            }
        }
        .sheet(isPresented: .constant(true)) {
            answerSheet
                .presentationDetents([.height(220), .medium, .large])
                .presentationBackgroundInteraction(.enabled)
                .interactiveDismissDisabled()
        }
        .statusBarHidden(true)
        .alert(
            "Camera access needed",
            isPresented: .constant(viewModel.cameraManager.permissionDenied)
        ) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please allow camera access in Settings to use live OCR scanning.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            statusBadge
            quotaBadge
            sharpnessBadge // CHANGE: new — live sharpness score for calibrating BlurDetector's threshold.
            Spacer()

            Button {
                viewModel.showOCROverlay.toggle()
            } label: {
                Image(systemName: viewModel.showOCROverlay ? "eye.fill" : "eye.slash.fill")
            }
            .buttonStyle(.toolbarCircle)

            Button {
                viewModel.toggle()
            } label: {
                Image(systemName: viewModel.isRunning ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.toolbarCircle)

            Button {
                viewModel.clearHistory()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.toolbarCircle)
        }
        .padding(.horizontal)
        .padding(.top, 54)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(viewModel.state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize() // CHANGE: prevent wrapping now that 3 badges share the top bar.
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var quotaBadge: some View {
        Text("\(viewModel.requestsUsedToday)/\(viewModel.estimatedDailyQuota) today")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }

    // CHANGE: new — diagnostic badge showing the live blur/sharpness score.
    // Once you've picked a good `minimumSharpnessScore` in MainViewModel by
    // watching this number in different real conditions, feel free to
    // remove this badge (and `currentSharpnessScore`) if you don't want it
    // as permanent UI.
    private var sharpnessBadge: some View {
        Text("sharp: \(Int(viewModel.currentSharpnessScore))")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .idle: return .gray
        case .scanning: return .blue
        case .sendingToAI: return .orange
        case .answerReady: return .green
        case .error: return .red
        }
    }

    // MARK: - Draggable Region of Interest

    private func roiOverlay(in size: CGSize) -> some View {
        let rect = CGRect(
            x: viewModel.regionOfInterest.minX * size.width,
            y: viewModel.regionOfInterest.minY * size.height,
            width: viewModel.regionOfInterest.width * size.width,
            height: viewModel.regionOfInterest.height * size.height
        )

        return Rectangle()
            .strokeBorder(Color.yellow, lineWidth: 2)
            .background(Color.yellow.opacity(0.05))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartRect == nil { dragStartRect = viewModel.regionOfInterest }
                        guard let start = dragStartRect else { return }
                        var newRect = start
                        newRect.origin.x = min(
                            max(0, start.minX + value.translation.width / size.width),
                            1 - newRect.width
                        )
                        newRect.origin.y = min(
                            max(0, start.minY + value.translation.height / size.height),
                            1 - newRect.height
                        )
                        viewModel.regionOfInterest = newRect
                    }
                    .onEnded { _ in
                        dragStartRect = nil
                        viewModel.focusCameraOnROI() // CHANGE: re-lock focus on the new ROI position after dragging.
                    }
            )
    }

    // MARK: - OCR text overlay 

    private var ocrTextOverlay: some View {
        ScrollView {
            Text(viewModel.currentOCRText.isEmpty ? "No text detected yet…" : viewModel.currentOCRText)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 100)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: - Bottom answer sheet 

    private var answerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gemini Answer")
                    .font(.headline)
                Spacer()
                if viewModel.state == .sendingToAI {
                    ProgressView()
                }
                Button {
                    viewModel.copyAnswer()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(viewModel.geminiAnswer.isEmpty)
            }

            Button {
                viewModel.askGemini()
            } label: {
                Label("Ask Gemini", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.currentOCRText.isEmpty || viewModel.state == .sendingToAI)

            ScrollView {
                Text(viewModel.geminiAnswer.isEmpty ? "Point the camera at text, then tap Ask Gemini." : viewModel.geminiAnswer)
                    .font(.body)
                    .foregroundStyle(viewModel.geminiAnswer.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)

            if !viewModel.history.isEmpty {
                Divider()
                Text("History")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.history) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.question)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(item.answer)
                                    .font(.caption)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct ToolbarCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(.ultraThinMaterial, in: Circle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == ToolbarCircleButtonStyle {
    static var toolbarCircle: ToolbarCircleButtonStyle { ToolbarCircleButtonStyle() }
}

#Preview {
    ContentView()
}