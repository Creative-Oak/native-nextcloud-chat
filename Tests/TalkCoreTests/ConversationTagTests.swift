import Foundation
import Testing
@testable import TalkCore

struct ConversationTagTests {
    private let work = ConversationTag(id: "11", name: "Work", sortOrder: 1, isCollapsed: false, kind: .custom)
    private let family = ConversationTag(id: "12", name: "Family", sortOrder: 2, isCollapsed: true, kind: .custom)
    private let others = ConversationTag(id: "2", name: "Other", sortOrder: 99, isCollapsed: false, kind: .other)
    private let favourites = ConversationTag(id: "1", name: "Favorites", sortOrder: 0, isCollapsed: false, kind: .favorites)

    private func make(_ token: String, tags: [String] = [], favorite: Bool = false, archived: Bool = false) -> Conversation {
        var conversation = Conversation(token: token, type: .group, displayName: token, isFavorite: favorite, isArchived: archived)
        conversation.tagIDs = tags
        return conversation
    }

    @Test func conversationsAreSortedIntoTheirTagsInTheUsersOrder() {
        let sections = ConversationIndex.sections(for: [
            make("plan", tags: ["11"]),
            make("mum", tags: ["12"]),
            make("random"),
            make("star", favorite: true),
            make("old", archived: true)
        ], tags: [favourites, work, family, others])

        #expect(sections.map(\.title) == ["Favourites", "Work", "Family", "Other", "Archived"])
        #expect(sections.map { $0.items.map(\.token) } == [["star"], ["plan"], ["mum"], ["random"], ["old"]])
        #expect(sections[2].tag?.isCollapsed == true)
    }

    @Test func twoTagsMeanTwoSections() {
        let sections = ConversationIndex.sections(for: [make("both", tags: ["11", "12"])], tags: [work, family])
        #expect(sections.map(\.title) == ["Work", "Family"])
        #expect(Set(sections.map(\.id)).count == 2)
    }

    @Test func aTaggedFavouriteIsAmongTheFacesAndInItsTag() {
        let sections = ConversationIndex.sections(for: [make("star", tags: ["11"], favorite: true)], tags: [work])
        #expect(sections.map(\.section) == [.favorites, .tagged])
        #expect(sections.last?.items.map(\.token) == ["star"])
    }

    @Test func aTagThatIsGoneCountsAsNone() {
        let sections = ConversationIndex.sections(for: [make("stray", tags: ["99"])], tags: [work, others])
        #expect(sections.map(\.title) == ["Other"])
    }

    @Test func withoutTagsItIsTheUsualList() {
        let sections = ConversationIndex.sections(for: [make("a"), make("b", tags: ["11"])])
        #expect(sections.map(\.section) == [.conversations])
        #expect(sections[0].title == "Conversations")
    }

    @Test func tagsDecodeFromTheConversation() throws {
        let json = #"{"id":1,"token":"t","type":2,"name":"n","tagIds":["11","12"]}"#
        let conversation = try JSONDecoder().decode(ConversationDTO.self, from: Data(json.utf8)).model()
        #expect(conversation.tagIDs == ["11", "12"])
        let numbers = #"{"id":1,"token":"t","type":2,"name":"n","tagIds":[11]}"#
        #expect(try JSONDecoder().decode(ConversationDTO.self, from: Data(numbers.utf8)).model().tagIDs == ["11"])
    }
}
