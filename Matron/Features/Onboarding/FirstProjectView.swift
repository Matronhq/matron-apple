import SwiftUI
import MatronModels
import MatronViewModels

struct FirstProjectView: View {
    @Bindable var model: FirstProjectViewModel
    let openConversation: (String) -> Void
    let openResult: (String) -> Void
    let openProject: (String) -> Void
    let showConversations: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var confirmAnotherStart = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Make something with Matron").font(.title2.bold())
                    Text("Connect Claude, give it a useful first project, then open what it makes.")
                        .foregroundStyle(.secondary)
                    Text("Step \(model.step) of 3").font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("firstProject.step")
                    ProgressView(value: Double(model.step), total: 3)
                }
                if model.step == 1 { connectionSection }
                if model.step == 2 { projectSection }
                if model.step == 3 { resultSection }
                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Try checking again") { Task { await model.load() } }
                            .disabled(model.busy)
                    }
                }
            }
            .navigationTitle("Get started")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { model.skip(); dismiss() }
                        .accessibilityIdentifier("firstProject.later")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("You can return here from Settings → Get started.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding().background(.bar)
            }
            .task { await model.load() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    if model.needsRefresh { await model.refresh() }
                }
            }
            .onDisappear { code = "" }
            .alert("Start another chat?", isPresented: $confirmAnotherStart) {
                Button("Cancel", role: .cancel) {}
                Button("Start again") { model.allowAnotherStart() }
            } message: {
                Text("The first request may have created a chat. Check Conversations first so you do not start the same work twice.")
            }
        }
    }

    @ViewBuilder private var connectionSection: some View {
        Section("1. Connect Claude") {
            if model.busy { ProgressView("Checking your server…") }
            if model.boxes.isEmpty && !model.busy {
                Text("Your server needs a connected Matron box. Finish server setup, then try again.")
                Button("Check for my server") { Task { await model.load() } }
            } else {
                if model.boxes.count > 1 {
                    Picker("Server", selection: Binding(get: { model.progress.boxID ?? 0 },
                        set: { id in Task { await model.selectBox(id) } })) {
                        ForEach(model.boxes) { box in Text(box.name).tag(box.id) }
                    }.disabled(model.busy)
                }
                if model.connection == "unsupported" {
                    Text("This server needs a newer Matron bridge to guide Claude sign-in. Update it, then try again.")
                } else if model.connection == "locked" {
                    Text("Your box is locked. Unlock it from Boxes, then return here.")
                } else if model.connection == "unavailable" {
                    Text("Claude's sign-in tools are not available on this server. Check the Claude installation, then try again.")
                } else if model.connection == "busy" {
                    Text("Another device is signing in to Claude on this server. Finish that sign-in, then check again.")
                } else if ["starting", "checking"].contains(model.connection) {
                    ProgressView(model.connection == "starting" ? "Opening Claude sign-in…" : "Checking Claude sign-in…")
                } else {
                    Text("Use your Claude subscription on this server. Matron will confirm when the connection is ready.")
                    if let url = model.authorizationURL {
                        Link("Open Claude sign-in", destination: url)
                            .accessibilityIdentifier("firstProject.authorize")
                        Text("After signing in, return here. If Claude gives you a code, paste it below.")
                    } else if model.connection != "invalid_code" {
                        if ["expired", "failed", "cancelled"].contains(model.connection) {
                            Text("That sign-in did not finish. Start again for a fresh link.")
                        }
                        Button("Connect Claude") { Task { await model.connect() } }
                            .disabled(model.busy).accessibilityIdentifier("firstProject.connect")
                    }
                    if model.authorizationURL != nil || model.connection == "invalid_code" {
                        SecureField("Code from Claude", text: $code)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("firstProject.code")
                        Button("Finish connecting") {
                            let submitted = code.trimmingCharacters(in: .whitespacesAndNewlines)
                            code = ""
                            Task { await model.submit(code: submitted) }
                        }.disabled(code.isEmpty || model.busy)
                    }
                }
                if ["unsupported", "locked", "unavailable", "busy"].contains(model.connection) {
                    Button("Check again") { Task { await model.refresh() } }.disabled(model.busy)
                }
                if ["starting", "waiting", "checking", "invalid_code"].contains(model.connection) {
                    Button("Cancel sign-in", role: .cancel) { Task { await model.cancelLogin() } }.disabled(model.busy)
                }
            }
        }
    }

    private var projectSection: some View {
        Section("2. Make your first project") {
            Label("Claude is connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Picker("What would you like to make?", selection: Binding(get: { model.progress.kind }, set: { model.choose($0) })) {
                ForEach(FirstProjectKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            TextField("Describe what you want", text: Binding(get: { model.progress.brief }, set: { model.setBrief($0) }), axis: .vertical)
                .lineLimit(3...8).accessibilityIdentifier("firstProject.brief")
            Text("Claude will do the work on your server, using your Claude allowance. You can keep talking to it as it works.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { Task { await model.startProject() } } label: {
                if model.busy { ProgressView("Starting your project…") } else { Text("Start my project") }
            }.disabled(!model.canStart).accessibilityIdentifier("firstProject.start")
        }
    }

    @ViewBuilder private var resultSection: some View {
        Section("3. Open your result") {
            if model.progress.startUnconfirmed {
                Text("The server has not confirmed whether your chat started.")
                Button("Check Conversations") { dismiss(); showConversations() }
                Button("I've checked — start again") { confirmAnotherStart = true }
            } else if let result = model.result {
                Label(result.title, systemImage: "checkmark.circle.fill")
                Button("Open result") { model.openedResult(); dismiss(); openResult(result.noticeID) }
                    .accessibilityIdentifier("firstProject.result")
                if let project = result.projectID {
                    Button("Open project") { dismiss(); openProject(project) }
                }
            } else if model.progress.promptQueued {
                ProgressView("Your project is underway…")
                Text("The finished page or report will appear here with its result notice. If Claude needs you, it will ask in the conversation or For you.")
            } else {
                Text("Your chat is ready, but the brief has not been sent yet.")
                Button("Send my brief") { Task { await model.load() } }.disabled(model.busy)
            }
            if let id = model.progress.conversationID {
                Button("Open conversation") { dismiss(); openConversation(id) }
                    .accessibilityIdentifier("firstProject.conversation")
            }
        }
    }
}
