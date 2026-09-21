import SwiftUI
import Testing
@testable import Pepito

@Test func conversationFollowsResponsesUnlessUserScrollsAway() {
    var scroll = ConversationScrollFollowing()
    // Un nouveau morceau de réponse éloigne temporairement le bas : le suivi reste actif.
    scroll.geometryChanged(atBottom: false)
    #expect(scroll.followsBottom)
    scroll.phaseChanged(.interacting, atBottom: true)
    #expect(!scroll.followsBottom)
    scroll.geometryChanged(atBottom: false)
    scroll.phaseChanged(.decelerating, atBottom: false)
    scroll.phaseChanged(.idle, atBottom: false)
    #expect(!scroll.followsBottom)
    // Ni une réponse ni une modification du contenu ne doivent reprendre le contrôle.
    scroll.geometryChanged(atBottom: true)
    scroll.phaseChanged(.idle, atBottom: true)
    #expect(!scroll.followsBottom)
    // Le retour manuel en bas réactive le suivi.
    scroll.phaseChanged(.interacting, atBottom: false)
    scroll.geometryChanged(atBottom: true)
    #expect(scroll.followsBottom)
    scroll.phaseChanged(.idle, atBottom: true)
    scroll.geometryChanged(atBottom: false)
    #expect(scroll.followsBottom)
    // Un clic sans déplacement ne désactive pas durablement le suivi.
    scroll.phaseChanged(.tracking, atBottom: true)
    scroll.phaseChanged(.idle, atBottom: true)
    #expect(scroll.followsBottom)
}
