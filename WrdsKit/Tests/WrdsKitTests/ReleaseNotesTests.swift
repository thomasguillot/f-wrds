import Foundation
import Testing
@testable import WrdsKit

@Suite struct ReleaseNotesTests {
    @Test func parsesHeadingsBulletsAndParagraphs() {
        let blocks = ReleaseNotes.blocks(from: """
        ## What's new

        - **Snippets** — organise them into groups.
        - Fragments.

        A closing paragraph.
        """)
        #expect(blocks == [
            .heading(level: 2, text: "What's new"),
            .bullet("**Snippets** — organise them into groups."),
            .bullet("Fragments."),
            .paragraph("A closing paragraph."),
        ])
    }

    @Test func joinsWrappedParagraphLines() {
        let blocks = ReleaseNotes.blocks(from: "One line\nand its continuation.")
        #expect(blocks == [.paragraph("One line and its continuation.")])
    }

    @Test func joinsIndentedBulletContinuation() {
        let blocks = ReleaseNotes.blocks(from: "- A bullet that\n  wraps onto a second line.")
        #expect(blocks == [.bullet("A bullet that wraps onto a second line.")])
    }

    @Test func unindentedLineAfterBulletStartsAParagraph() {
        let blocks = ReleaseNotes.blocks(from: "- A bullet.\nNot a continuation.")
        #expect(blocks == [.bullet("A bullet."), .paragraph("Not a continuation.")])
    }

    @Test func handlesCRLF() {
        let blocks = ReleaseNotes.blocks(from: "## Title\r\n\r\n- One\r\n")
        #expect(blocks == [.heading(level: 2, text: "Title"), .bullet("One")])
    }

    @Test func treatsAsteriskBulletsLikeDashes() {
        #expect(ReleaseNotes.blocks(from: "* Starred") == [.bullet("Starred")])
    }

    @Test func hashWithoutSpaceIsNotAHeading() {
        #expect(ReleaseNotes.blocks(from: "#hashtag not a heading")
                == [.paragraph("#hashtag not a heading")])
    }

    // MARK: Updater noise — irrelevant to someone already running the app

    @Test func stripsInstallSectionUpToTheNextTopLevelHeading() {
        let blocks = ReleaseNotes.blocks(from: """
        ## What's new

        - A change.

        ## Install (unsigned app)

        1. Double-click the app.
        2. Open Anyway.

        ### A nested step

        More install detail.

        ## After install

        Kept.
        """)
        #expect(blocks == [
            .heading(level: 2, text: "What's new"),
            .bullet("A change."),
            .heading(level: 2, text: "After install"),
            .paragraph("Kept."),
        ])
    }

    @Test func stripsRequiresMacOSLine() {
        let blocks = ReleaseNotes.blocks(from: """
        Real content.

        **Requires macOS 26 (Tahoe) or later · Apple Silicon**.
        """)
        #expect(blocks == [.paragraph("Real content.")])
    }

    @Test func stripsChecksumLabelAndDigest() {
        let blocks = ReleaseNotes.blocks(from: """
        Real content.

        **DMG SHA-256**
        `22c32bf146a71783ce3623d6137bc4ed99d4afe5b8697627e14157cd0299a709`
        """)
        #expect(blocks == [.paragraph("Real content.")])
    }

    @Test func keepsOrdinaryInlineCode() {
        let blocks = ReleaseNotes.blocks(from: "Edit `snippets.json` directly.")
        #expect(blocks == [.paragraph("Edit `snippets.json` directly.")])
    }

    @Test func emptyBodyYieldsNoBlocks() {
        #expect(ReleaseNotes.blocks(from: "").isEmpty)
        #expect(ReleaseNotes.blocks(from: "\n\n  \n").isEmpty)
    }

    // MARK: Checksum

    @Test func readsChecksumUnderItsLabel() {
        let body = """
        ## What's new

        - Something.

        **DMG SHA-256**
        `22C32BF146A71783CE3623D6137BC4ED99D4AFE5B8697627E14157CD0299A709`
        """
        #expect(ReleaseNotes.checksum(from: body)
            == "22c32bf146a71783ce3623d6137bc4ed99d4afe5b8697627e14157cd0299a709")
    }

    @Test func readsChecksumOnTheLabelLine() {
        let body = "**DMG SHA-256**: `22c32bf146a71783ce3623d6137bc4ed99d4afe5b8697627e14157cd0299a709`"
        #expect(ReleaseNotes.checksum(from: body)
            == "22c32bf146a71783ce3623d6137bc4ed99d4afe5b8697627e14157cd0299a709")
    }

    @Test func readsAnUnlabelledLoneDigest() {
        let body = "Notes.\n\n`22c32bf146a71783ce3623d6137bc4ed99d4afe5b8697627e14157cd0299a709`"
        #expect(ReleaseNotes.checksum(from: body)
            == "22c32bf146a71783ce3623d6137bc4ed99d4afe5b8697627e14157cd0299a709")
    }

    @Test func ignoresHashesThatAreNotSHA256() {
        // A git revision is 40 hex characters, and reading one as a checksum would fail every
        // download against a number that was never about the image.
        #expect(ReleaseNotes.checksum(from: "Built from `1a2b3c4d5e6f70819293a4b5c6d7e8f901234567`.") == nil)
        #expect(ReleaseNotes.checksum(from: "**DMG SHA-256**\n`deadbeef`") == nil)
    }

    @Test func absentChecksumIsNil() {
        #expect(ReleaseNotes.checksum(from: "## What's new\n\n- Something.") == nil)
        #expect(ReleaseNotes.checksum(from: "") == nil)
    }

    @Test func aLabelOnlyPromisesTheVeryNextLine() {
        // A digest three paragraphs below a stale label is not that label's digest.
        let body = """
        **DMG SHA-256**

        Some prose in between.

        Then 22c32bf146a71783ce3623d6137bc4ed99d4afe5b8697627e14157cd0299a709 bare.
        """
        #expect(ReleaseNotes.checksum(from: body) == nil)
    }
}
