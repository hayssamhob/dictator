import DictatorCore
import Foundation

struct AppleSpeechSetupState: Equatable {
    var selectedLocaleIdentifier: String
    var secondaryLocaleIdentifier: String?
    var locales: [AppleSpeechLocale]
    var readiness: AppleSpeechReadiness

    var readyLocale: AppleSpeechLocale? {
        guard case .ready(let locale) = readiness else { return nil }
        return locale
    }

    var readySecondaryLocale: AppleSpeechLocale? {
        guard let secondary = secondaryLocaleIdentifier else { return nil }
        return locales.first { $0.identifier == secondary }
    }
}

@MainActor
final class AppleSpeechCoordinator: ObservableObject {
    @Published private(set) var state: AppleSpeechSetupState

    let isAvailable: Bool
    private let provider: (any LocalSpeechTranscribing)?
    private let persistSelection: (String) -> Void
    private let persistSecondarySelection: (String?) -> Void
    private var generation = 0

    init(
        provider: (any LocalSpeechTranscribing)?,
        selectedLocaleIdentifier: String,
        secondaryLocaleIdentifier: String? = nil,
        persistSelection: @escaping (String) -> Void,
        persistSecondarySelection: @escaping (String?) -> Void = { _ in }
    ) {
        self.provider = provider
        self.persistSelection = persistSelection
        self.persistSecondarySelection = persistSecondarySelection
        isAvailable = provider != nil
        state = .init(
            selectedLocaleIdentifier: selectedLocaleIdentifier,
            secondaryLocaleIdentifier: secondaryLocaleIdentifier,
            locales: [],
            readiness: .checking
        )
    }

    var statusText: String {
        switch state.readiness {
        case .checking: "Checking model availability…"
        case .downloadRequired(let locale): "Download \(displayName(for: locale.identifier)) to use Apple On-Device."
        case .downloading(_, let progress): "Downloading model… \(Int(progress * 100))%"
        case .ready(let locale):
            "Ready · \(displayName(for: locale.identifier))" + (state.secondaryLocaleIdentifier.map { " + \(displayName(for: $0))" } ?? "")
        case .unavailable(let reason), .failed(let reason): reason
        }
    }

    func selectLocale(_ identifier: String) {
        guard state.locales.contains(where: { $0.identifier == identifier }) else { return }
        generation += 1
        state.selectedLocaleIdentifier = identifier
        state.readiness = .checking
        persistSelection(identifier)
        let expectedGeneration = generation
        Task { await refresh(expectedGeneration: expectedGeneration) }
    }

    func selectSecondaryLocale(_ identifier: String?) {
        let resolved = identifier.flatMap { id in
            state.locales.contains(where: { $0.identifier == id }) ? id : nil
        }
        guard resolved != state.secondaryLocaleIdentifier else { return }
        state.secondaryLocaleIdentifier = resolved
        persistSecondarySelection(resolved)
    }

    func swapLocales() {
        guard let secondary = state.secondaryLocaleIdentifier else { return }
        let primary = state.selectedLocaleIdentifier
        selectLocale(secondary)
        selectSecondaryLocale(primary)
    }

    func refresh() async {
        generation += 1
        await refresh(expectedGeneration: generation)
    }

    func prepare() async {
        guard let provider else {
            state.readiness = .unavailable("Apple On-Device transcription requires macOS 26 or later.")
            return
        }
        if state.locales.isEmpty { await refresh() }
        if state.readiness.isReady { return }
        guard let locale = state.readiness.locale
                ?? state.locales.first(where: { $0.identifier == state.selectedLocaleIdentifier })
        else { return }

        generation += 1
        let expectedGeneration = generation
        let expectedIdentifier = state.selectedLocaleIdentifier
        state.readiness = .downloading(locale, progress: 0)
        do {
            let readiness = try await provider.installAssets(for: expectedIdentifier) { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                          self.generation == expectedGeneration,
                          self.state.selectedLocaleIdentifier == expectedIdentifier
                    else { return }
                    self.state.readiness = .downloading(locale, progress: min(max(progress, 0), 1))
                }
            }
            guard generation == expectedGeneration,
                  state.selectedLocaleIdentifier == expectedIdentifier
            else { return }
            apply(readiness, for: expectedIdentifier)
        } catch is CancellationError {
            guard generation == expectedGeneration,
                  state.selectedLocaleIdentifier == expectedIdentifier
            else { return }
            state.readiness = .checking
            Task { await self.refresh() }
            return
        } catch {
            guard generation == expectedGeneration,
                  state.selectedLocaleIdentifier == expectedIdentifier
            else { return }
            state.readiness = .failed("Model download failed: \(error.localizedDescription)")
        }
    }

    func transcribe(audio: RecordedAudio, vocabulary: [VocabularyEntry]) async throws -> TranscriptionResult {
        guard let provider else {
            throw ProviderError.unsupported("Apple On-Device transcription requires macOS 26 or later.")
        }
        guard let locale = state.readyLocale else {
            throw ProviderError.invalidConfiguration("Download the selected Apple speech model before dictating.")
        }
        do {
            let result = try await provider.transcribe(
                audio: audio,
                localeIdentifier: locale.identifier,
                vocabulary: vocabulary
            )
            if !result.text.isEmpty { return result }
            // Empty transcript — try secondary locale if set
            if let secondary = state.readySecondaryLocale {
                return try await provider.transcribe(
                    audio: audio,
                    localeIdentifier: secondary.identifier,
                    vocabulary: vocabulary
                )
            }
            return result
        } catch ProviderError.emptyTranscript {
            // Primary locale returned empty — try secondary
            if let secondary = state.readySecondaryLocale {
                return try await provider.transcribe(
                    audio: audio,
                    localeIdentifier: secondary.identifier,
                    vocabulary: vocabulary
                )
            }
            throw ProviderError.emptyTranscript
        }
    }

    private func refresh(expectedGeneration: Int) async {
        guard let provider else {
            guard generation == expectedGeneration else { return }
            state = .init(
                selectedLocaleIdentifier: state.selectedLocaleIdentifier,
                secondaryLocaleIdentifier: state.secondaryLocaleIdentifier,
                locales: [],
                readiness: .unavailable("Apple On-Device transcription requires macOS 26 or later.")
            )
            return
        }

        let requestedIdentifier = state.selectedLocaleIdentifier
        let locales = await provider.availableLocales()
        guard generation == expectedGeneration else { return }
        guard !locales.isEmpty else {
            state = .init(
                selectedLocaleIdentifier: requestedIdentifier,
                secondaryLocaleIdentifier: state.secondaryLocaleIdentifier,
                locales: [],
                readiness: .unavailable("No Apple speech languages are available on this Mac.")
            )
            return
        }

        let selectedIdentifier = resolvedSelection(requestedIdentifier, from: locales)
        state = .init(
            selectedLocaleIdentifier: selectedIdentifier,
            secondaryLocaleIdentifier: state.secondaryLocaleIdentifier.flatMap { id in
                locales.contains(where: { $0.identifier == id }) ? id : nil
            },
            locales: locales,
            readiness: .checking
        )
        if selectedIdentifier != requestedIdentifier { persistSelection(selectedIdentifier) }

        let readiness = await provider.readiness(for: selectedIdentifier)
        guard generation == expectedGeneration,
              state.selectedLocaleIdentifier == selectedIdentifier
        else { return }
        apply(readiness, for: selectedIdentifier)
    }

    private func apply(_ readiness: AppleSpeechReadiness, for requestedIdentifier: String) {
        let resolvedIdentifier = readiness.locale?.identifier ?? requestedIdentifier
        if resolvedIdentifier != state.selectedLocaleIdentifier {
            state.selectedLocaleIdentifier = resolvedIdentifier
            persistSelection(resolvedIdentifier)
        }
        state.readiness = readiness
    }

    private func resolvedSelection(_ requestedIdentifier: String, from locales: [AppleSpeechLocale]) -> String {
        if locales.contains(where: { $0.identifier == requestedIdentifier }) { return requestedIdentifier }
        let requestedLanguage = Locale(identifier: requestedIdentifier).language.languageCode
        return locales.first {
            Locale(identifier: $0.identifier).language.languageCode == requestedLanguage
        }?.identifier ?? locales[0].identifier
    }

    private func displayName(for localeIdentifier: String) -> String {
        Locale.current.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
    }

    private func engineName(_ engine: AppleTranscriptionEngine) -> String {
        switch engine {
        case .speechTranscriber: "SpeechTranscriber"
        case .dictationTranscriber: "Dictation fallback"
        }
    }
}
