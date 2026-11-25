import Foundation
import XCTest
@testable import FiltreCore

final class InterfaceLanguageTests: XCTestCase {
    func testFrenchPrimaryLanguageIncludingRegionalVariants() {
        for language in ["fr", "fr-FR", "fr-CA", "fr_CA", "FR_ca"] {
            XCTAssertEqual(interfaceLanguageCode(for: [language, "en-US"]), "fr", language)
        }
    }

    func testEveryOtherPrimaryUsesEnglishEvenWithSecondaryFrench() {
        for language in ["en", "en-GB", "de", "de-DE", "es", "es-MX", "it", "ja", "ar", "franken"] {
            XCTAssertEqual(interfaceLanguageCode(for: [language, "fr", "en"]), "en", language)
        }
    }

    func testEverySystemKnownISOLanguageUsesOnlyFrenchOrEnglish() {
        for language in Locale.isoLanguageCodes {
            XCTAssertEqual(interfaceLanguageCode(for: [language, "fr", "en"]),
                           language == "fr" ? "fr" : "en", language)
        }
    }

    func testMissingPrimaryDoesNotPromoteSecondaryFrench() {
        XCTAssertEqual(interfaceLanguageCode(for: []), "en")
        XCTAssertEqual(interfaceLanguageCode(for: ["", "fr"]), "en")
    }

    func testConfigurationIsVolatileAndPreservesOtherArguments() throws {
        let suite = "MusicFilterLanguageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let persistentBefore = defaults.persistentDomain(forName: suite)
        defaults.setVolatileDomain(["fixture": "preserved", "AppleLanguages": ["de", "fr"]],
                                  forName: UserDefaults.argumentDomain)
        configureInterfaceLanguage(preferredLanguages: ["de", "fr"], defaults: defaults)
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        XCTAssertEqual(arguments["AppleLanguages"] as? [String], ["en"])
        XCTAssertEqual(arguments["fixture"] as? String, "preserved")
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, persistentBefore as NSDictionary?)
        configureInterfaceLanguage(preferredLanguages: ["fr-CA", "en"], defaults: defaults)
        XCTAssertEqual(defaults.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] as? [String], ["fr"])
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, persistentBefore as NSDictionary?)
    }

    func testAppOwnedErrorKeepsItsBilingualDescription() {
        XCTAssertEqual(interfaceErrorDescription(BanStoreError.emptyArtist),
                       L("Enter an artist name.", "Saisissez le nom d’un artiste."))
    }

    func testForeignSystemErrorUsesControlledMessageAndDiagnosticIdentity() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                            userInfo: [NSLocalizedDescriptionKey: "Keine Berechtigung zum Schreiben."])
        let message = interfaceErrorDescription(error)
        XCTAssertFalse(message.contains("Keine Berechtigung"))
        XCTAssertEqual(message, L("The operation could not be completed (NSCocoaErrorDomain, 513). Please try again.",
                                  "L’opération n’a pas pu être effectuée (NSCocoaErrorDomain, 513). Veuillez réessayer."))
    }
}
