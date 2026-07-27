import Foundation
import Testing
@testable import Minidisc

@Suite("MediaResolver radio origin isolation")
struct MediaResolverOriginTests {
    @Test func acceptsSameOriginWithImplicitHTTPSPort() throws {
        let radio = try #require(URL(string: "https://music.example.com/radio/live"))
        let server = try #require(URL(string: "https://music.example.com:443/rest"))
        #expect(MediaResolver.isSameOrigin(radio, server))
    }

    @Test func rejectsDifferentHost() throws {
        let radio = try #require(URL(string: "https://stream.example.net/live"))
        let server = try #require(URL(string: "https://music.example.com"))
        #expect(!MediaResolver.isSameOrigin(radio, server))
    }

    @Test func rejectsSchemeAndPortChanges() throws {
        let server = try #require(URL(string: "https://music.example.com"))
        let insecure = try #require(URL(string: "http://music.example.com"))
        let alternatePort = try #require(URL(string: "https://music.example.com:8443/live"))
        #expect(!MediaResolver.isSameOrigin(insecure, server))
        #expect(!MediaResolver.isSameOrigin(alternatePort, server))
    }
}
