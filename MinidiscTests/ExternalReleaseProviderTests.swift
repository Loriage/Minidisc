import Testing
import Foundation
@testable import Minidisc

@Suite("ExternalReleaseProvider — validate(urlTemplate:)")
struct ExternalReleaseProviderValidationTests {

    @Test("valid https template returns .valid")
    func validHTTPS() {
        #expect(ExternalReleaseProvider.validate(urlTemplate: "https://bandcamp.com/search?q=%s") == .valid)
    }

    @Test("valid http template returns .valid")
    func validHTTP() {
        #expect(ExternalReleaseProvider.validate(urlTemplate: "http://example.com/search?q=%s") == .valid)
    }

    @Test("missing %s placeholder returns .missingPlaceholder")
    func missingPlaceholder() {
        #expect(ExternalReleaseProvider.validate(urlTemplate: "https://bandcamp.com/search?q=artist") == .missingPlaceholder)
    }

    @Test("two %s placeholders returns .multiplePlaceholders")
    func multiplePlaceholders() {
        #expect(ExternalReleaseProvider.validate(urlTemplate: "https://example.com?a=%s&b=%s") == .multiplePlaceholders)
    }

    @Test("javascript: scheme returns .invalidScheme — critical security test")
    func javascriptSchemeCritical() {
        #expect(ExternalReleaseProvider.validate(urlTemplate: "javascript:alert(1)%s") == .invalidScheme)
    }

    @Test("JavaScript: mixed case also returns .invalidScheme")
    func javascriptMixedCase() {
        #expect(ExternalReleaseProvider.validate(urlTemplate: "JavaScript:alert(1)%s") == .invalidScheme)
    }

    @Test("ftp:// scheme returns .invalidScheme")
    func ftpScheme() {
        #expect(ExternalReleaseProvider.validate(urlTemplate: "ftp://example.com/search?q=%s") == .invalidScheme)
    }

    @Test("malformed URL returns .malformed")
    func malformedURL() {
        #expect(ExternalReleaseProvider.validate(urlTemplate: "https://[invalid]/q=%s") == .malformed)
    }
}

@Suite("ExternalReleaseProvider — validate(name:)")
struct ExternalReleaseProviderNameValidationTests {

    @Test("whitespace-only string returns false")
    func whitespaceName() {
        #expect(ExternalReleaseProvider.validate(name: "   ") == false)
    }

    @Test("name of exactly 50 chars returns true")
    func exactly50Chars() {
        #expect(ExternalReleaseProvider.validate(name: String(repeating: "a", count: 50)) == true)
    }

    @Test("name of 51 chars returns false")
    func over50Chars() {
        #expect(ExternalReleaseProvider.validate(name: String(repeating: "a", count: 51)) == false)
    }
}

@Suite("ExternalReleaseProvider — buildURL")
struct ExternalReleaseProviderBuildURLTests {

    private let provider = ExternalReleaseProvider(
        name: "Test",
        urlTemplate: "https://example.com/search?q=%s"
    )

    @Test("reserved characters and Unicode stay inside a single search query")
    func searchTermIsEncoded() throws {
        let url = try #require(provider.buildURL(artistName: "AC/DC & Les Égarés", albumTitle: "Rock 'n' Roll"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "q", value: "AC/DC & Les Égarés Rock 'n' Roll")])
        #expect(url.absoluteString.contains("%26"))
        #expect(url.absoluteString.contains("%2F"))
        #expect(url.absoluteString.contains("%C3%89"))
    }

    @Test("leading and trailing whitespace is trimmed from search term")
    func whitespaceTrimmed() {
        let urlWithSpaces = provider.buildURL(artistName: "  Daft Punk  ", albumTitle: "  Discovery  ")
        #expect(urlWithSpaces?.absoluteString == "https://example.com/search?q=Daft%20Punk%20Discovery")
    }
}
