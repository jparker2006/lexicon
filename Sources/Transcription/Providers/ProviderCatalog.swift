import LexiconDomain

/// The one place a `CloudModel` becomes an adapter. Exhaustive switch: adding a
/// case to `CloudModel` fails the build HERE until its adapter file exists.
func provider(for model: CloudModel) -> any StreamingProvider {
    switch model {
    case .museVoice: MuseVoice()
    }
}
