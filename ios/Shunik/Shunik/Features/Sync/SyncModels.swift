import Foundation

/// Shared sync-domain models (v1 household plan). ONE Codable per wire
/// shape, used for local GRDB rows, outbox payloads, AND relay JSON —
/// the backend speaks snake_case with RFC 3339 timestamps, so every type
/// below uses explicit CodingKeys and String timestamps (never Double).
///
/// Timestamps are RFC3339-millisecond UTC strings ("2026-10-26T12:00:00.123Z").
/// Fixed-width UTC lexicographic order IS chronological order, so cursors
/// and LWW base comparisons are plain string operations. The backend stores
/// microseconds; ingest MUST normalize via RFC3339Milli or same-instant
/// values compare unequal across the boundary.
enum RFC3339Milli {
    static func nowString() -> String {
        format(Date())
    }

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func parse(_ string: String) -> Date? {
        formatter.date(from: string) ?? fallback.date(from: string)
    }

    /// Normalizes any RFC3339 timestamp (nano precision, offsets) to the
    /// canonical ms-UTC form. Unparseable input passes through unchanged
    /// (loud failure at the call site, never silent epoch-zero).
    static func normalize(_ string: String) -> String {
        guard let date = parse(string) else { return string }
        return format(date)
    }

    private static var formatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }

    private static var fallback: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }
}

/// Outbox + tombstone resource names. MUST match the relay's tombstone
/// `resource` strings exactly — delete-wins checks compare them.
enum SyncResource: String, CaseIterable, Sendable {
    case pet
    case event
    case intake
    case document
}

/// Sync-state cursor keys (one per resource + deletions feed).
enum SyncCursorKey {
    static let pets = "pets"
    static let events = "events"
    static let intakes = "intakes"
    static let documents = "documents"
    static let deletions = "deletions"
}

/// A household shared by equal owners (day-1 sharing).
struct HouseholdRecord: Codable, Equatable, Sendable {
    var id: String
    var createdAt: String
    var updatedAt: String
    var updatedBy: String

    enum CodingKeys: String, CodingKey {
        case id, createdAt = "created_at", updatedAt = "updated_at", updatedBy = "updated_by"
    }
}

/// One owner of a household.
struct HouseholdMemberRecord: Codable, Equatable, Sendable {
    var householdID: String
    var userID: String
    var email: String
    var addedBy: String
    var joinedAt: String

    enum CodingKeys: String, CodingKey {
        case householdID = "household_id", userID = "user_id", email
        case addedBy = "added_by", joinedAt = "joined_at"
    }
}

struct HouseholdWithMembers: Codable, Sendable {
    var household: HouseholdRecord
    var members: [HouseholdMemberRecord]
}

/// A pet in the calling household.
struct PetRecord: Codable, Equatable, Sendable {
    var id: String
    var householdID: String
    var name: String
    var species: String
    var birthdate: String?
    var notes: String
    var createdAt: String
    var updatedAt: String
    var updatedBy: String

    enum CodingKeys: String, CodingKey {
        case id, householdID = "household_id", name, species, birthdate, notes
        case createdAt = "created_at", updatedAt = "updated_at", updatedBy = "updated_by"
    }
}

struct VaccDetail: Codable, Equatable, Sendable {
    var vaccine: String
    var batch: String
    var vet: String
    var notes: String
}

struct GroomDetail: Codable, Equatable, Sendable {
    var service: String
    var place: String
    var notes: String
}

struct WeightDetail: Codable, Equatable, Sendable {
    var grams: Int64
}

/// Medication course detail. Dose stays a string ("0.5", never a float) so
/// no layer can round it.
struct MedCourseRecord: Codable, Equatable, Sendable {
    var drugName: String
    var doseAmount: String
    var doseUnit: String
    var route: String
    var scheduleKind: String
    var scheduleTimes: String
    var scheduleWeekdays: String
    var durationDays: Int
    var endsOn: String?
    var status: String
    var instructions: String
    var infoRef: String

    enum CodingKeys: String, CodingKey {
        case drugName = "drug_name", doseAmount = "dose_amount", doseUnit = "dose_unit"
        case route, scheduleKind = "schedule_kind", scheduleTimes = "schedule_times"
        case scheduleWeekdays = "schedule_weekdays", durationDays = "duration_days"
        case endsOn = "ends_on", status, instructions, infoRef = "info_ref"
    }
}

/// Kind detail container: exactly one member is non-nil, matching the base
/// row's kind (backend contract; unknown members are ignored on decode).
struct EventDetailPayload: Codable, Equatable, Sendable {
    var vaccination: VaccDetail?
    var grooming: GroomDetail?
    var weight: WeightDetail?
    var course: MedCourseRecord?

    enum CodingKeys: String, CodingKey {
        case vaccination, grooming, weight, course
    }
}

/// One timeline row with its kind detail joined.
struct EventRecord: Codable, Equatable, Sendable {
    var id: String
    var householdID: String
    var petID: String
    var kind: String
    var occurredAt: String
    var nextDueAt: String?
    var title: String
    var vaccination: VaccDetail?
    var grooming: GroomDetail?
    var weight: WeightDetail?
    var course: MedCourseRecord?
    var createdAt: String
    var updatedAt: String
    var updatedBy: String

    enum CodingKeys: String, CodingKey {
        case id, householdID = "household_id", petID = "pet_id", kind
        case occurredAt = "occurred_at", nextDueAt = "next_due_at", title
        case vaccination, grooming, weight, course
        case createdAt = "created_at", updatedAt = "updated_at", updatedBy = "updated_by"
    }

    /// The backend nests the detail under a "detail" object; the local row
    /// is flat. Decode supports both shapes so pulls and snapshots share
    /// this type.
    private enum DetailWrapperKeys: String, CodingKey {
        case detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        householdID = try c.decodeIfPresent(String.self, forKey: .householdID) ?? ""
        petID = try c.decode(String.self, forKey: .petID)
        kind = try c.decode(String.self, forKey: .kind)
        occurredAt = try c.decode(String.self, forKey: .occurredAt)
        nextDueAt = try c.decodeIfPresent(String.self, forKey: .nextDueAt)
        title = try c.decode(String.self, forKey: .title)
        var nested: EventDetailPayload?
        if let wrapper = try? decoder.container(keyedBy: DetailWrapperKeys.self) {
            nested = try? wrapper.decode(EventDetailPayload.self, forKey: .detail)
        }
        if let detail = nested {
            vaccination = detail.vaccination
            grooming = detail.grooming
            weight = detail.weight
            course = detail.course
        } else {
            vaccination = try c.decodeIfPresent(VaccDetail.self, forKey: .vaccination)
            grooming = try c.decodeIfPresent(GroomDetail.self, forKey: .grooming)
            weight = try c.decodeIfPresent(WeightDetail.self, forKey: .weight)
            course = try c.decodeIfPresent(MedCourseRecord.self, forKey: .course)
        }
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy) ?? ""
    }
}

/// One due or logged giving of a course.
struct IntakeRecord: Codable, Equatable, Sendable {
    var id: String
    var householdID: String
    var courseID: String
    var dueAt: String?
    var status: String
    var takenAt: String?
    var doseSnapshot: String
    var note: String
    var markedBy: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, householdID = "household_id", courseID = "course_id"
        case dueAt = "due_at", status, takenAt = "taken_at"
        case doseSnapshot = "dose_snapshot", note, markedBy = "marked_by"
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

/// Document metadata (never bytes). petIDs replaces the link set wholesale.
struct DocumentRecord: Codable, Equatable, Sendable {
    var id: String
    var householdID: String
    var title: String
    var mime: String
    var sizeBytes: Int64
    var filename: String
    var blobKey: String
    var ready: Bool
    var extractedText: String
    var petIDs: [String]
    var createdAt: String
    var updatedAt: String
    var updatedBy: String

    enum CodingKeys: String, CodingKey {
        case id, householdID = "household_id", title, mime
        case sizeBytes = "size_bytes", filename, blobKey = "blob_key"
        case ready, extractedText = "extracted_text", petIDs = "pet_ids"
        case createdAt = "created_at", updatedAt = "updated_at", updatedBy = "updated_by"
    }
}

/// A relay tombstone: a hard delete other devices must apply.
struct TombstoneRecord: Codable, Equatable, Sendable {
    var resource: String
    var recordID: String
    var deletedAt: String

    enum CodingKeys: String, CodingKey {
        case resource, recordID = "record_id", deletedAt = "deleted_at"
    }
}

// MARK: - Full-shape update bodies (PATCH is full-replace + base guard)

/// Pet update body: full shape + the base the writer last saw.
struct PetUpdateBody: Codable, Sendable {
    var baseUpdatedAt: String
    var name: String
    var species: String
    var birthdate: String?
    var notes: String

    enum CodingKeys: String, CodingKey {
        case baseUpdatedAt = "base_updated_at", name, species, birthdate, notes
    }
}

/// Event update body: full shape + base. pet_id/kind are echoed immutable
/// (the relay rejects changes).
struct EventUpdateBody: Codable, Sendable {
    var baseUpdatedAt: String
    var petID: String
    var kind: String
    var occurredAt: String
    var nextDueAt: String?
    var title: String
    var vaccination: VaccDetail?
    var grooming: GroomDetail?
    var weight: WeightDetail?
    var course: MedCourseRecord?

    enum CodingKeys: String, CodingKey {
        case baseUpdatedAt = "base_updated_at", petID = "pet_id", kind
        case occurredAt = "occurred_at", nextDueAt = "next_due_at", title
        case vaccination, grooming, weight, course
    }
}

/// Intake update body: only base_updated_at is required (nil fields merge
/// server-side — resend current values to keep them).
struct IntakeUpdateBody: Codable, Sendable {
    var baseUpdatedAt: String
    var status: String?
    var takenAt: String?
    var note: String?
    var doseSnapshot: String?

    enum CodingKeys: String, CodingKey {
        case baseUpdatedAt = "base_updated_at", status
        case takenAt = "taken_at", note, doseSnapshot = "dose_snapshot"
    }
}

/// Document update body: only base_updated_at is required.
struct DocumentUpdateBody: Codable, Sendable {
    var baseUpdatedAt: String
    var title: String?
    var petIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case baseUpdatedAt = "base_updated_at", title, petIDs = "pet_ids"
    }
}

// MARK: - List envelopes (cursor pages)

struct PetListResponse: Codable, Sendable {
    var pets: [PetRecord]
    var cursor: String
}

struct EventListResponse: Codable, Sendable {
    var events: [EventRecord]
    var cursor: String
}

struct IntakeListResponse: Codable, Sendable {
    var intakes: [IntakeRecord]
    var cursor: String
}

struct DocumentListResponse: Codable, Sendable {
    var documents: [DocumentRecord]
    var cursor: String
}

struct DeletionListResponse: Codable, Sendable {
    var deletions: [TombstoneRecord]
    var cursor: String
}
