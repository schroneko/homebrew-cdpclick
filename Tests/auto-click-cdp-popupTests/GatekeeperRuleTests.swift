import XCTest
@testable import auto_click_cdp_popup

final class GatekeeperRuleTests: XCTestCase {
    let english = GatekeeperLocalizationRule(
        locale: "en",
        headlineTemplate: "“%@” is an app downloaded from the Internet. Are you sure you want to open it?",
        notarizedDetails: [
            "Apple checked it for malicious software and none was detected.",
            "As of %@, Apple checked it for malicious software and none was detected."
        ],
        openButton: "Open",
        provenanceTemplates: ["%@ downloaded this file on %@."]
    )
    let japanese = GatekeeperLocalizationRule(
        locale: "ja",
        headlineTemplate: "“%@”はインターネットからダウンロードされたアプリケーションです。開いてもよろしいですか?",
        notarizedDetails: [
            "Appleによるチェックで悪質なソフトウェアは検出されませんでした。",
            "%@の時点で、Appleによるチェックで悪質なソフトウェアは検出されませんでした。"
        ],
        openButton: "開く",
        provenanceTemplates: ["このファイルは“%@”により%@にダウンロードされました。"]
    )

    var rule: GatekeeperRule {
        GatekeeperRule(localizations: [english, japanese])
    }

    func testMatchesEnglishGatekeeperConfirmation() {
        XCTAssertEqual(
            rule.match(englishSnapshot()),
            GatekeeperMatch(locale: "en", buttonLabel: "Open", usesButtonFallback: false)
        )
    }

    func testMatchesJapaneseGatekeeperConfirmation() {
        let snapshot = GatekeeperDialogSnapshot(
            bundleIdentifier: GatekeeperRule.bundleIdentifier,
            bundlePath: GatekeeperRule.bundlePath,
            staticTexts: [
                "“Sample.app”はインターネットからダウンロードされたアプリケーションです。開いてもよろしいですか?",
                "Appleによるチェックで悪質なソフトウェアは検出されませんでした。",
                "このファイルは“Homebrew Cask”により2026年8月6日にダウンロードされました。"
            ],
            modalEvidence: .modal,
            buttonEvidence: .defaultButton(
                GatekeeperButtonSnapshot(role: "AXButton", label: "開く")
            )
        )

        XCTAssertEqual(
            rule.match(snapshot),
            GatekeeperMatch(locale: "ja", buttonLabel: "開く", usesButtonFallback: false)
        )
    }

    func testRejectsMissingHomebrewCaskProvenance() {
        var snapshot = englishSnapshot()
        snapshot = replacingTexts(
            in: snapshot,
            with: snapshot.staticTexts.map {
                $0.replacingOccurrences(of: "Homebrew Cask", with: "Safari")
            }
        )

        XCTAssertNil(rule.match(snapshot))
    }

    func testRejectsMissingNotarizedDetail() {
        let snapshot = replacingTexts(
            in: englishSnapshot(),
            with: englishSnapshot().staticTexts.filter {
                $0 != english.notarizedDetails[0]
            }
        )

        XCTAssertNil(rule.match(snapshot))
    }

    func testRejectsUnverifiedWarning() {
        var texts = englishSnapshot().staticTexts.filter {
            $0 != english.notarizedDetails[0]
        }
        texts.append("Apple could not verify “Sample.app” is free of malware.")
        let snapshot = replacingTexts(in: englishSnapshot(), with: texts)

        XCTAssertNil(rule.match(snapshot))
    }

    func testRejectsMalwareWarning() {
        var texts = englishSnapshot().staticTexts.filter {
            $0 != english.notarizedDetails[0]
        }
        texts.append("“Sample.app” was not opened because it contains malware.")
        let snapshot = replacingTexts(in: englishSnapshot(), with: texts)

        XCTAssertNil(rule.match(snapshot))
    }

    func testRejectsOpenAnywayButton() {
        let snapshot = replacingButton(
            in: englishSnapshot(),
            with: .defaultButton(
                GatekeeperButtonSnapshot(role: "AXButton", label: "Open Anyway")
            )
        )

        XCTAssertNil(rule.match(snapshot))
    }

    func testRejectsDifferentBundleIdentifier() {
        let original = englishSnapshot()
        let snapshot = GatekeeperDialogSnapshot(
            bundleIdentifier: "com.example.uiagent",
            bundlePath: GatekeeperRule.bundlePath,
            staticTexts: original.staticTexts,
            modalEvidence: original.modalEvidence,
            buttonEvidence: original.buttonEvidence
        )

        XCTAssertNil(rule.match(snapshot))
    }

    func testRejectsDifferentBundlePath() {
        let original = englishSnapshot()
        let snapshot = GatekeeperDialogSnapshot(
            bundleIdentifier: original.bundleIdentifier,
            bundlePath: "/Applications/CoreServicesUIAgent.app",
            staticTexts: original.staticTexts,
            modalEvidence: original.modalEvidence,
            buttonEvidence: original.buttonEvidence
        )

        XCTAssertNil(rule.match(snapshot))
    }

    func testRejectsDiskImageHeadline() {
        let snapshot = replacingTexts(
            in: englishSnapshot(),
            with: [
                "“Sample.dmg” is a disk image downloaded from the Internet. Are you sure you want to open it?",
                english.notarizedDetails[0],
                "Homebrew Cask downloaded this file on August 6, 2026."
            ]
        )

        XCTAssertNil(rule.match(snapshot))
    }

    func testRejectsNonModalWindow() {
        let original = englishSnapshot()
        let snapshot = GatekeeperDialogSnapshot(
            bundleIdentifier: original.bundleIdentifier,
            bundlePath: original.bundlePath,
            staticTexts: original.staticTexts,
            modalEvidence: .notModal,
            buttonEvidence: original.buttonEvidence
        )

        XCTAssertNil(rule.match(snapshot))
    }

    func testMatchesDialogSubroleFallback() {
        let original = englishSnapshot()
        let snapshot = GatekeeperDialogSnapshot(
            bundleIdentifier: original.bundleIdentifier,
            bundlePath: original.bundlePath,
            staticTexts: original.staticTexts,
            modalEvidence: .dialogSubroleFallback,
            buttonEvidence: original.buttonEvidence
        )

        XCTAssertNotNil(rule.match(snapshot))
    }

    func testMatchesUniqueOpenButtonWhenDefaultButtonIsUnsupported() {
        let snapshot = replacingButton(
            in: englishSnapshot(),
            with: .defaultButtonUnsupported([
                GatekeeperButtonSnapshot(role: "AXButton", label: "Cancel"),
                GatekeeperButtonSnapshot(role: "AXButton", label: "Open")
            ])
        )

        XCTAssertEqual(
            rule.match(snapshot),
            GatekeeperMatch(locale: "en", buttonLabel: "Open", usesButtonFallback: true)
        )
    }

    func testRejectsAmbiguousOpenButtonsWhenDefaultButtonIsUnsupported() {
        let snapshot = replacingButton(
            in: englishSnapshot(),
            with: .defaultButtonUnsupported([
                GatekeeperButtonSnapshot(role: "AXButton", label: "Open"),
                GatekeeperButtonSnapshot(role: "AXButton", label: "Open")
            ])
        )

        XCTAssertNil(rule.match(snapshot))
    }

    func testMatchesCombinedProvenanceAndNotarizedDetail() {
        let snapshot = replacingTexts(
            in: englishSnapshot(),
            with: [
                "“Sample.app” is an app downloaded from the Internet. Are you sure you want to open it?",
                "Homebrew Cask downloaded this file on August 6, 2026. Apple checked it for malicious software and none was detected."
            ]
        )

        XCTAssertNotNil(rule.match(snapshot))
    }

    func testMatchesOfflineNotarizedDetail() {
        let snapshot = replacingTexts(
            in: englishSnapshot(),
            with: [
                "“Sample.app” is an app downloaded from the Internet. Are you sure you want to open it?",
                "Homebrew Cask downloaded this file on August 6, 2026. As of August 6, 2026, Apple checked it for malicious software and none was detected."
            ]
        )

        XCTAssertNotNil(rule.match(snapshot))
    }

    func testRejectsCombinedDetailsWithUnexpectedText() {
        let snapshot = replacingTexts(
            in: englishSnapshot(),
            with: [
                "“Sample.app” is an app downloaded from the Internet. Are you sure you want to open it?",
                "Homebrew Cask downloaded this file on August 6, 2026. Apple checked it for malicious software and none was detected. Apple could not verify the developer."
            ]
        )

        XCTAssertNil(rule.match(snapshot))
    }

    func testMatchesNumberedLocalizationPlaceholders() {
        let catalan = GatekeeperLocalizationRule(
            locale: "ca",
            headlineTemplate: "Vols obrir l’app “%@”, descarregada d’internet?",
            notarizedDetails: ["Apple ha comprovat que no conté programari maliciós."],
            openButton: "Obre",
            provenanceTemplates: [
                "L’app %1$@ va descarregar aquest arxiu del lloc web %3$@ el dia %2$@."
            ]
        )
        let snapshot = GatekeeperDialogSnapshot(
            bundleIdentifier: GatekeeperRule.bundleIdentifier,
            bundlePath: GatekeeperRule.bundlePath,
            staticTexts: [
                "Vols obrir l’app “Sample.app”, descarregada d’internet?",
                "L’app Homebrew Cask va descarregar aquest arxiu del lloc web example.com el dia 6 d’agost. Apple ha comprovat que no conté programari maliciós."
            ],
            modalEvidence: .modal,
            buttonEvidence: .defaultButton(
                GatekeeperButtonSnapshot(role: "AXButton", label: "Obre")
            )
        )

        XCTAssertNotNil(GatekeeperRule(localizations: [catalan]).match(snapshot))
    }

    func testMatchesAnnotatedLocalizationPlaceholder() {
        XCTAssertTrue(
            GatekeeperRule.matches(
                template: "%[tt]@ downloaded this file on %@.",
                text: "Homebrew Cask downloaded this file on August 6, 2026.",
                fixedPlaceholders: [0: GatekeeperRule.provenanceAgent]
            )
        )
    }

    func testRejectsLongerDownloaderNameContainingHomebrewCask() {
        let snapshot = replacingTexts(
            in: englishSnapshot(),
            with: [
                "“Sample.app” is an app downloaded from the Internet. Are you sure you want to open it?",
                english.notarizedDetails[0],
                "Fake Homebrew Cask downloaded this file on August 6, 2026."
            ]
        )

        XCTAssertNil(rule.match(snapshot))
    }

    func testCatalogLoadsHomebrewProvenanceAndSafeDetails() {
        let localizations = GatekeeperLocalizationCatalog.load()
        let englishRule = localizations.first(where: { $0.locale == "en" })

        XCTAssertNotNil(englishRule)
        XCTAssertFalse(englishRule?.provenanceTemplates.isEmpty ?? true)
        XCTAssertGreaterThanOrEqual(englishRule?.notarizedDetails.count ?? 0, 2)
    }

    func testSystemCatalogMatchesScreenshotPrompt() {
        let snapshot = GatekeeperDialogSnapshot(
            bundleIdentifier: GatekeeperRule.bundleIdentifier,
            bundlePath: GatekeeperRule.bundlePath,
            staticTexts: [
                "“Codex Computer Use.app” is an app downloaded from the Internet. Are you sure you want to open it?",
                "Homebrew Cask downloaded this file today at 0:13. Apple checked it for malicious software and none was detected."
            ],
            modalEvidence: .modal,
            buttonEvidence: .defaultButton(
                GatekeeperButtonSnapshot(role: "AXButton", label: "Open")
            )
        )

        XCTAssertNotNil(
            GatekeeperRule(localizations: GatekeeperLocalizationCatalog.load()).match(snapshot)
        )
    }

    private func englishSnapshot() -> GatekeeperDialogSnapshot {
        GatekeeperDialogSnapshot(
            bundleIdentifier: GatekeeperRule.bundleIdentifier,
            bundlePath: GatekeeperRule.bundlePath,
            staticTexts: [
                "“Sample.app” is an app downloaded from the Internet. Are you sure you want to open it?",
                english.notarizedDetails[0],
                "Homebrew Cask downloaded this file on August 6, 2026."
            ],
            modalEvidence: .modal,
            buttonEvidence: .defaultButton(
                GatekeeperButtonSnapshot(role: "AXButton", label: "Open")
            )
        )
    }

    private func replacingTexts(
        in snapshot: GatekeeperDialogSnapshot,
        with staticTexts: [String]
    ) -> GatekeeperDialogSnapshot {
        GatekeeperDialogSnapshot(
            bundleIdentifier: snapshot.bundleIdentifier,
            bundlePath: snapshot.bundlePath,
            staticTexts: staticTexts,
            modalEvidence: snapshot.modalEvidence,
            buttonEvidence: snapshot.buttonEvidence
        )
    }

    private func replacingButton(
        in snapshot: GatekeeperDialogSnapshot,
        with buttonEvidence: GatekeeperButtonEvidence
    ) -> GatekeeperDialogSnapshot {
        GatekeeperDialogSnapshot(
            bundleIdentifier: snapshot.bundleIdentifier,
            bundlePath: snapshot.bundlePath,
            staticTexts: snapshot.staticTexts,
            modalEvidence: snapshot.modalEvidence,
            buttonEvidence: buttonEvidence
        )
    }
}
