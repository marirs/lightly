import XCTest
@testable import Lightly

final class FavouritesManagerTests: XCTestCase {

    private var userDefaults: UserDefaults!
    private var manager: UserDefaultsFavouritesManager!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "test.lightly.favourites.\(UUID().uuidString)")!
        manager = UserDefaultsFavouritesManager(userDefaults: userDefaults)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: userDefaults.description)
        super.tearDown()
    }

    func testInitialFavouritesIsEmpty() {
        XCTAssertTrue(manager.allFavourites().isEmpty)
        XCTAssertFalse(manager.isFavourite(presetID: "test.look"))
    }

    func testToggleFavouriteAddsAndRemoves() {
        let presetID = "film.kodak-gold-123"

        manager.toggleFavourite(presetID: presetID)
        XCTAssertTrue(manager.isFavourite(presetID: presetID))
        XCTAssertTrue(manager.allFavourites().contains(presetID))

        manager.toggleFavourite(presetID: presetID)
        XCTAssertFalse(manager.isFavourite(presetID: presetID))
        XCTAssertFalse(manager.allFavourites().contains(presetID))
    }

    func testMultipleFavourites() {
        manager.toggleFavourite(presetID: "look.1")
        manager.toggleFavourite(presetID: "look.2")
        manager.toggleFavourite(presetID: "look.3")

        let all = manager.allFavourites()
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.contains("look.1"))
        XCTAssertTrue(all.contains("look.2"))
        XCTAssertTrue(all.contains("look.3"))
    }
}
