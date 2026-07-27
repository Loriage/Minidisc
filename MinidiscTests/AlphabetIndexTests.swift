// Minidisc — Music client for Subsonic/OpenSubsonic servers
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Minidisc

@Suite("Alphabet jump bar — indexing")
struct AlphabetIndexTests {

    @Test("Latin names index under their uppercased initial")
    func latinNames() {
        #expect(alphabetFirstLetter(of: "Zara Larsson") == "Z")
        #expect(alphabetFirstLetter(of: "bôa") == "B")
        #expect(alphabetFirstLetter(of: "almost monday") == "A")
    }

    /// Regression guard: these returned their own initial ("Л", "Ν"), an index entry no row in the
    /// bar can match — the artists were unreachable and "#" stayed greyed out despite having content.
    @Test("non-Latin scripts fall into the # bucket")
    func nonLatinScripts() {
        #expect(alphabetFirstLetter(of: "ЛЮТИК") == "#")
        #expect(alphabetFirstLetter(of: "Нонконформистка") == "#")
        #expect(alphabetFirstLetter(of: "Νεότητα") == "#")
        #expect(alphabetFirstLetter(of: "東京事変") == "#")
    }

    @Test("diacritics fold onto their base letter")
    func diacritics() {
        #expect(alphabetFirstLetter(of: "Édith Piaf") == "E")
        #expect(alphabetFirstLetter(of: "Ólafur Arnalds") == "O")
        #expect(alphabetFirstLetter(of: "Ängie") == "A")
    }

    @Test("digits, punctuation and empty names index under #")
    func nonLetters() {
        #expect(alphabetFirstLetter(of: "3 Doors Down") == "#")
        #expect(alphabetFirstLetter(of: "!!!") == "#")
        #expect(alphabetFirstLetter(of: "") == "#")
    }

    @Test("the available set only ever contains letters the bar can show")
    func availableLettersAreDisplayable() {
        struct Item: Identifiable { let id = UUID(); let name: String }
        let items = [
            Item(name: "Zara Larsson"), Item(name: "ЛЮТИК"),
            Item(name: "Édith Piaf"), Item(name: "3 Doors Down")
        ]
        let letters = items.availableAlphabetLetters(keyPath: \.name)

        #expect(letters == ["Z", "#", "E"])
        let displayable = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)).union(["#"])
        #expect(letters.isSubset(of: displayable))
    }

    @Test("tapping a letter resolves to the first matching item")
    func firstItemForLetter() {
        struct Item: Identifiable { let id: String; let name: String }
        let items = [
            Item(id: "1", name: "Zara Larsson"),
            Item(id: "2", name: "ЛЮТИК"),
            Item(id: "3", name: "Нонконформистка")
        ]
        #expect(firstAlphabetItemID(forLetter: "#", in: items, keyPath: \.name) == "2")
        #expect(firstAlphabetItemID(forLetter: "Z", in: items, keyPath: \.name) == "1")
        #expect(firstAlphabetItemID(forLetter: "Q", in: items, keyPath: \.name) == nil)
    }
}
