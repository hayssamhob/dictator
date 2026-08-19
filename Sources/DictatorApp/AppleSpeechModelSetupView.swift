import DictatorCore
import SwiftUI

struct AppleSpeechModelSetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.appleSpeech.state.locales.isEmpty {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Primary")
                            .font(.dictatorUtility(9))
                            .foregroundStyle(DictatorDesign.muted)
                        DictatorMenuField(
                            label: "Language",
                            options: model.appleSpeech.state.locales.map {
                                .init(value: $0.identifier, label: localeDisplayName($0.identifier))
                            },
                            selection: Binding(
                                get: { model.appleSpeech.state.selectedLocaleIdentifier },
                                set: { model.selectAppleSpeechLocale($0) }
                            )
                        )
                    }

                    if model.appleSpeech.state.secondaryLocaleIdentifier != nil {
                        Button(action: { model.swapAppleSpeechLocales() }) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.dictatorBody(11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .help("Swap primary and secondary languages")
                        .padding(.top, 14)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Secondary")
                            .font(.dictatorUtility(9))
                            .foregroundStyle(DictatorDesign.muted)
                        DictatorMenuField(
                            label: "Language",
                            options: secondaryLocaleOptions,
                            selection: Binding(
                                get: { model.appleSpeech.state.secondaryLocaleIdentifier ?? "none" },
                                set: { model.selectAppleSpeechSecondaryLocale($0 == "none" ? nil : $0) }
                            )
                        )
                    }
                }
            }

            Text(model.appleSpeech.statusText)
                .font(.dictatorBody(12, weight: .medium))
                .foregroundStyle(model.appleSpeech.state.readiness.isReady ? DictatorDesign.focus : .secondary)

            if case let .downloading(_, progress) = model.appleSpeech.state.readiness {
                ProgressView(value: progress)
            }
        }
        .task { await model.appleSpeech.refresh() }
    }

    private var secondaryLocaleOptions: [DictatorMenuOption] {
        var options: [DictatorMenuOption] = [.init(value: "none", label: "None")]
        options.append(contentsOf: model.appleSpeech.state.locales
            .filter { $0.identifier != model.appleSpeech.state.selectedLocaleIdentifier }
            .map { .init(value: $0.identifier, label: localeDisplayName($0.identifier)) })
        return options
    }

    private func localeDisplayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
