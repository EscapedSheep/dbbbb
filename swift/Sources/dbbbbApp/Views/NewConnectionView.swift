import SwiftUI
import AppKit
import dbbbbCore

/// New-connection sheet: one form per engine, with validation, an environment
/// picker, and a read-only toggle. Production connections get a visible warning.
struct NewConnectionView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

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
    @State private var environment: ConnectionEnvironment = .development
    @State private var readOnly = false
    @State private var addError: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    Spacer()
                    Picker("Engine", selection: $engine) {
                        ForEach(DatabaseEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: engine) { _, newEngine in
                        port = newEngine == .mysql ? "3306" : "5432"
                        addError = nil
                    }
                    Spacer()
                }

                Section("Connection") {
                    TextField("Name", text: $name, prompt: Text(engine.displayName))
                    switch engine {
                    case .postgresql, .mysql:
                        TextField("Host", text: $host)
                        TextField("Port", text: $port)
                        TextField("Username", text: $username)
                        SecureField("Password", text: $password)
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
                    }
                }

                Section("Options") {
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
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                    }
                }
                if let addError {
                    Section {
                        Label(addError, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
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
                    .keyboardShortcut(.cancelAction)
                Button("Add Connection") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!issues.isEmpty || isSubmitting)
            }
            .padding()
        }
        .frame(width: 480, height: 560)
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
        }
        isSubmitting = true
        addError = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await store.addConnection(input)
                dismiss()
            } catch {
                addError = SessionStore.redactedMessage(for: error)
            }
        }
    }
}
