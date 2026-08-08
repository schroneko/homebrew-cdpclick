import Foundation

enum GatekeeperModalEvidence: Equatable {
    case modal
    case dialogSubroleFallback
    case notModal
    case unavailable

    var isSafe: Bool {
        self == .modal || self == .dialogSubroleFallback
    }
}

struct GatekeeperButtonSnapshot: Equatable {
    let role: String
    let label: String
}

enum GatekeeperButtonEvidence: Equatable {
    case defaultButton(GatekeeperButtonSnapshot)
    case defaultButtonUnsupported([GatekeeperButtonSnapshot])
    case unavailable
}

struct GatekeeperDialogSnapshot: Equatable {
    let bundleIdentifier: String?
    let bundlePath: String?
    let staticTexts: [String]
    let modalEvidence: GatekeeperModalEvidence
    let buttonEvidence: GatekeeperButtonEvidence
}

struct GatekeeperLocalizationRule: Equatable {
    let locale: String
    let headlineTemplate: String
    let notarizedDetails: [String]
    let openButton: String
    let provenanceTemplates: [String]
}

struct GatekeeperMatch: Equatable {
    let locale: String
    let buttonLabel: String
    let usesButtonFallback: Bool
}

struct GatekeeperRule {
    static let bundleIdentifier = "com.apple.coreservices.uiagent"
    static let bundlePath = "/System/Library/CoreServices/CoreServicesUIAgent.app"
    static let provenanceAgent = "Homebrew Cask"

    let localizations: [GatekeeperLocalizationRule]

    func match(_ snapshot: GatekeeperDialogSnapshot) -> GatekeeperMatch? {
        guard snapshot.bundleIdentifier == Self.bundleIdentifier else {
            return nil
        }
        guard snapshot.bundlePath == Self.bundlePath else {
            return nil
        }
        guard snapshot.modalEvidence.isSafe else {
            return nil
        }

        let texts = snapshot.staticTexts.map(Self.normalized)
        for localization in localizations {
            guard texts.contains(where: {
                Self.matches(template: localization.headlineTemplate, text: $0)
            }) else {
                continue
            }
            guard matchesDetails(texts: texts, localization: localization) else {
                continue
            }
            guard let usesFallback = matchesButton(
                evidence: snapshot.buttonEvidence,
                label: localization.openButton
            ) else {
                continue
            }
            return GatekeeperMatch(
                locale: localization.locale,
                buttonLabel: localization.openButton,
                usesButtonFallback: usesFallback
            )
        }
        return nil
    }

    private func matchesDetails(
        texts: [String],
        localization: GatekeeperLocalizationRule
    ) -> Bool {
        guard !localization.provenanceTemplates.isEmpty else {
            return false
        }
        let hasNotarizedDetail = texts.contains { text in
            localization.notarizedDetails.contains { detail in
                Self.matches(template: detail, text: text)
            }
        }
        let hasProvenance = texts.contains { text in
            localization.provenanceTemplates.contains { template in
                Self.matches(
                    template: template,
                    text: text,
                    fixedPlaceholders: [0: Self.provenanceAgent]
                )
            }
        }
        if hasNotarizedDetail && hasProvenance {
            return true
        }
        return texts.contains { text in
            localization.provenanceTemplates.contains { provenance in
                localization.notarizedDetails.contains { detail in
                    Self.matchesSequence(
                        templates: [provenance, detail],
                        text: text,
                        fixedPlaceholders: [[0: Self.provenanceAgent], [:]]
                    )
                }
            }
        }
    }

    private func matchesButton(
        evidence: GatekeeperButtonEvidence,
        label: String
    ) -> Bool? {
        let expected = Self.normalized(label)
        switch evidence {
        case let .defaultButton(button):
            guard button.role == "AXButton", Self.normalized(button.label) == expected else {
                return nil
            }
            return false
        case let .defaultButtonUnsupported(buttons):
            let matches = buttons.filter {
                $0.role == "AXButton" && Self.normalized($0.label) == expected
            }
            guard matches.count == 1 else {
                return nil
            }
            return true
        case .unavailable:
            return nil
        }
    }

    static func matches(
        template: String,
        text: String,
        fixedPlaceholders: [Int: String] = [:]
    ) -> Bool {
        guard let fragment = pattern(
            template: template,
            fixedPlaceholders: fixedPlaceholders
        ) else {
            return false
        }
        return matches(pattern: "^\(fragment)$", text: text)
    }

    static func matchesSequence(
        templates: [String],
        text: String,
        fixedPlaceholders: [[Int: String]]
    ) -> Bool {
        guard templates.count == fixedPlaceholders.count else {
            return false
        }
        let fragments = zip(templates, fixedPlaceholders).compactMap {
            pattern(template: $0.0, fixedPlaceholders: $0.1)
        }
        guard fragments.count == templates.count else {
            return false
        }
        return matches(pattern: "^\(fragments.joined(separator: " "))$", text: text)
    }

    private static func pattern(
        template: String,
        fixedPlaceholders: [Int: String]
    ) -> String? {
        let normalizedTemplate = normalized(template)
        guard let placeholderExpression = try? NSRegularExpression(
            pattern: "%(?:(\\d+)\\$)?(?:\\[[^\\]]+\\])?@"
        ) else {
            return nil
        }
        let templateRange = NSRange(normalizedTemplate.startIndex..., in: normalizedTemplate)
        let placeholders = placeholderExpression.matches(
            in: normalizedTemplate,
            range: templateRange
        )
        var pattern = ""
        var cursor = normalizedTemplate.startIndex
        var implicitIndex = 0
        for placeholder in placeholders {
            guard let placeholderRange = Range(placeholder.range, in: normalizedTemplate) else {
                return nil
            }
            pattern += NSRegularExpression.escapedPattern(
                for: String(normalizedTemplate[cursor..<placeholderRange.lowerBound])
            )
            let argumentIndex: Int
            if placeholder.range(at: 1).location != NSNotFound,
               let indexRange = Range(placeholder.range(at: 1), in: normalizedTemplate),
               let explicitIndex = Int(normalizedTemplate[indexRange]) {
                argumentIndex = explicitIndex - 1
            } else {
                argumentIndex = implicitIndex
                implicitIndex += 1
            }
            if let expected = fixedPlaceholders[argumentIndex] {
                pattern += NSRegularExpression.escapedPattern(for: normalized(expected))
            } else {
                pattern += "(.+?)"
            }
            cursor = placeholderRange.upperBound
        }
        pattern += NSRegularExpression.escapedPattern(
            for: String(normalizedTemplate[cursor...])
        )
        return pattern
    }

    private static func matches(pattern: String, text: String) -> Bool {
        let normalizedText = normalized(text)
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        return expression.firstMatch(in: normalizedText, range: range) != nil
    }

    static func normalized(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum GatekeeperLocalizationCatalog {
    static let resourcesURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/CoreServicesUIAgent.app/Contents/Resources",
        isDirectory: true
    )

    static func load() -> [GatekeeperLocalizationRule] {
        let headlines = loadTable(named: "QuarantineHeadlines.loctable")
        let quarantine = loadTable(named: "Quarantine.loctable")
        let details = loadTable(named: "QuarantineDetails.loctable")
        var rules: [GatekeeperLocalizationRule] = []

        for locale in headlines.keys.sorted() {
            guard let headline = headlines[locale]?[
                "Q_HEADLINE_APP.Q_ORIGIN_INTERNET.Q_TYPE_APPLICATION"
            ],
            let button = quarantine[locale]?["Q_BUTTON_OPEN"] else {
                continue
            }
            let notarizedDetails = [
                quarantine[locale]?["Q_DETAIL_NOTARIZED_ONLINE"],
                quarantine[locale]?["Q_DETAIL_NOTARIZED_OFFLINE"]
            ].compactMap { $0 }
            guard !notarizedDetails.isEmpty else {
                continue
            }
            let provenanceTemplates = details[locale]?
                .filter { key, _ in
                    let isDownload = key.hasPrefix("Q_DETAIL_DOWNLOAD_AGENT_DATE.")
                        || key.hasPrefix("Q_DETAIL_DOWNLOAD_AGENT_DATE_FROM.")
                    return isDownload && key.hasSuffix(".Q_DETAIL_TYPE_FILE")
                }
                .map(\.value)
                .sorted() ?? []
            rules.append(
                GatekeeperLocalizationRule(
                    locale: locale,
                    headlineTemplate: headline,
                    notarizedDetails: notarizedDetails,
                    openButton: button,
                    provenanceTemplates: provenanceTemplates
                )
            )
        }

        for fallback in fallbackRules {
            let exists = rules.contains {
                $0.headlineTemplate == fallback.headlineTemplate
                    && $0.notarizedDetails == fallback.notarizedDetails
                    && $0.openButton == fallback.openButton
            }
            if !exists {
                rules.append(fallback)
            }
        }
        return rules
    }

    static let fallbackRules = [
        GatekeeperLocalizationRule(
            locale: "en",
            headlineTemplate: "“%@” is an app downloaded from the Internet. Are you sure you want to open it?",
            notarizedDetails: [
                "Apple checked it for malicious software and none was detected.",
                "As of %@, Apple checked it for malicious software and none was detected."
            ],
            openButton: "Open",
            provenanceTemplates: [
                "%@ downloaded this file on %@.",
                "%@ downloaded this file today at %@.",
                "%@ downloaded this file on an unknown date.",
                "%@ downloaded this file yesterday at %@.",
                "%@ downloaded this file on %@ from %@.",
                "%@ downloaded this file today at %@ from %@.",
                "%@ downloaded this file on an unknown date from %@.",
                "%@ downloaded this file yesterday at %@ from %@."
            ]
        ),
        GatekeeperLocalizationRule(
            locale: "ja",
            headlineTemplate: "“%@”はインターネットからダウンロードされたアプリケーションです。開いてもよろしいですか?",
            notarizedDetails: [
                "Appleによるチェックで悪質なソフトウェアは検出されませんでした。",
                "%@の時点で、Appleによるチェックで悪質なソフトウェアは検出されませんでした。"
            ],
            openButton: "開く",
            provenanceTemplates: [
                "このファイルは“%@”により%@にダウンロードされました。",
                "このファイルは“%@”により今日の%@にダウンロードされました。",
                "このファイルは“%@”によりダウンロードされました。ダウンロード日は不明です。",
                "このファイルは“%@”により昨日の%@にダウンロードされました。",
                "このファイルは“%@”により%@に%@からダウンロードされました。",
                "このファイルは“%@”により今日の%@に%@からダウンロードされました。",
                "このファイルは“%@”により%@からダウンロードされました。ダウンロード日は不明です。",
                "このファイルは“%@”により昨日の%@に%@からダウンロードされました。"
            ]
        )
    ]

    private static func loadTable(named name: String) -> [String: [String: String]] {
        let url = resourcesURL.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let locales = propertyList as? [String: Any] else {
            return [:]
        }

        var table: [String: [String: String]] = [:]
        for (locale, values) in locales {
            if let values = values as? [String: String] {
                table[locale] = values
            }
        }
        return table
    }
}
