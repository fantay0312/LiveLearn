import MacAudio

/// Edits remain local until the proposed sources and language directions pass validation.
struct SessionSourceSelection: Equatable {
    enum Computer: String, CaseIterable { case off, system, applications }
    var computer: Computer
    var applications: [RunningApplicationSummary]
    var microphoneEnabled: Bool
    var microphone: AudioInputDevice?
    var languages: OverlayLanguages

    @MainActor init(model: AppModel) {
        computer = model.useSystem ? .system : (model.useApplication ? .applications : .off)
        applications = model.selectedApplications
        microphoneEnabled = model.useMicrophone
        microphone = model.selectedMicrophone
        languages = OverlayLanguages(settings: model.settings)
    }

    var validationError: String? {
        if computer == .off && !microphoneEnabled { return "请至少启用一个音源。" }
        if computer == .applications && applications.isEmpty { return "请选择要收听的应用。" }
        return nil
    }

    mutating func toggleApplication(_ app: RunningApplicationSummary) {
        if computer != .applications { applications = [] }
        computer = .applications
        if applications.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            applications.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        } else { applications.append(app) }
        // An empty explicit selection remains invalid; never silently expand capture scope.
    }

    @MainActor func apply(to model: AppModel) {
        model.select(applications: applications)
        model.useApplication = computer == .applications
        model.useSystem = computer == .system
        model.settings.listenToApplications = computer == .applications
        model.useMicrophone = microphoneEnabled
        model.select(microphone: microphone)
        model.settings.mode = computer == .off ? .faceToFace : (microphoneEnabled ? .converse : .listen)
    }
}
