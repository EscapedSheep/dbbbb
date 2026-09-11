import SwiftUI
import AppKit
import dbbbbCore

/// New-connection sheet: one form per engine, with validation, an environment
/// picker, and a read-only toggle. Production connections get a visible warning.
struct NewConnectionView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Edit mode: the connection being edited. The engine is fixed; password
    /// fields start blank (blank = keep the current one).
    private let editing: SessionStore.ConnectionEditingContext?

    @State private var engine: DatabaseEngine = .postgresql
    @State private var name = ""
    @State private var host = "localhost"
    @State private var port = "5432"
    @State private var username = ""
    @State private var password = ""
    @State private var database = ""
    @State private var sslMode: SSLMode = .disable
    @State private var mongoURI = "mongodb://localhost:27017"
    @State private var mongoTLS = false
    @State private var sqlitePath = ""
    @State private var bullPrefix = "bull"
    @State private var bullTLS = false
    @State private var environment: ConnectionEnvironment = .development
    @State private var readOnly = false
    @State private var addError: String?
    @State private var isSubmitting = false
    /// Edit mode on a never-persisted session: opt-in "Save this connection".
    @State private var rememberConnection = false

    /// Add mode (nil) or edit mode with every field prefilled from the
    /// current input — except password fields, which start blank on purpose.
    init(editing: SessionStore.ConnectionEditingContext? = nil) {
        self.editing = editing
        guard let input = editing?.input else { return }
        _engine = State(initialValue: input.engine)
        _environment = State(initialValue: input.environment)
        _readOnly = State(initialValue: input.readOnly)
        switch input {
        case .postgres(let i):
            _name = State(initialValue: i.name)
            _host = State(initialValue: i.host)
            _port = State(initialValue: String(i.port))
            _username = State(initialValue: i.username)
            _database = State(initialValue: i.database)
            _sslMode = State(initialValue: i.sslMode)
        case .mysql(let i):
            _name = State(initialValue: i.name)
            _host = State(initialValue: i.host)
            _port = State(initialValue: String(i.port))
            _username = State(initialValue: i.username)
            _database = State(initialValue: i.database)
            _sslMode = State(initialValue: i.sslMode)
        case .mongo(let i):
            _name = State(initialValue: i.name)
            _mongoURI = State(initialValue: i.uri)
            _database = State(initialValue: i.database)
            _mongoTLS = State(initialValue: i.tls)
        case .sqlite(let i):
            _name = State(initialValue: i.name)
            _sqlitePath = State(initialValue: i.filePath)
        case .bullmq(let i):
            _name = State(initialValue: i.name)
            _host = State(initialValue: i.host)
            _port = State(initialValue: String(i.port))
            _database = State(initialValue: String(i.database))
            _bullPrefix = State(initialValue: i.prefix)
            _bullTLS = State(initialValue: i.tls)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if editing != nil {
                    // Editing never changes the engine — show it as a fixed card.
                    HStack(spacing: 10) {
                        EngineBadge(engine: engine)
                        Text(engine.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppColors.text)
                        Spacer(minLength: 0)
                        Text("Engine can't be changed")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColors.textDisabled)
                    }
                    .padding(.vertical, 4)
                } else {
                    // Engine cards, two per row (reference `.engine-picker`).
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(DatabaseEngine.allCases, id: \.self) { candidate in
                            EngineOptionCard(engine: candidate, isSelected: candidate == engine) {
                                engine = candidate
                                switch candidate {
                                case .mysql: port = "3306"
                                case .bullmq: port = "6379"
                                default: port = "5432"
                                }
                                addError = nil
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Connection") {
                    TextField("Name", text: $name, prompt: Text(engine.displayName))
                    switch engine {
                    case .postgresql, .mysql:
                        TextField("Host", text: $host)
                        TextField("Port", text: $port)
                        TextField("Username", text: $username)
                        SecureField("Password", text: $password,
                                    prompt: Text(editing == nil ? "" : "Leave blank to keep the current password"))
                        if editing != nil {
                            Text("Leave blank to keep the current password.")
                                .font(.caption)
                                .foregroundStyle(AppColors.textDisabled)
                        }
                        // Optional for both: PostgreSQL falls back to the
                        // `postgres` maintenance database; MySQL connects
                        // without a default schema and browses server-wide.
                        TextField("Database", text: $database, prompt: Text(
                            engine == .postgresql ? "postgres (default)" : "Optional — all schemas"))
                        Picker("SSL Mode", selection: $sslMode) {
                            ForEach(SSLMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    case .mongodb:
                        TextField("URI", text: $mongoURI, prompt: Text("mongodb://host:27017"))
                            .font(.system(.body, design: .monospaced))
                        TextField("Database", text: $database)
                        Toggle("TLS", isOn: $mongoTLS)
                    case .sqlite:
                        HStack {
                            TextField("File Path", text: $sqlitePath, prompt: Text("/path/to/database.db"))
                                .font(.system(.body, design: .monospaced))
                            Button("Choose…") { chooseSQLiteFile() }
                        }
                    case .bullmq:
                        TextField("Host", text: $host)
                        TextField("Port", text: $port)
                        SecureField("Password", text: $password, prompt: Text(
                            editing == nil ? "Optional — Redis AUTH" : "Leave blank to keep the current password"))
                        if editing != nil {
                            Text("Leave blank to keep the current password.")
                                .font(.caption)
                                .foregroundStyle(AppColors.textDisabled)
                        }
                        TextField("Database", text: $database, prompt: Text("0–15"))
                        TextField("Key Prefix", text: $bullPrefix, prompt: Text("bull"))
                        Toggle("TLS", isOn: $bullTLS)
                    }
                }

                Section("Options") {
                    if let editing, !editing.isPersisted {
                        Toggle("Save this connection", isOn: $rememberConnection)
                        Text("Off: this edit stays session-only. On: the connection is stored with the protected OS credential storage.")
                            .font(.caption)
                            .foregroundStyle(AppColors.textDisabled)
                    }
                    Picker("Environment", selection: $environment) {
                        ForEach(ConnectionEnvironment.allCases, id: \.self) { env in
                            Text(env.rawValue.capitalized).tag(env)
                        }
                    }
                    Toggle("Read-only connection", isOn: $readOnly)
                    if environment == .production {
                        Label(
                            "Production connection — take extra care with writes.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(AppColors.production)
                        .font(.callout)
                    }
                }

                if !issues.isEmpty {
                    Section {
                        ForEach(issues, id: \.self) { issue in
                            Label(issue, systemImage: "exclamationmark.circle")
                                .foregroundStyle(AppColors.danger)
                                .font(.callout)
                        }
                    }
                }
                if let addError {
                    Section {
                        Label(addError, systemImage: "exclamationmark.circle")
                            .foregroundStyle(AppColors.danger)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(AppColors.bgPanel)

            HStack {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.appSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add Connection" : "Save Changes") { submit() }
                    .buttonStyle(.appPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!issues.isEmpty || isSubmitting)
            }
            .padding()
            .background(AppColors.bgSubtle)
            .overlay(alignment: .top) {
                Rectangle().fill(AppColors.border).frame(height: 1)
            }
        }
        .frame(width: 480, height: 580)
        .background(AppColors.bgPanel)
    }

    // MARK: Validation

    private var issues: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("Name is required.")
        }
        switch engine {
        case .postgresql, .mysql:
            if host.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("Host is required.")
            }
            if let portNumber = Int(port), (1...65535).contains(portNumber) {
            } else {
                problems.append("Port must be a number between 1 and 65535.")
            }
            // Database is optional for both SQL servers (see the field prompt).
        case .mongodb:
            let uri = mongoURI.trimmingCharacters(in: .whitespaces)
            if !uri.hasPrefix("mongodb://") && !uri.hasPrefix("mongodb+srv://") {
                problems.append("URI must start with mongodb:// or mongodb+srv://.")
            }
            // MongoDB still requires a database: the command contract carries
            // no database, so the adapter runs every command against one fixed
            // database (documented in MongoAdapter).
            if database.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("Database is required.")
            }
        case .sqlite:
            if sqlitePath.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("Choose a database file.")
            }
        case .bullmq:
            if host.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("Host is required.")
            }
            if let portNumber = Int(port), (1...65535).contains(portNumber) {
            } else {
                problems.append("Port must be a number between 1 and 65535.")
            }
            let dbText = database.trimmingCharacters(in: .whitespaces)
            if let dbNumber = Int(dbText.isEmpty ? "0" : dbText), (0...15).contains(dbNumber) {
            } else {
                problems.append("Database must be a Redis logical database between 0 and 15.")
            }
            if bullPrefix.range(of: #"^[A-Za-z0-9:_-]{1,64}$"#, options: .regularExpression) == nil {
                problems.append("Key prefix may only contain letters, digits, colons, underscores, and dashes.")
            }
        }
        return problems
    }

    // MARK: Actions

    private func chooseSQLiteFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a SQLite database file"
        if panel.runModal() == .OK, let url = panel.url {
            sqlitePath = url.path(percentEncoded: false)
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedDatabase = database.trimmingCharacters(in: .whitespaces)
        let input: ConnectionInput
        switch engine {
        case .postgresql:
            input = .postgres(.init(
                name: trimmedName, host: host, port: Int(port) ?? 5432,
                username: username, password: password, database: trimmedDatabase,
                sslMode: sslMode, environment: environment, readOnly: readOnly))
        case .mysql:
            input = .mysql(.init(
                name: trimmedName, host: host, port: Int(port) ?? 3306,
                username: username, password: password, database: trimmedDatabase,
                sslMode: sslMode, environment: environment, readOnly: readOnly))
        case .mongodb:
            input = .mongo(.init(
                name: trimmedName, uri: mongoURI.trimmingCharacters(in: .whitespaces),
                database: trimmedDatabase, tls: mongoTLS,
                environment: environment, readOnly: readOnly))
        case .sqlite:
            input = .sqlite(.init(
                name: trimmedName, filePath: sqlitePath,
                environment: environment, readOnly: readOnly))
        case .bullmq:
            let dbText = trimmedDatabase.isEmpty ? "0" : trimmedDatabase
            input = .bullmq(.init(
                name: trimmedName, host: host, port: Int(port) ?? 6379,
                password: password, database: Int(dbText) ?? 0,
                tls: bullTLS, prefix: bullPrefix.trimmingCharacters(in: .whitespaces),
                environment: environment, readOnly: readOnly))
        }
        isSubmitting = true
        addError = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                if let editing {
                    try await store.updateConnection(id: editing.id, input: input, remember: rememberConnection)
                } else {
                    try await store.addConnection(input)
                }
                dismiss()
            } catch {
                addError = SessionStore.redactedMessage(for: error)
            }
        }
    }
}


/// One engine card in the picker grid (reference `.engine-option`): monogram
/// chip, name, hint; the selected card takes the accent tint.
private struct EngineOptionCard: View {
    let engine: DatabaseEngine
    let isSelected: Bool
    let select: () -> Void

    private var hint: String {
        switch engine {
        case .postgresql: "SQL · server"
        case .mysql: "SQL · server"
        case .mongodb: "Documents"
        case .sqlite: "SQL · local file"
        case .bullmq: "Redis job queues"
        }
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                EngineBadge(engine: engine)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColors.text)
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textDisabled)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(minHeight: 58)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .fill(isSelected ? AppColors.accentSoft : AppColors.bgPanel))
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.cornerRadius)
                    .stroke(isSelected ? AppColors.accent : AppColors.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
