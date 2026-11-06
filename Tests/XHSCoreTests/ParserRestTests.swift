import Testing
@testable import XHSCore

@Suite struct ParserRestTests {
    private func rest(_ text: String) -> Bool { rest(Array(text.utf8)) }
    private func rest(_ bytes: [UInt8]) -> Bool {
        var parser = ParserRest()
        parser.advance(bytes)
        return parser.isAtRest
    }

    @Test func plainTextAndWholeSequencesAreAtRest() {
        for text in ["", "abc\r\n", "räksmörgås", "\u{1b}[1;31m", "\u{1b}]0;title\u{7}", "\u{1b}]0;title\u{1b}\\", "\u{1b}P1$r0m\u{1b}\\",
                     "\u{1b}_x\u{1b}\\", "\u{1b}Xx\u{1b}\\", "\u{1b}^x\u{1b}\\", "\u{1b}(B", "\u{1b}c", "\u{1b}]0;x\u{18}", "\u{1b}]0;x\u{1a}"] {
            #expect(rest(text), "\(text)")
        }
    }

    @Test func everyKindOfUnfinishedSequenceIsBusy() {
        for text in ["\u{1b}", "\u{1b}[", "\u{1b}[1;3", "\u{1b}]", "\u{1b}]0;tit", "\u{1b}]0;title\u{1b}", "\u{1b}P", "\u{1b}P1$r0", "\u{1b}_x", "\u{1b}Xx", "\u{1b}^x", "\u{1b}("] {
            #expect(!rest(text), "\(text)")
        }
    }

    @Test func halfACharacterIsBusy() {
        #expect(!rest([0xC3]))
        #expect(!rest([0xE2, 0x82]))
        #expect(!rest([0xF0, 0x9F, 0x91]))
        #expect(rest([0xF0, 0x9F, 0x91, 0xA9]))
    }

    @Test func aBellOnlyEndsWhatABellEnds() {
        #expect(rest("\u{1b}]0;x\u{7}"))
        #expect(rest("\u{1b}_x\u{7}"))
        #expect(!rest("\u{1b}P1$r0\u{7}"))
        #expect(!rest("\u{1b}Xx\u{7}"))
    }

    @Test func canOnlyEndsWhatItEnds() {
        #expect(rest("\u{1b}]0;x\u{18}"))
        #expect(rest("\u{1b}_x\u{18}"))
        #expect(!rest("\u{1b}P1\u{18}"))
        #expect(!rest("\u{1b}Xx\u{18}"))
        #expect(!rest("\u{1b}[1\u{18}"))
        #expect(!rest("\u{1b}(\u{18}"))
        #expect(!rest("\u{1b}\u{18}"))
    }

    @Test func subEndsEverything() {
        for text in ["\u{1b}]0;x", "\u{1b}P1", "\u{1b}Xx", "\u{1b}[1", "\u{1b}(", "\u{1b}"] {
            #expect(rest(text + "\u{1a}"), "\(text)")
        }
    }

    @Test func halfACharacterOutlivesControlsAndSequences() {
        #expect(!rest([0xF0, 0x9F, 0x07]))
        #expect(!rest([0xC3, 0x18]))
        #expect(!rest([0xC3] + Array("\u{1b}[1m".utf8)))
        // The next printable bytes finish it, whether they fit or not.
        #expect(!rest([0xF0, 0x9F, 0x07, 0x45]))
        #expect(rest([0xF0, 0x9F, 0x07, 0x45, 0x4E]))
        #expect(rest([0xC3, 0x18, 0x45]))
    }

    @Test func aHighByteInsideASequenceIsLostUntilAnEscapeOrSub() {
        let start: [UInt8] = Array("\u{1b}(".utf8) + [0xF0, 0x9F, 0x07]
        #expect(!rest(start))
        #expect(!rest(Array("\u{1b}]".utf8) + [0x9B, 0x07]))
        #expect(!rest(Array("\u{1b}P".utf8) + [0x9C]))
        // Text after the parser fell out of the sequence may have started a character.
        #expect(!rest(Array("\u{1b}(".utf8) + [0xF0, 0x9F] + Array("\u{1b}\\".utf8)))
        // Back in step, once the character it may have started is paid for.
        #expect(rest(start + Array("\u{1b}\\abc".utf8)))
        #expect(rest(start + [0x1A] + Array("abc".utf8)))
    }

    @Test func aCharacterInsideATitleDoesNotEndIt() {
        // The tail of this letter is 0x9C, which ends a DCS and not an OSC.
        #expect(!rest(Array("\u{1b}]0;".utf8) + [0xC5, 0x9C]))
        #expect(rest(Array("\u{1b}]0;".utf8) + [0xC3, 0x85] + Array("\u{7}".utf8)))
    }

    @Test func itCarriesAcrossChunks() {
        var parser = ParserRest()
        parser.advance(Array("\u{1b}]0;ti".utf8))
        #expect(!parser.isAtRest)
        parser.advance(Array("tle\u{7}".utf8))
        #expect(parser.isAtRest)
    }
}
