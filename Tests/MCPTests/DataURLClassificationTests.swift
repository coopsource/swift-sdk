// Copyright © Co-op Source Network.
import Foundation
import Testing

@testable import MCP

@Suite("Data URL classification and exact text fidelity")
struct DataURLClassificationTests {
    static let invalidText = [
        "data:a,b", "data:a,%62", "data:a;base64,Yg==", "data:123,456",
        "data:a;charset=utf-8,%62",
        "data:/plain,b", "data:text/,b", "data:text/plain/extra,%62",
        "data:text plain/subtype,b", "data:text/plain name,b",
        "data:text/\"plain\",b", "data:text/(plain),b", "data:text/pl[ain],b",
        "data:text/pl\\ain,b", "data:text/pl:ain,b", "data:text/pl?ain,b",
        "data:text/pl=ain,b", "data:text/pl@ain,b", "data:text/<plain>,b",
        "data:t\u{0000}ext/plain,b", "data:text/pl\t ain,b", "data:text/pl\nain,b",
        "data:téxt/plain,%62", "data:text/文本;base64,Yg==",
        "data:K/plain,%62", "data:text/K;base64,Yg==",
        "data:te\u{0301}xt/plain,b", "data:text/plai\u{0301}n,b",
        "data:text/\u{0301}plain,b", "data:text/plain\u{0301},b",
        "data:text/plain;other=value,%62", "data:;charset=,b"
    ]

    @Test("Invalid media remains exact text, including nested values", arguments: invalidText)
    func invalidMediaRemainsText(_ original: String) throws {
        #expect(!Data.isDataURL(string: original))
        #expect(Data.parseDataURL(original) == nil)
        let wire = try JSONEncoder().encode(original)
        let value = try JSONDecoder().decode(Value.self, from: wire)
        let text = try #require(value.stringValue)
        #expect(Array(text.utf8) == Array(original.utf8))
        let encoded = try JSONEncoder().encode(value)
        #expect(Array(try JSONDecoder().decode(String.self, from: encoded).utf8) == Array(original.utf8))

        let nestedWire = try JSONEncoder().encode(["values": [original]])
        let nested = try JSONDecoder().decode(Value.self, from: nestedWire)
        let nestedText = try #require(nested.objectValue?["values"]?.arrayValue?.first?.stringValue)
        #expect(Array(nestedText.utf8) == Array(original.utf8))
    }

    @Test("Every ASCII media character has its MIME token meaning")
    func asciiMediaTokens() throws {
        let allowed = Set("!#$%&'*+-.0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ^_`abcdefghijklmnopqrstuvwxyz{|}~".utf8)
        for scalar in UInt8.min...127 {
            let character = String(UnicodeScalar(scalar))
            for media in ["x\(character)/plain", "text/\(character)x"] {
                let original = "data:\(media),%62"
                let accepted = allowed.contains(scalar)
                #expect(Data.isDataURL(string: original) == accepted, "scalar \(scalar) in \(media.debugDescription)")
                let parsed = Data.parseDataURL(original)
                #expect((parsed != nil) == accepted)
                let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(original))
                if accepted {
                    #expect(parsed?.data == Data([98]))
                    #expect(value.dataValue?.1 == Data([98]))
                    #expect(value.dataValue?.mimeType == media)
                } else {
                    let text = try #require(value.stringValue)
                    #expect(Array(text.utf8) == Array(original.utf8))
                }
            }
        }
    }

    @Test("Valid existing forms retain their MIME type and decoded bytes")
    func validForms() throws {
        let cases: [(String, String, Data)] = [
            ("data:,hello%20world", "text/plain", Data("hello world".utf8)),
            ("data:;charset=utf-8,caf%C3%A9", "text/plain;charset=utf-8", Data("café".utf8)),
            ("data:text/plain,te\u{0301}xt K 文", "text/plain", Data("te\u{0301}xt K 文".utf8)),
            ("data:text/plain;charset=UTF-8,hello", "text/plain;charset=UTF-8", Data("hello".utf8)),
            ("data:application/octet-stream;base64,AP8=", "application/octet-stream", Data([0, 255])),
            ("data:;base64,AP8=", "text/plain", Data([0, 255])),
            ("data:;charset=utf-8;base64,Yg==", "text/plain;charset=utf-8", Data([98])),
            ("data:,", "text/plain", Data()),
            ("data:;base64,", "text/plain", Data()),
            ("data:text/plain;base64,", "text/plain", Data()),
            ("data:Text/PLAIN,Hello", "Text/PLAIN", Data("Hello".utf8)),
            ("data:application/vnd.example+json,%7B%7D", "application/vnd.example+json", Data("{}".utf8)),
            ("data:text/plain,comma,in,payload", "text/plain", Data("comma,in,payload".utf8)),
            ("data:text/plain;charset=K,b", "text/plain;charset=K", Data([98]))
        ]
        for (wireText, mimeType, bytes) in cases {
            #expect(Data.isDataURL(string: wireText))
            let parsed = try #require(Data.parseDataURL(wireText))
            #expect(Array(parsed.mimeType.utf8) == Array(mimeType.utf8))
            #expect(parsed.data == bytes)
            let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(wireText))
            #expect(value == .data(mimeType: mimeType, bytes))
            let roundTrip = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
            #expect(roundTrip == value)
        }
    }

    @Test("Malformed payloads keep the original string", arguments: [
        "data:text/plain,%", "data:text/plain,%GG", "data:text/plain,%FF",
        "data:text/plain;base64,?", "data:text/plain;base64,Yg=",
        "data:;base64,SGVsbG8=!"
    ])
    func malformedPayloadRemainsText(_ original: String) throws {
        // isDataURL is structural; payload validation remains in parseDataURL.
        #expect(Data.isDataURL(string: original))
        #expect(Data.parseDataURL(original) == nil)
        let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(original))
        let text = try #require(value.stringValue)
        #expect(Array(text.utf8) == Array(original.utf8))
    }
}
