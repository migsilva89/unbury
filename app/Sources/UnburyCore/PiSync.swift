import Foundation
import PostgresNIO
import NIOCore
import NIOPosix

/// Pulling the vault down from the Postgres on the Pi.
///
/// A meeting point for people who run one: a machine an agent can also write to,
/// so links can arrive from somewhere other than a browser. The Mac keeps a full
/// copy, so the app opens with no network and the data exists in two places.
/// Nothing in the interface depends on this — it is reachable only through
/// `unburyctl sync`, and the app is complete without it.
public struct PiSync: Sendable {
    public struct Server: Codable, Sendable {
        public var host: String
        public var port: Int
        public var database: String
        public var username: String
        public var password: String

        public init(host: String, port: Int = 5432, database: String,
                    username: String, password: String) {
            self.host = host; self.port = port; self.database = database
            self.username = username; self.password = password
        }
    }

    public struct Result: Sendable {
        public let bookmarks: [Bookmark]
        public let vectors: [Float]
        public let dimensions: Int
        public let seconds: Double
    }

    private let server: Server

    public init(server: Server) { self.server = server }

    public func pull(progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Result {
        let started = Date()
        // The shared group is owned by the runtime; shutting our own down from an
        // async context is not allowed, and one connection does not need its own.
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()

        var tls = PostgresConnection.Configuration.TLS.disable
        if server.host.contains(".") && !server.host.hasPrefix("100.") {
            tls = .prefer(try .init(configuration: .clientDefault))
        }
        let configuration = PostgresConnection.Configuration(
            host: server.host, port: server.port,
            username: server.username, password: server.password,
            database: server.database, tls: tls)

        let connection = try await PostgresConnection.connect(
            on: eventLoop, configuration: configuration, id: 1, logger: .init(label: "vault"))
        defer { Task { try? await connection.close() } }

        let total = try await countRows(connection)
        var bookmarks: [Bookmark] = []
        var vectors: [Float] = []
        var dimensions = 0
        bookmarks.reserveCapacity(total)

        // The vector comes over as text — pgvector's own format, "[0.1,-0.2,…]" —
        // because PostgresNIO has no idea what a vector column is. Parsing it here
        // is cheaper than adding a type plugin for one column.
        let rows = try await connection.query("""
            SELECT id, url, coalesce(titulo,''), coalesce(pasta,''), dominio,
                   coalesce(guardado_em::text,''), origem, coalesce(descricao,''),
                   coalesce(tags,'{}'), imagem,
                   coalesce(criado_em::text,''), coalesce(atualizado_em::text,''),
                   embedding::text
            FROM bookmarks ORDER BY id
            """, logger: .init(label: "vault"))

        for try await row in rows.decode((Int, String, String, String, String, String,
                                          String, String, [String], String?, String,
                                          String, String).self) {
            bookmarks.append(Bookmark(
                id: row.0, url: row.1, title: row.2, folder: row.3, site: row.4,
                savedOn: row.5, origin: row.6, summary: row.7, tags: row.8,
                image: row.9, indexedAt: row.10, updatedAt: row.11))
            let numbers = parseVector(row.12)
            if dimensions == 0 { dimensions = numbers.count }
            vectors.append(contentsOf: numbers)
            progress?(bookmarks.count, total)
        }

        return Result(bookmarks: bookmarks, vectors: vectors, dimensions: dimensions,
                      seconds: Date().timeIntervalSince(started))
    }

    private func countRows(_ connection: PostgresConnection) async throws -> Int {
        let rows = try await connection.query("SELECT count(*)::int FROM bookmarks",
                                              logger: .init(label: "vault"))
        for try await row in rows.decode(Int.self) { return row }
        return 0
    }

    private func parseVector(_ text: String) -> [Float] {
        text.dropFirst().dropLast().split(separator: ",").compactMap { Float($0) }
    }
}
