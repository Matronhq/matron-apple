import SwiftUI
import MatronModels

/// One routine's editor, or the new-routine form. A new routine chooses
/// schedule or trigger once: the journal keeps a routine that kind for
/// life, so an existing one edits only its own kind's fields. A pure leaf
/// view: `onSave` validates and writes (it is `RoutinesViewModel.save`),
/// answering `nil` on success or the reason it refused, which the form
/// shows without clearing what was typed.
public struct RoutineEditorView: View {
    public enum Mode: String, Hashable, CaseIterable, Sendable {
        case schedule, trigger
        var label: String { self == .schedule ? "On a schedule" : "When something happens" }
    }

    public struct Draft: Equatable, Sendable {
        public var name: String
        public var title: String
        public var prompt: String
        public var tz: String
        public var mode: Mode
        /// minute, hour, day of month, month, day of week.
        public var cron: [String]
        public var triggerKind: RoutineTrigger.Kind
        public var threshold: Int
        public var enabled: Bool

        public init(name: String = "", title: String = "", prompt: String = "",
                    tz: String = RoutineRules.defaultZone, mode: Mode = .schedule,
                    cron: [String] = ["0", "9", "*", "*", "1-5"],
                    triggerKind: RoutineTrigger.Kind = .contextOver, threshold: Int = 40, enabled: Bool = true) {
            self.name = name; self.title = title; self.prompt = prompt; self.tz = tz; self.mode = mode
            self.cron = cron; self.triggerKind = triggerKind; self.threshold = threshold; self.enabled = enabled
        }

        public init(routine: Routine) {
            var cron = (routine.schedule ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            if cron.count != 5 { cron = Draft().cron }
            let trigger = routine.trigger ?? RoutineTrigger.Kind.contextOver.defaultTrigger
            self.init(name: routine.name, title: routine.title, prompt: routine.prompt, tz: routine.tz,
                      mode: routine.isTriggered ? .trigger : .schedule, cron: cron,
                      triggerKind: trigger.kind, threshold: trigger.threshold, enabled: routine.enabled)
        }

        public var schedule: String { cron.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
        public var trigger: RoutineTrigger { .make(kind: triggerKind, threshold: threshold) }

        /// What saving sends. `enabled` rides only on a create: on an edit
        /// the list's switch owns it.
        public func routineDraft(isNew: Bool) -> RoutineDraft {
            RoutineDraft(title: title, prompt: prompt, tz: tz,
                         schedule: mode == .schedule ? schedule : nil,
                         trigger: mode == .trigger ? trigger : nil,
                         enabled: isNew ? enabled : nil)
        }

        /// The plain-words preview under the cron fields.
        public var schedulePreview: String {
            if let problem = RoutineRules.scheduleError(schedule) { return problem }
            return CronWords.describe(schedule) ?? "Runs on the cron schedule \(schedule)."
        }
    }

    static let cronLabels = ["Minute", "Hour", "Day", "Month", "Weekday"]

    let routine: Routine?
    let onSave: (Draft) async -> String?
    let onDelete: () async -> String?
    let onRun: (() async -> String?)?

    @State private var draft: Draft
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    @State private var confirmingDelete = false

    public init(routine: Routine?, onSave: @escaping (Draft) async -> String?,
                onDelete: @escaping () async -> String?, onRun: (() async -> String?)? = nil) {
        self.routine = routine; self.onSave = onSave; self.onDelete = onDelete; self.onRun = onRun
        _draft = State(initialValue: routine.map(Draft.init(routine:)) ?? Draft())
    }

    var isNew: Bool { routine == nil }

    public var body: some View {
        Form {
            #if os(macOS)
            Section {
                Text(routine?.title ?? "New routine").font(.title2.weight(.semibold))
                if let routine { Text(routine.name).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            #endif
            if isNew {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("weekly-review"))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        #endif
                        .labelsHidden()
                        .accessibilityIdentifier("routine.name")
                } header: {
                    Text("Name")
                } footer: {
                    Text("Lowercase letters, digits and dashes. It can't be changed later.")
                }
            }
            Section("Title") {
                TextField("Title", text: $draft.title, prompt: Text("Weekly review"))
                    .labelsHidden()
                    .accessibilityIdentifier("routine.title")
            }
            Section {
                ZStack(alignment: .topLeading) {
                    if draft.prompt.isEmpty {
                        Text("What the Coordinator should do when this fires")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $draft.prompt)
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .accessibilityIdentifier("routine.prompt")
                }
            } header: {
                Text("Prompt")
            } footer: {
                Text("\(draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).count)/\(RoutineRules.promptMaxLength)")
                    .monospacedDigit()
            }
            if isNew {
                Section {
                    Picker("Runs", selection: $draft.mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("routine.mode")
                } header: {
                    Text("Runs")
                } footer: {
                    Text("A routine stays scheduled or triggered: this can't be changed later.")
                }
            }
            switch draft.mode {
            case .schedule: scheduleSection
            case .trigger: triggerSection
            }
            if isNew {
                Section {
                    Toggle("Active", isOn: $draft.enabled)
                }
            }
            Section {
                if let error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("routine.error")
                }
                if let note {
                    Text(note).foregroundStyle(.secondary)
                }
                Button { Task { await save() } } label: {
                    Text(busy ? "Saving…" : "Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("routine.save")
                if let onRun, !isNew {
                    Button {
                        Task {
                            busy = true
                            let message = await onRun()
                            note = message ?? "Sent to the Coordinator."
                            busy = false
                        }
                    } label: {
                        Label("Run now", systemImage: "play").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("routine.run")
                }
            }
            if routine != nil {
                Section {
                    Button("Delete routine", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("routine.delete")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        #if os(iOS)
        .navigationTitle(routine?.title ?? "New routine")
        #endif
        .confirmationDialog("Delete this routine?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Coordinator stops receiving it. This can't be undone.")
        }
    }

    private var scheduleSection: some View {
        Section {
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { index in
                    VStack(spacing: 2) {
                        TextField(Self.cronLabels[index], text: $draft.cron[index])
                            .font(.body.monospaced())
                            .multilineTextAlignment(.center)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numbersAndPunctuation)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            .labelsHidden()
                            .accessibilityLabel(Self.cronLabels[index])
                            .accessibilityIdentifier("routine.cron.\(index)")
                        Text(Self.cronLabels[index]).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text(draft.schedulePreview)
                .font(.callout)
                .accessibilityIdentifier("routine.schedulePreview")
            TextField("Time zone", text: $draft.tz, prompt: Text(RoutineRules.defaultZone))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("routine.tz")
        } header: {
            Text("Schedule")
        } footer: {
            Text("Five cron fields, in the time zone below. It may fire at most every \(RoutineRules.minGapMinutes) minutes.")
        }
    }

    private var triggerSection: some View {
        Section {
            Picker("When", selection: Binding(get: { draft.triggerKind }, set: { kind in
                guard kind != draft.triggerKind else { return }
                draft.triggerKind = kind
                draft.threshold = kind.defaultTrigger.threshold
            })) {
                ForEach(RoutineTrigger.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("routine.triggerKind")
            Stepper(value: $draft.threshold, in: RoutineTrigger.thresholdRange(for: draft.triggerKind),
                    step: draft.triggerKind == .stalled ? 30 : 5) {
                Text(Self.thresholdLabel(draft.trigger)).monospacedDigit()
            }
            .accessibilityIdentifier("routine.threshold")
            Text(draft.trigger.words).font(.callout)
        } header: {
            Text("Trigger")
        } footer: {
            Text("It fires once for each session or box that crosses the line, at most every \(RoutineRules.minGapMinutes) minutes.")
        }
    }

    static func thresholdLabel(_ trigger: RoutineTrigger) -> String {
        switch trigger {
        case .contextOver(let pct): return "\(pct)% of the context window"
        case .diskUnder(let pct): return "\(pct)% free disk"
        case .stalled(let minutes): return minutes == 0 ? "Any reset time" : "No reset within \(RoutineTrigger.duration(minutes))"
        }
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        note = nil
        error = await onSave(draft)
        busy = false
    }

    private func delete() async {
        guard !busy else { return }
        busy = true
        error = await onDelete()
        busy = false
    }
}
