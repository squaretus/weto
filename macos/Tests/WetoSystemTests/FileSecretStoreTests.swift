import XCTest
@testable import WetoSystem
import WetoCore

/// Токен терминальной версии лежит файлом: связка ключей у фонового сервиса
/// спрашивала бы разрешения диалогом, а показать его некому.
final class FileSecretStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("weto-secrets-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: FileSecretStore { FileSecretStore(directory: directory) }

    func test_reading_absent_secret_returns_nil() {
        XCTAssertNil(store.read(account: "token"))
    }

    func test_written_secret_is_read_back_and_creates_the_directory() {
        XCTAssertTrue(store.write("s3cret", account: "token").isSuccess)
        XCTAssertEqual(store.read(account: "token"), "s3cret")
    }

    /// Токен читает только владелец: plist и бэкапы видят все.
    func test_the_file_is_readable_by_the_owner_only() throws {
        _ = store.write("s3cret", account: "token")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url(account: "token").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// Файл, оставшийся с другими правами, при перезаписи права не сохраняет.
    func test_rewriting_a_file_with_loose_permissions_tightens_them() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = store.url(account: "token")
        FileManager.default.createFile(atPath: url.path, contents: Data("old".utf8),
                                       attributes: [.posixPermissions: 0o644])

        XCTAssertTrue(store.write("new", account: "token").isSuccess)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(store.read(account: "token"), "new")
    }

    func test_writing_nil_deletes_the_file_and_absent_file_is_fine() {
        _ = store.write("to be removed", account: "token")
        XCTAssertTrue(store.write(nil, account: "token").isSuccess)
        XCTAssertNil(store.read(account: "token"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(account: "token").path))
        XCTAssertTrue(store.write(nil, account: "token").isSuccess)
    }

    /// Токен, вписанный руками через `echo`, несёт перевод строки — он не часть токена.
    func test_a_trailing_newline_is_not_part_of_the_token() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("abc\n".utf8).write(to: store.url(account: "token"))
        XCTAssertEqual(store.read(account: "token"), "abc")
    }

    func test_an_unwritable_directory_is_reported() {
        let blocked = FileSecretStore(directory: URL(fileURLWithPath: "/dev/null/weto"))
        guard case .failure(.file) = blocked.write("x", account: "token") else {
            return XCTFail("ошибка записи обязана дойти до вызывающего")
        }
    }
}
