import XCTest
@testable import WetoSystem

final class KeychainStoreTests: XCTestCase {

    private let service = "com.weto.tests.keychain"
    private let account = "ipinfo"

    private var store: KeychainStore { KeychainStore(service: service) }

    override func tearDown() {
        store.write(nil, account: account)
        super.tearDown()
    }

    func test_reading_absent_secret_returns_nil() {
        store.write(nil, account: account)
        XCTAssertNil(store.read(account: account))
    }

    func test_written_secret_is_read_back() {
        XCTAssertTrue(store.write("s3cret", account: account))
        XCTAssertEqual(store.read(account: account), "s3cret")
    }

    func test_writing_twice_overwrites_previous_value() {
        store.write("first", account: account)
        store.write("second", account: account)
        XCTAssertEqual(store.read(account: account), "second")
    }

    func test_writing_nil_deletes_secret() {
        store.write("to be removed", account: account)
        XCTAssertTrue(store.write(nil, account: account))
        XCTAssertNil(store.read(account: account))
    }

    func test_accounts_are_isolated() {
        store.write("a", account: "first")
        store.write("b", account: "second")
        XCTAssertEqual(store.read(account: "first"), "a")
        XCTAssertEqual(store.read(account: "second"), "b")
        store.write(nil, account: "first")
        store.write(nil, account: "second")
    }
}

final class TokenBoxTests: XCTestCase {

    func test_stores_and_returns_value() {
        let box = TokenBox()
        XCTAssertNil(box.value)
        box.value = "token"
        XCTAssertEqual(box.value, "token")
        box.value = nil
        XCTAssertNil(box.value)
    }

    func test_concurrent_access_does_not_corrupt_state() {
        let box = TokenBox("initial")
        let iterations = 500

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            if index.isMultiple(of: 2) {
                box.value = "value-\(index)"
            } else {
                _ = box.value
            }
        }

        XCTAssertNotNil(box.value)
    }
}
