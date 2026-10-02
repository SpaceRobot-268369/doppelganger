import Foundation
import GRDB

/// The indexed application catalog. Portable transfer evidence remains on
/// disk; this database makes it searchable and preserves local organization,
/// operator attribution, and audit history.
final class ProductDatabase: @unchecked Sendable {
    private let writer: DatabaseQueue

    init(path: String) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        writer = try DatabaseQueue(path: path, configuration: configuration)
        try migrate()
        try ensureDefaultProfile()
    }

    init(inMemory: Bool) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        writer = try DatabaseQueue(configuration: configuration)
        try migrate()
        try ensureDefaultProfile()
    }

    static func applicationDefault() throws -> ProductDatabase {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let root = base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lucastao.doppelganger", isDirectory: true)
            .appendingPathComponent("Catalog", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("doppelganger.sqlite")
        let backup = root.appendingPathComponent("doppelganger-before-migration.sqlite")
        if manager.fileExists(atPath: database.path), !manager.fileExists(atPath: backup.path) {
            try? manager.copyItem(at: database, to: backup)
        }
        return try ProductDatabase(path: database.path)
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("product-catalog-v1") { db in
            try db.execute(sql: """
                CREATE TABLE operator_profiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    avatar_kind TEXT NOT NULL,
                    avatar_color TEXT NOT NULL,
                    avatar_file_name TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    archived_at REAL
                );
                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    notes TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    archived_at REAL
                );
                CREATE TABLE destinations (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    path_hint TEXT NOT NULL,
                    volume_identifier TEXT,
                    role TEXT,
                    benchmark_bytes_per_second REAL,
                    benchmarked_at REAL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE destination_groups (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE destination_group_members (
                    group_id TEXT NOT NULL REFERENCES destination_groups(id) ON DELETE CASCADE,
                    destination_id TEXT NOT NULL REFERENCES destinations(id) ON DELETE RESTRICT,
                    sort_order INTEGER NOT NULL,
                    PRIMARY KEY (group_id, destination_id)
                );
                CREATE TABLE presets (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    version INTEGER NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE transfer_tasks (
                    id TEXT PRIMARY KEY NOT NULL,
                    label TEXT NOT NULL,
                    source_path TEXT NOT NULL,
                    destination_paths_json TEXT NOT NULL,
                    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    created_by_profile_id TEXT NOT NULL REFERENCES operator_profiles(id) ON DELETE RESTRICT,
                    created_by_name TEXT NOT NULL,
                    checksum_algorithm TEXT NOT NULL,
                    verification_profile TEXT NOT NULL,
                    lifecycle TEXT NOT NULL,
                    verdict TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE transfer_attempts (
                    id TEXT PRIMARY KEY NOT NULL,
                    task_id TEXT NOT NULL REFERENCES transfer_tasks(id) ON DELETE RESTRICT,
                    parent_attempt_id TEXT REFERENCES transfer_attempts(id) ON DELETE RESTRICT,
                    kind TEXT NOT NULL,
                    initiated_by_profile_id TEXT NOT NULL REFERENCES operator_profiles(id) ON DELETE RESTRICT,
                    initiated_by_name TEXT NOT NULL,
                    checksum_algorithm TEXT NOT NULL,
                    verification_profile TEXT NOT NULL,
                    lifecycle TEXT NOT NULL,
                    verdict TEXT NOT NULL,
                    started_at REAL,
                    finished_at REAL,
                    issues_json TEXT NOT NULL DEFAULT '[]'
                );
                CREATE TABLE audit_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    task_id TEXT REFERENCES transfer_tasks(id) ON DELETE RESTRICT,
                    attempt_id TEXT REFERENCES transfer_attempts(id) ON DELETE RESTRICT,
                    actor_kind TEXT NOT NULL,
                    operator_profile_id TEXT REFERENCES operator_profiles(id) ON DELETE RESTRICT,
                    operator_display_name TEXT,
                    action TEXT NOT NULL,
                    occurred_at REAL NOT NULL,
                    detail TEXT
                );
                CREATE TABLE file_records (
                    attempt_id TEXT NOT NULL REFERENCES transfer_attempts(id) ON DELETE RESTRICT,
                    relative_path TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    digest TEXT,
                    outcomes_json TEXT NOT NULL,
                    PRIMARY KEY (attempt_id, relative_path)
                );
                CREATE TABLE evidence_artifacts (
                    id TEXT PRIMARY KEY NOT NULL,
                    attempt_id TEXT NOT NULL REFERENCES transfer_attempts(id) ON DELETE RESTRICT,
                    kind TEXT NOT NULL,
                    path TEXT NOT NULL,
                    required INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    warning TEXT
                );
                CREATE TABLE health_findings (
                    id TEXT PRIMARY KEY NOT NULL,
                    task_id TEXT NOT NULL REFERENCES transfer_tasks(id) ON DELETE RESTRICT,
                    severity TEXT NOT NULL,
                    code TEXT NOT NULL,
                    message TEXT NOT NULL,
                    relative_path TEXT
                );
                CREATE TABLE imported_manifests (
                    canonical_path TEXT PRIMARY KEY NOT NULL,
                    transfer_id TEXT NOT NULL,
                    schema_version INTEGER NOT NULL,
                    modified_at REAL NOT NULL,
                    imported_at REAL NOT NULL
                );
                CREATE INDEX task_project_created_idx ON transfer_tasks(project_id, created_at DESC);
                CREATE INDEX task_operator_created_idx ON transfer_tasks(created_by_profile_id, created_at DESC);
                CREATE INDEX attempt_task_idx ON transfer_attempts(task_id, started_at DESC);
                CREATE INDEX audit_task_time_idx ON audit_events(task_id, occurred_at DESC);
                CREATE INDEX file_digest_idx ON file_records(digest, size);
                """)
        }
        migrator.registerMigration("source-identity-v2") { db in
            try db.alter(table: "transfer_tasks") { table in
                table.add(column: "source_fingerprint", .text)
                table.add(column: "source_volume_identifier", .text)
                table.add(column: "source_volume_name", .text)
            }
            try db.create(
                index: "task_source_fingerprint_idx",
                on: "transfer_tasks",
                columns: ["source_fingerprint", "created_at"]
            )
        }
        migrator.registerMigration("task-organization-v3") { db in
            try db.alter(table: "transfer_tasks") { table in
                table.add(column: "shooting_day", .text)
                table.add(column: "camera_label", .text)
                table.add(column: "card_label", .text)
            }
            try db.create(
                index: "task_organization_idx",
                on: "transfer_tasks",
                columns: ["project_id", "shooting_day", "camera_label", "card_label", "created_at"]
            )
        }
        migrator.registerMigration("project-production-details-v4") { db in
            try db.alter(table: "projects") { table in
                table.add(column: "production_company", .text).notNull().defaults(to: "")
                table.add(column: "shoot_location", .text).notNull().defaults(to: "")
                table.add(column: "shoot_start_date", .double)
                table.add(column: "shoot_end_date", .double)
            }
        }
        migrator.registerMigration("project-cameras-v5") { db in
            try db.execute(sql: """
                CREATE TABLE cameras (
                    id TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL,
                    reel_prefix TEXT NOT NULL,
                    name TEXT NOT NULL DEFAULT '',
                    make TEXT NOT NULL DEFAULT '',
                    model TEXT NOT NULL DEFAULT '',
                    notes TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    archived_at REAL
                );
                CREATE INDEX camera_project_idx ON cameras (project_id, reel_prefix);
                """)
        }
        try migrator.migrate(writer)
    }

    // MARK: - Profiles

    private func ensureDefaultProfile() throws {
        try writer.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operator_profiles") ?? 0
            guard count == 0 else { return }
            let profile = OperatorProfile(displayName: "Local Operator")
            try Self.insert(profile, db: db)
            try db.execute(
                sql: "INSERT INTO app_state (key, value) VALUES (?, ?)",
                arguments: ["activeProfileID", profile.id.uuidString.lowercased()]
            )
        }
    }

    func profiles(includeArchived: Bool = false) throws -> [OperatorProfile] {
        try writer.read { db in
            let whereClause = includeArchived ? "" : "WHERE archived_at IS NULL"
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM operator_profiles \(whereClause) ORDER BY display_name COLLATE NOCASE"
            )
            return rows.compactMap(Self.profile(from:))
        }
    }

    func activeProfile() throws -> OperatorProfile {
        try writer.read { db in
            let activeID = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = ?",
                arguments: ["activeProfileID"]
            )
            if let activeID,
               let row = try Row.fetchOne(
                   db,
                   sql: "SELECT * FROM operator_profiles WHERE id = ? AND archived_at IS NULL",
                   arguments: [activeID]
               ), let profile = Self.profile(from: row) {
                return profile
            }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM operator_profiles WHERE archived_at IS NULL ORDER BY created_at LIMIT 1"
            ), let profile = Self.profile(from: row) else {
                throw DatabaseError(message: L10n.text("No active operator profile is available"))
            }
            return profile
        }
    }

    func saveProfile(_ profile: OperatorProfile) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO operator_profiles
                    (id, display_name, avatar_kind, avatar_color, avatar_file_name, created_at, updated_at, archived_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    avatar_kind = excluded.avatar_kind,
                    avatar_color = excluded.avatar_color,
                    avatar_file_name = excluded.avatar_file_name,
                    updated_at = excluded.updated_at,
                    archived_at = excluded.archived_at
                """, arguments: Self.profileArguments(profile))
        }
    }

    func setActiveProfile(id: UUID) throws {
        try writer.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM operator_profiles WHERE id = ? AND archived_at IS NULL)",
                arguments: [id.uuidString.lowercased()]
            ) ?? false
            guard exists else {
                throw DatabaseError(message: L10n.text("The selected profile is archived or missing"))
            }
            try db.execute(sql: """
                INSERT INTO app_state (key, value) VALUES ('activeProfileID', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [id.uuidString.lowercased()])
        }
    }

    func archiveProfile(id: UUID) throws {
        try writer.write { db in
            let activeCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM operator_profiles WHERE archived_at IS NULL"
            ) ?? 0
            guard activeCount > 1 else {
                throw DatabaseError(message: L10n.text("At least one operator profile must remain active"))
            }
            try db.execute(
                sql: "UPDATE operator_profiles SET archived_at = ?, updated_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, Date().timeIntervalSince1970, id.uuidString.lowercased()]
            )
            let selected = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = 'activeProfileID'"
            )
            if selected == id.uuidString.lowercased(),
               let replacement = try String.fetchOne(
                   db,
                   sql: "SELECT id FROM operator_profiles WHERE archived_at IS NULL ORDER BY created_at LIMIT 1"
               ) {
                try db.execute(
                    sql: "UPDATE app_state SET value = ? WHERE key = 'activeProfileID'",
                    arguments: [replacement]
                )
            }
        }
    }

    // MARK: - Projects

    func projects(includeArchived: Bool = false) throws -> [ProjectRecord] {
        try writer.read { db in
            let whereClause = includeArchived ? "" : "WHERE archived_at IS NULL"
            return try Row.fetchAll(
                db,
                sql: "SELECT * FROM projects \(whereClause) ORDER BY name COLLATE NOCASE"
            ).compactMap(Self.project(from:))
        }
    }

    func saveProject(_ project: ProjectRecord) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO projects
                    (id, name, notes, production_company, shoot_location,
                     shoot_start_date, shoot_end_date, created_at, archived_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    notes = excluded.notes,
                    production_company = excluded.production_company,
                    shoot_location = excluded.shoot_location,
                    shoot_start_date = excluded.shoot_start_date,
                    shoot_end_date = excluded.shoot_end_date,
                    archived_at = excluded.archived_at
                """, arguments: [
                    project.id.uuidString.lowercased(), project.name, project.notes,
                    project.productionCompany, project.shootLocation,
                    project.shootStartDate?.timeIntervalSince1970,
                    project.shootEndDate?.timeIntervalSince1970,
                    project.createdAt.timeIntervalSince1970,
                    project.archivedAt?.timeIntervalSince1970
                ])
        }
    }

    // MARK: - Cameras

    func cameras(includeArchived: Bool = false) throws -> [CameraRecord] {
        try writer.read { db in
            let whereClause = includeArchived ? "" : "WHERE archived_at IS NULL"
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM cameras \(whereClause)
                    ORDER BY reel_prefix COLLATE NOCASE, name COLLATE NOCASE
                    """
            ).compactMap(Self.camera(from:))
        }
    }

    func saveCamera(_ camera: CameraRecord) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO cameras
                    (id, project_id, reel_prefix, name, make, model, notes, created_at, archived_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    project_id = excluded.project_id,
                    reel_prefix = excluded.reel_prefix,
                    name = excluded.name,
                    make = excluded.make,
                    model = excluded.model,
                    notes = excluded.notes,
                    archived_at = excluded.archived_at
                """, arguments: [
                    camera.id.uuidString.lowercased(),
                    camera.projectID.uuidString.lowercased(),
                    camera.reelPrefix, camera.name, camera.make, camera.model, camera.notes,
                    camera.createdAt.timeIntervalSince1970,
                    camera.archivedAt?.timeIntervalSince1970
                ])
        }
    }

    /// Cameras are catalog metadata, so retiring one is a soft archive. Past
    /// transfers keep the camera and reel labels they were recorded with.
    func archiveCamera(id: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE cameras SET archived_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, id.uuidString.lowercased()]
            )
        }
    }

    // MARK: - Task and audit history

    func taskHistory() throws -> [TaskHistoryRecord] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.*, p.name AS project_name,
                    COALESCE((
                        SELECT GROUP_CONCAT(a.kind || ' ' || a.verdict || ' ' || a.issues_json, ' ')
                        FROM transfer_attempts a WHERE a.task_id = t.id
                    ), '') AS attempt_search_text,
                    COALESCE((
                        SELECT GROUP_CONCAT(e.kind || ' ' || e.status || ' ' || e.path || ' ' || COALESCE(e.warning, ''), ' ')
                        FROM evidence_artifacts e
                        JOIN transfer_attempts a ON a.id = e.attempt_id
                        WHERE a.task_id = t.id
                    ), '') AS evidence_search_text
                FROM transfer_tasks t
                LEFT JOIN projects p ON p.id = t.project_id
                ORDER BY t.created_at DESC
                """).compactMap(Self.taskHistory(from:))
        }
    }

    func registerTask(
        id: UUID,
        label: String,
        source: URL,
        destinations: [URL],
        projectID: UUID?,
        sourceFingerprint: String? = nil,
        sourceVolumeIdentifier: String? = nil,
        sourceVolumeName: String? = nil,
        operatorProfile: OperatorProfile,
        algorithm: ChecksumAlgorithm,
        verificationProfile: VerificationProfile,
        createdAt: Date = Date()
    ) throws {
        let paths = destinations.map(\.path)
        let encodedPaths = try String(
            decoding: JSONEncoder().encode(paths),
            as: UTF8.self
        )
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO transfer_tasks
                    (id, label, source_path, destination_paths_json, project_id,
                     source_fingerprint, source_volume_identifier, source_volume_name,
                     created_by_profile_id, created_by_name, checksum_algorithm,
                     verification_profile, lifecycle, verdict, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id.uuidString.lowercased(), label, source.path, encodedPaths,
                    projectID?.uuidString.lowercased(), sourceFingerprint,
                    sourceVolumeIdentifier, sourceVolumeName,
                    operatorProfile.id.uuidString.lowercased(),
                    operatorProfile.displayName, algorithm.rawValue, verificationProfile.rawValue,
                    TaskLifecycle.queued.rawValue, TransferVerdict.pending.rawValue,
                    createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970
                ])
            try Self.insertAudit(
                AuditEventRecord(
                    taskID: id,
                    actorKind: .operatorProfile,
                    operatorSnapshot: OperatorSnapshot(profile: operatorProfile),
                    action: .taskCreated,
                    occurredAt: createdAt
                ),
                db: db
            )
        }
    }

    func registerAttempt(
        id: UUID,
        taskID: UUID,
        parentAttemptID: UUID? = nil,
        kind: TransferAttemptKind,
        operatorProfile: OperatorProfile,
        algorithm: ChecksumAlgorithm,
        verificationProfile: VerificationProfile,
        startedAt: Date = Date()
    ) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO transfer_attempts
                    (id, task_id, parent_attempt_id, kind, initiated_by_profile_id,
                     initiated_by_name, checksum_algorithm, verification_profile,
                     lifecycle, verdict, started_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id.uuidString.lowercased(), taskID.uuidString.lowercased(),
                    parentAttemptID?.uuidString.lowercased(), kind.rawValue,
                    operatorProfile.id.uuidString.lowercased(), operatorProfile.displayName,
                    algorithm.rawValue, verificationProfile.rawValue,
                    TaskLifecycle.copying.rawValue, TransferVerdict.pending.rawValue,
                    startedAt.timeIntervalSince1970
                ])
            try db.execute(
                sql: "UPDATE transfer_tasks SET lifecycle = ?, updated_at = ? WHERE id = ?",
                arguments: [TaskLifecycle.copying.rawValue, startedAt.timeIntervalSince1970, taskID.uuidString.lowercased()]
            )
            let auditAction: AuditAction = switch kind {
            case .copy: .taskStarted
            case .resume: .taskResumed
            case .retry: .retryCreated
            case .verification: .verificationCreated
            case .cascade: .cascadeCreated
            case .contactSheet: .contactSheetCreated
            }
            try Self.insertAudit(
                AuditEventRecord(
                    taskID: taskID,
                    attemptID: id,
                    actorKind: .operatorProfile,
                    operatorSnapshot: OperatorSnapshot(profile: operatorProfile),
                    action: auditAction,
                    occurredAt: startedAt
                ),
                db: db
            )
        }
    }

    func finishAttempt(
        id: UUID,
        taskID: UUID,
        report: TransferReport,
        verificationProfile: VerificationProfile
    ) throws {
        let verdict: TransferVerdict = switch report.status {
        case .paused: .paused
        case .transferredPendingVerification: .transferredPendingVerification
        case .verified: .verified
        case .failed: .failed
        case .cancelled: .cancelled
        }
        let lifecycle: TaskLifecycle = switch verdict {
        case .paused: .paused
        case .transferredPendingVerification: .transferredPendingVerification
        case .verified: .complete
        case .failed, .needsAttention: .failed
        case .cancelled: .cancelled
        case .pending: .complete
        }
        let encoder = JSONEncoder()
        let issues = try String(decoding: encoder.encode(report.issues), as: UTF8.self)
        let manifest = TransferManifest(report: report)
        let fileRows = try manifest.items.map { item in
            (
                item.relativePath,
                item.size,
                item.digest,
                String(decoding: try encoder.encode(item.results), as: UTF8.self)
            )
        }
        var evidence: [(UUID, String, String, Bool, String, String?)] = []
        for location in report.manifestLocations {
            evidence.append((
                UUID(), "json-manifest",
                location.appendingPathComponent(ManifestWriter.manifestFileName(shortID: report.shortID)).path,
                true, "written", nil
            ))
            evidence.append((
                UUID(), "markdown-report",
                location.appendingPathComponent(ManifestWriter.reportFileName(shortID: report.shortID)).path,
                true, "written", nil
            ))
        }
        for destination in report.destinations {
            let chain = destination
                .appendingPathComponent(MHLWriter.directoryName, isDirectory: true)
                .appendingPathComponent(MHLWriter.chainFileName)
            if FileManager.default.fileExists(atPath: chain.path) {
                evidence.append((UUID(), "asc-mhl-chain", chain.path, true, "written", nil))
            }
        }
        try writer.write { db in
            try db.execute(sql: """
                UPDATE transfer_attempts
                SET lifecycle = ?, verdict = ?, finished_at = ?, issues_json = ?
                WHERE id = ?
                """, arguments: [
                    lifecycle.rawValue, verdict.rawValue, report.finishedAt.timeIntervalSince1970,
                    issues, id.uuidString.lowercased()
                ])
            try db.execute(sql: """
                UPDATE transfer_tasks SET lifecycle = ?, verdict = ?, updated_at = ? WHERE id = ?
                """, arguments: [
                    lifecycle.rawValue, verdict.rawValue, report.finishedAt.timeIntervalSince1970,
                    taskID.uuidString.lowercased()
                ])
            for row in fileRows {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO file_records
                        (attempt_id, relative_path, size, digest, outcomes_json)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [
                        id.uuidString.lowercased(), row.0, row.1, row.2, row.3
                    ])
            }
            for artifact in evidence {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO evidence_artifacts
                        (id, attempt_id, kind, path, required, status, warning)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        artifact.0.uuidString.lowercased(), id.uuidString.lowercased(),
                        artifact.1, artifact.2, artifact.3, artifact.4, artifact.5
                    ])
            }
            try Self.insertAudit(
                AuditEventRecord(
                    taskID: taskID,
                    attemptID: id,
                    actorKind: .system,
                    action: report.status == .paused
                        ? .taskPaused
                        : report.status == .verified || report.status == .transferredPendingVerification
                            ? .attemptCompleted : .attemptFailed,
                    occurredAt: report.finishedAt,
                    detail: report.issues.first
                ),
                db: db
            )
        }
    }

    func recordAudit(_ event: AuditEventRecord) throws {
        try writer.write { db in try Self.insertAudit(event, db: db) }
    }

    func attemptHistory(taskID: UUID) throws -> [AttemptHistoryRecord] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.*, COUNT(f.relative_path) AS file_count
                FROM transfer_attempts a
                LEFT JOIN file_records f ON f.attempt_id = a.id
                WHERE a.task_id = ?
                GROUP BY a.id
                ORDER BY COALESCE(a.started_at, 0) DESC
                """, arguments: [taskID.uuidString.lowercased()])
                .compactMap(Self.attemptHistory(from:))
        }
    }

    func evidenceArtifacts(taskID: UUID) throws -> [EvidenceArtifactHistoryRecord] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.* FROM evidence_artifacts e
                JOIN transfer_attempts a ON a.id = e.attempt_id
                WHERE a.task_id = ?
                ORDER BY e.path COLLATE NOCASE
                """, arguments: [taskID.uuidString.lowercased()])
                .compactMap(Self.evidenceArtifact(from:))
        }
    }

    /// Idempotently indexes portable manifests left by earlier app versions.
    /// The importer is read-only with respect to the spool and its evidence.
    /// The catalog's own record wins: a manifest whose attempt the catalog
    /// already finished is only remembered, and one whose attempt is still
    /// open is skipped — launch reconciliation closes that attempt as failed,
    /// never from a manifest it may not own.
    func importSpoolManifests(at root: URL, fallbackProfile: OperatorProfile) throws {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let decoder = JSONDecoder()
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("doppelganger-manifest-"),
                  url.pathExtension.lowercased() == "json",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url),
                  let manifest = try? decoder.decode(TransferManifest.self, from: data),
                  let transferID = UUID(uuidString: manifest.transferID),
                  let algorithm = Self.algorithm(fromManifestValue: manifest.algorithm)
            else { continue }

            let taskID = manifest.taskID.flatMap(UUID.init(uuidString:)) ?? transferID
            let attemptID = manifest.attemptID.flatMap(UUID.init(uuidString:)) ?? transferID
            let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let alreadyImported = try writer.read { db in
                let prior: Double? = try Double.fetchOne(
                    db,
                    sql: "SELECT modified_at FROM imported_manifests WHERE canonical_path = ?",
                    arguments: [canonicalPath]
                )
                return prior == modifiedAt.timeIntervalSince1970
            }
            if alreadyImported { continue }

            let startedAt = (try? Date(manifest.startedAt, strategy: iso)) ?? modifiedAt
            let finishedAt = (try? Date(manifest.finishedAt, strategy: iso)) ?? modifiedAt
            let verdict = TransferVerdict(rawValue: manifest.status) ?? .failed
            let lifecycle: TaskLifecycle = switch verdict {
            case .pending: .queued
            case .paused: .paused
            case .transferredPendingVerification: .transferredPendingVerification
            case .verified: .complete
            case .needsAttention, .failed: .failed
            case .cancelled: .cancelled
            }
            let verificationProfile = VerificationProfile(
                rawValue: manifest.verificationProfile ?? ""
            ) ?? .standard
            let operatorName = manifest.operatorDisplayName ?? fallbackProfile.displayName
            let destinationPaths = manifest.destinations.map(\.path)
            let encodedDestinations = String(
                decoding: try JSONEncoder().encode(destinationPaths),
                as: UTF8.self
            )
            let issuesJSON = String(
                decoding: try JSONEncoder().encode(manifest.issues ?? []),
                as: UTF8.self
            )
            let projectID: String? = try writer.read { db in
                guard let value = manifest.projectID else { return nil }
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM projects WHERE id = ?)",
                    arguments: [value]
                ) ?? false
                return exists ? value : nil
            }

            try writer.write { db in
                switch try Self.catalogState(ofAttempt: attemptID, db: db) {
                case .open:
                    // Never reached a terminal report: this file is uncommitted
                    // evidence (journal recovery removes it). Write nothing,
                    // not even bookkeeping.
                    return
                case .finished:
                    // finishAttempt already cataloged the files, evidence, and
                    // the one terminal event. Only remember the file.
                    try Self.recordImportedManifest(
                        canonicalPath: canonicalPath,
                        transferID: manifest.transferID,
                        schemaVersion: manifest.schemaVersion,
                        modifiedAt: modifiedAt,
                        db: db
                    )
                    return
                case .absent:
                    break // A manifest the catalog has never seen: import it.
                }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO transfer_tasks
                        (id, label, source_path, destination_paths_json, project_id,
                         source_fingerprint, created_by_profile_id, created_by_name,
                         checksum_algorithm, verification_profile, lifecycle, verdict,
                         created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        taskID.uuidString.lowercased(),
                        URL(fileURLWithPath: manifest.sourceRoot).lastPathComponent,
                        manifest.sourceRoot, encodedDestinations, projectID,
                        manifest.sourceFingerprint,
                        fallbackProfile.id.uuidString.lowercased(), operatorName,
                        algorithm.rawValue, verificationProfile.rawValue,
                        lifecycle.rawValue, verdict.rawValue,
                        startedAt.timeIntervalSince1970, finishedAt.timeIntervalSince1970
                    ])
                try db.execute(sql: """
                    INSERT OR IGNORE INTO transfer_attempts
                        (id, task_id, kind, initiated_by_profile_id, initiated_by_name,
                         checksum_algorithm, verification_profile, lifecycle, verdict,
                         started_at, finished_at, issues_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        attemptID.uuidString.lowercased(), taskID.uuidString.lowercased(),
                        TransferAttemptKind.copy.rawValue,
                        fallbackProfile.id.uuidString.lowercased(), operatorName,
                        algorithm.rawValue, verificationProfile.rawValue,
                        lifecycle.rawValue, verdict.rawValue,
                        startedAt.timeIntervalSince1970, finishedAt.timeIntervalSince1970,
                        issuesJSON
                    ])
                for item in manifest.items {
                    let resultsJSON = String(
                        decoding: try JSONEncoder().encode(item.results),
                        as: UTF8.self
                    )
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO file_records
                            (attempt_id, relative_path, size, digest, outcomes_json)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [
                            attemptID.uuidString.lowercased(), item.relativePath,
                            item.size, item.digest, resultsJSON
                        ])
                }

                try Self.insertEvidenceIfMissing(
                    attemptID: attemptID,
                    kind: "json-manifest",
                    path: canonicalPath,
                    required: true,
                    db: db
                )
                let reportPath = url.deletingLastPathComponent()
                    .appendingPathComponent(
                        ManifestWriter.reportFileName(
                            shortID: String(attemptID.uuidString.prefix(8)).lowercased()
                        )
                    ).path
                if manager.fileExists(atPath: reportPath) {
                    try Self.insertEvidenceIfMissing(
                        attemptID: attemptID,
                        kind: "markdown-report",
                        path: reportPath,
                        required: true,
                        db: db
                    )
                }
                try Self.insertAudit(
                    AuditEventRecord(
                        taskID: taskID,
                        attemptID: attemptID,
                        actorKind: .system,
                        action: Self.terminalAuditAction(for: verdict),
                        occurredAt: finishedAt,
                        detail: "Imported existing spool manifest"
                    ),
                    db: db
                )
                try Self.recordImportedManifest(
                    canonicalPath: canonicalPath,
                    transferID: manifest.transferID,
                    schemaVersion: manifest.schemaVersion,
                    modifiedAt: modifiedAt,
                    db: db
                )
            }
        }
    }

    // MARK: - Abandoned runs

    /// Stored on an attempt that was still open when the app launched. It is
    /// provenance, not display text, so — like the engine's own issues — it is
    /// not localized. It repeats the recovered dashboard card's wording.
    static let abandonedAttemptIssue = "The app exited before this transfer produced a terminal report. Treat every output as incomplete and keep the source media."
    /// Audit detail for a queued task the app left behind before any attempt.
    /// Worded from the catalog's side: it never claims nothing was copied.
    static let neverStartedTaskDetail = "Closed at launch: the app quit before this queued transfer recorded an attempt."
    /// Audit detail for a queued task the operator withdrew.
    static let withdrawnTaskDetail = "Withdrawn from the queue before it started."

    struct AbandonedRuns: Equatable, Sendable {
        var failedAttemptIDs: [UUID] = []
        var cancelledTaskIDs: [UUID] = []
    }

    /// Launch reconciliation: closes what no process can still be running.
    ///
    /// Call once per launch, before this launch starts any attempt.
    /// - An attempt registered at or before `launchedAt` that never finished
    ///   was abandoned by an earlier process (crash, force quit, Quit Anyway).
    ///   It is closed through `finishAttempt` as failed, so the task aggregate
    ///   settles exactly as for any other failed attempt. It is never closed
    ///   as anything else: nothing it left behind is evidence.
    /// - A task registered at or before `launchedAt` that is still queued and
    ///   never started an attempt is closed as cancelled.
    /// Finished attempts and tasks that have moved on are never touched, so a
    /// second run changes nothing. A row that fails to close stays open (never
    /// read as success) and is retried at the next launch.
    @discardableResult
    func closeAbandonedRuns(before launchedAt: Date, closedAt: Date = Date()) throws -> AbandonedRuns {
        struct OpenAttempt: Sendable {
            let id: UUID
            let taskID: UUID
            let algorithm: ChecksumAlgorithm
            let profile: VerificationProfile
            let sourcePath: String
            let startedAt: Date
        }
        let bound = launchedAt.timeIntervalSince1970
        let open: [OpenAttempt] = try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.task_id, a.checksum_algorithm, a.verification_profile,
                       a.started_at, t.source_path
                FROM transfer_attempts a
                JOIN transfer_tasks t ON t.id = a.task_id
                WHERE a.finished_at IS NULL AND COALESCE(a.started_at, 0) <= ?
                ORDER BY COALESCE(a.started_at, 0), a.rowid
                """, arguments: [bound]).compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let taskID = UUID(uuidString: row["task_id"])
                else { return nil }
                let started: Double? = row["started_at"]
                return OpenAttempt(
                    id: id,
                    taskID: taskID,
                    // Only shapes the in-memory report: finishAttempt never
                    // persists a report's algorithm or profile.
                    algorithm: Self.algorithm(fromManifestValue: row["checksum_algorithm"]) ?? .xxh3,
                    profile: VerificationProfile(rawValue: row["verification_profile"]) ?? .standard,
                    sourcePath: row["source_path"],
                    startedAt: started.map(Date.init(timeIntervalSince1970:)) ?? closedAt
                )
            }
        }

        var closed = AbandonedRuns()
        var firstError: (any Error)?
        for attempt in open {
            let report = TransferReport(
                id: attempt.id,
                status: .failed,
                algorithm: attempt.algorithm,
                verificationProfile: attempt.profile,
                taskID: attempt.taskID,
                sourceRoot: URL(fileURLWithPath: attempt.sourcePath, isDirectory: true),
                // No destinations, items, or manifest locations: an abandoned
                // attempt committed no evidence, so finishAttempt records no
                // file results and probes no destination MHL chain on its
                // behalf (recovery may already have rolled that chain back).
                destinations: [],
                startedAt: attempt.startedAt,
                finishedAt: closedAt,
                items: [],
                manifestLocations: [],
                issues: [Self.abandonedAttemptIssue]
            )
            do {
                try finishAttempt(
                    id: attempt.id,
                    taskID: attempt.taskID,
                    report: report,
                    verificationProfile: attempt.profile
                )
                closed.failedAttemptIDs.append(attempt.id)
            } catch {
                firstError = firstError ?? error
            }
        }

        do {
            closed.cancelledTaskIDs = try writer.write { db in
                let keys = try String.fetchAll(db, sql: """
                    SELECT t.id FROM transfer_tasks t
                    WHERE t.lifecycle = ? AND t.verdict = ? AND t.created_at <= ?
                      AND NOT EXISTS (SELECT 1 FROM transfer_attempts a WHERE a.task_id = t.id)
                    ORDER BY t.created_at
                    """, arguments: [
                        TaskLifecycle.queued.rawValue, TransferVerdict.pending.rawValue, bound,
                    ])
                var cancelled: [UUID] = []
                for key in keys {
                    let didCancel = try Self.cancelNeverStartedTask(
                        key: key,
                        actorKind: .system,
                        operatorSnapshot: nil,
                        detail: Self.neverStartedTaskDetail,
                        at: closedAt,
                        db: db
                    )
                    if didCancel, let id = UUID(uuidString: key) { cancelled.append(id) }
                }
                return cancelled
            }
        } catch {
            firstError = firstError ?? error
        }
        if let firstError { throw firstError }
        return closed
    }

    /// The operator took a queued transfer out of line before it started. Only
    /// a task that is still queued, pending, and attempt-free is closed; a
    /// queued resume or retry belongs to a task with earlier attempts, which
    /// this never touches.
    @discardableResult
    func withdrawQueuedTask(
        id: UUID,
        operatorProfile: OperatorProfile,
        at date: Date = Date()
    ) throws -> Bool {
        try writer.write { db in
            try Self.cancelNeverStartedTask(
                key: id.uuidString.lowercased(),
                actorKind: .operatorProfile,
                operatorSnapshot: OperatorSnapshot(profile: operatorProfile),
                detail: Self.withdrawnTaskDetail,
                at: date,
                db: db
            )
        }
    }

    /// Updates only the searchable local catalog. Portable manifests and
    /// destination evidence remain byte-for-byte unchanged.
    func updateTaskOrganization(
        taskID: UUID,
        projectID: UUID?,
        shootingDay: String?,
        cameraLabel: String?,
        cardLabel: String?,
        operatorProfile: OperatorProfile,
        updatedAt: Date = Date()
    ) throws {
        func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let day = normalized(shootingDay)
        let camera = normalized(cameraLabel)
        let card = normalized(cardLabel)
        try writer.write { db in
            if let projectID {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM projects WHERE id = ? AND archived_at IS NULL)",
                    arguments: [projectID.uuidString.lowercased()]
                ) ?? false
                guard exists else {
                    throw DatabaseError(message: L10n.text("The selected project is missing or archived"))
                }
            }
            try db.execute(sql: """
                UPDATE transfer_tasks
                SET project_id = ?, shooting_day = ?, camera_label = ?, card_label = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [
                    projectID?.uuidString.lowercased(), day, camera, card,
                    updatedAt.timeIntervalSince1970, taskID.uuidString.lowercased()
                ])
            guard db.changesCount == 1 else {
                throw DatabaseError(message: L10n.text("The transfer task could not be found"))
            }
            let detail = [
                "project=\(projectID?.uuidString.lowercased() ?? "none")",
                "shootingDay=\(day ?? "none")",
                "camera=\(camera ?? "none")",
                "card=\(card ?? "none")"
            ].joined(separator: "; ")
            try Self.insertAudit(
                AuditEventRecord(
                    taskID: taskID,
                    actorKind: .operatorProfile,
                    operatorSnapshot: OperatorSnapshot(profile: operatorProfile),
                    action: .taskOrganizationChanged,
                    occurredAt: updatedAt,
                    detail: detail
                ),
                db: db
            )
        }
    }

    func auditEvents(taskID: UUID? = nil) throws -> [AuditEventRecord] {
        try writer.read { db in
            let rows: [Row]
            if let taskID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM audit_events WHERE task_id = ? ORDER BY occurred_at DESC",
                    arguments: [taskID.uuidString.lowercased()]
                )
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM audit_events ORDER BY occurred_at DESC")
            }
            return rows.compactMap(Self.audit(from:))
        }
    }

    // MARK: - Row conversion

    private static func insert(_ profile: OperatorProfile, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO operator_profiles
                (id, display_name, avatar_kind, avatar_color, avatar_file_name, created_at, updated_at, archived_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: profileArguments(profile))
    }

    private static func profileArguments(_ profile: OperatorProfile) -> StatementArguments {
        [
            profile.id.uuidString.lowercased(), profile.displayName,
            profile.avatar.kind.rawValue, profile.avatar.colorHex,
            profile.avatar.imageFileName, profile.createdAt.timeIntervalSince1970,
            profile.updatedAt.timeIntervalSince1970,
            profile.archivedAt?.timeIntervalSince1970
        ]
    }

    private static func profile(from row: Row) -> OperatorProfile? {
        guard let id = UUID(uuidString: row["id"]),
              let kind = OperatorAvatarKind(rawValue: row["avatar_kind"])
        else { return nil }
        let archived: Double? = row["archived_at"]
        return OperatorProfile(
            id: id,
            displayName: row["display_name"],
            avatar: OperatorAvatar(
                kind: kind,
                colorHex: row["avatar_color"],
                imageFileName: row["avatar_file_name"]
            ),
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            archivedAt: archived.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func project(from row: Row) -> ProjectRecord? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let archived: Double? = row["archived_at"]
        let shootStart: Double? = row["shoot_start_date"]
        let shootEnd: Double? = row["shoot_end_date"]
        return ProjectRecord(
            id: id,
            name: row["name"],
            notes: row["notes"],
            productionCompany: row["production_company"],
            shootLocation: row["shoot_location"],
            shootStartDate: shootStart.map(Date.init(timeIntervalSince1970:)),
            shootEndDate: shootEnd.map(Date.init(timeIntervalSince1970:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            archivedAt: archived.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func camera(from row: Row) -> CameraRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let projectID = UUID(uuidString: row["project_id"])
        else { return nil }
        let archived: Double? = row["archived_at"]
        return CameraRecord(
            id: id,
            projectID: projectID,
            reelPrefix: row["reel_prefix"],
            name: row["name"],
            make: row["make"],
            model: row["model"],
            notes: row["notes"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            archivedAt: archived.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func taskHistory(from row: Row) -> TaskHistoryRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let operatorID = UUID(uuidString: row["created_by_profile_id"]),
              let algorithm = ChecksumAlgorithm(rawValue: row["checksum_algorithm"]),
              let profile = VerificationProfile(rawValue: row["verification_profile"]),
              let lifecycle = TaskLifecycle(rawValue: row["lifecycle"]),
              let verdict = TransferVerdict(rawValue: row["verdict"])
        else { return nil }
        let pathsJSON: String = row["destination_paths_json"]
        let paths = (try? JSONDecoder().decode([String].self, from: Data(pathsJSON.utf8))) ?? []
        let projectIDString: String? = row["project_id"]
        let projectName: String? = row["project_name"]
        return TaskHistoryRecord(
            id: id,
            label: row["label"],
            sourcePath: row["source_path"],
            sourceFingerprint: row["source_fingerprint"],
            sourceVolumeIdentifier: row["source_volume_identifier"],
            sourceVolumeName: row["source_volume_name"],
            destinationPaths: paths,
            projectID: projectIDString.flatMap(UUID.init(uuidString:)),
            projectName: projectName,
            shootingDay: row["shooting_day"],
            cameraLabel: row["camera_label"],
            cardLabel: row["card_label"],
            searchableAttemptText: row["attempt_search_text"],
            searchableEvidenceText: row["evidence_search_text"],
            operatorSnapshot: OperatorSnapshot(
                profileID: operatorID,
                displayName: row["created_by_name"]
            ),
            algorithm: algorithm,
            verificationProfile: profile,
            lifecycle: lifecycle,
            verdict: verdict,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"])
        )
    }

    private static func attemptHistory(from row: Row) -> AttemptHistoryRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let taskID = UUID(uuidString: row["task_id"]),
              let profileID = UUID(uuidString: row["initiated_by_profile_id"]),
              let kind = TransferAttemptKind(rawValue: row["kind"]),
              let algorithm = ChecksumAlgorithm(rawValue: row["checksum_algorithm"]),
              let profile = VerificationProfile(rawValue: row["verification_profile"]),
              let lifecycle = TaskLifecycle(rawValue: row["lifecycle"]),
              let verdict = TransferVerdict(rawValue: row["verdict"])
        else { return nil }
        let parent: String? = row["parent_attempt_id"]
        let started: Double? = row["started_at"]
        let finished: Double? = row["finished_at"]
        let issuesJSON: String = row["issues_json"]
        let issues = (try? JSONDecoder().decode([String].self, from: Data(issuesJSON.utf8))) ?? []
        return AttemptHistoryRecord(
            id: id,
            taskID: taskID,
            parentAttemptID: parent.flatMap(UUID.init(uuidString:)),
            kind: kind,
            operatorSnapshot: OperatorSnapshot(profileID: profileID, displayName: row["initiated_by_name"]),
            algorithm: algorithm,
            verificationProfile: profile,
            lifecycle: lifecycle,
            verdict: verdict,
            startedAt: started.map(Date.init(timeIntervalSince1970:)),
            finishedAt: finished.map(Date.init(timeIntervalSince1970:)),
            issues: issues,
            fileCount: row["file_count"]
        )
    }

    private static func evidenceArtifact(from row: Row) -> EvidenceArtifactHistoryRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let attemptID = UUID(uuidString: row["attempt_id"])
        else { return nil }
        return EvidenceArtifactHistoryRecord(
            id: id,
            attemptID: attemptID,
            kind: row["kind"],
            path: row["path"],
            required: row["required"],
            status: row["status"],
            warning: row["warning"]
        )
    }

    private static func insertAudit(_ event: AuditEventRecord, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO audit_events
                (id, task_id, attempt_id, actor_kind, operator_profile_id,
                 operator_display_name, action, occurred_at, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                event.id.uuidString.lowercased(), event.taskID?.uuidString.lowercased(),
                event.attemptID?.uuidString.lowercased(), event.actorKind.rawValue,
                event.operatorSnapshot?.profileID.uuidString.lowercased(),
                event.operatorSnapshot?.displayName, event.action.rawValue,
                event.occurredAt.timeIntervalSince1970, event.detail
            ])
    }

    private static func insertEvidenceIfMissing(
        attemptID: UUID,
        kind: String,
        path: String,
        required: Bool,
        db: Database
    ) throws {
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM evidence_artifacts WHERE attempt_id = ? AND path = ?)",
            arguments: [attemptID.uuidString.lowercased(), path]
        ) ?? false
        guard !exists else { return }
        try db.execute(sql: """
            INSERT INTO evidence_artifacts
                (id, attempt_id, kind, path, required, status, warning)
            VALUES (?, ?, ?, ?, ?, 'written', NULL)
            """, arguments: [
                UUID().uuidString.lowercased(), attemptID.uuidString.lowercased(),
                kind, path, required
            ])
    }

    /// Closes a task that never started an attempt as cancelled, with one
    /// audit event. Writes nothing — and returns false — unless the task is
    /// still queued and pending and has no attempt at all.
    private static func cancelNeverStartedTask(
        key: String,
        actorKind: AuditActorKind,
        operatorSnapshot: OperatorSnapshot?,
        detail: String,
        at date: Date,
        db: Database
    ) throws -> Bool {
        try db.execute(sql: """
            UPDATE transfer_tasks SET lifecycle = ?, verdict = ?, updated_at = ?
            WHERE id = ? AND lifecycle = ? AND verdict = ?
              AND NOT EXISTS (SELECT 1 FROM transfer_attempts WHERE task_id = ?)
            """, arguments: [
                TaskLifecycle.cancelled.rawValue, TransferVerdict.cancelled.rawValue,
                date.timeIntervalSince1970, key,
                TaskLifecycle.queued.rawValue, TransferVerdict.pending.rawValue, key,
            ])
        guard db.changesCount == 1 else { return false }
        try insertAudit(
            AuditEventRecord(
                taskID: UUID(uuidString: key),
                actorKind: actorKind,
                operatorSnapshot: operatorSnapshot,
                action: .taskCancelled,
                occurredAt: date,
                detail: detail
            ),
            db: db
        )
        return true
    }

    private enum CatalogAttemptState { case absent, open, finished }

    private static func catalogState(ofAttempt id: UUID, db: Database) throws -> CatalogAttemptState {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT finished_at FROM transfer_attempts WHERE id = ?",
            arguments: [id.uuidString.lowercased()]
        ) else { return .absent }
        let finished: Double? = row["finished_at"]
        return finished == nil ? .open : .finished
    }

    /// The system event that closes an attempt with this verdict — the mapping
    /// finishAttempt applies to a report's status. A Fast copy is a completed
    /// attempt (its verdict says verification is pending); a pause is not a
    /// failure.
    private static func terminalAuditAction(for verdict: TransferVerdict) -> AuditAction {
        switch verdict {
        case .paused: .taskPaused
        case .verified, .transferredPendingVerification: .attemptCompleted
        case .pending, .needsAttention, .failed, .cancelled: .attemptFailed
        }
    }

    private static func recordImportedManifest(
        canonicalPath: String,
        transferID: String,
        schemaVersion: Int,
        modifiedAt: Date,
        db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO imported_manifests
                (canonical_path, transfer_id, schema_version, modified_at, imported_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(canonical_path) DO UPDATE SET
                transfer_id = excluded.transfer_id,
                schema_version = excluded.schema_version,
                modified_at = excluded.modified_at,
                imported_at = excluded.imported_at
            """, arguments: [
                canonicalPath, transferID, schemaVersion,
                modifiedAt.timeIntervalSince1970, Date().timeIntervalSince1970,
            ])
    }

    private static func algorithm(fromManifestValue value: String) -> ChecksumAlgorithm? {
        value == "xxh64" ? .xxh64 : ChecksumAlgorithm(rawValue: value)
    }

    private static func audit(from row: Row) -> AuditEventRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let actorKind = AuditActorKind(rawValue: row["actor_kind"]),
              let action = AuditAction(rawValue: row["action"])
        else { return nil }
        let profileIDString: String? = row["operator_profile_id"]
        let displayName: String? = row["operator_display_name"]
        let snapshot: OperatorSnapshot? = if let profileIDString,
            let profileID = UUID(uuidString: profileIDString), let displayName {
            OperatorSnapshot(profileID: profileID, displayName: displayName)
        } else { nil }
        let taskIDString: String? = row["task_id"]
        let attemptIDString: String? = row["attempt_id"]
        return AuditEventRecord(
            id: id,
            taskID: taskIDString.flatMap(UUID.init(uuidString:)),
            attemptID: attemptIDString.flatMap(UUID.init(uuidString:)),
            actorKind: actorKind,
            operatorSnapshot: snapshot,
            action: action,
            occurredAt: Date(timeIntervalSince1970: row["occurred_at"]),
            detail: row["detail"]
        )
    }
}
