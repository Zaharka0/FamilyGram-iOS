import Foundation
import UIKit
import TelegramCore
import AccountContext
import SwiftSignalKit
import ChatHistoryEntry

final class FGChatPresentation {
    static func entries(_ source: [ChatHistoryEntry]) -> [ChatHistoryEntry] {
        return source.compactMap { entry in
            switch entry {
            case let .MessageEntry(raw, presentation, read, location, selection, attributes):
                guard raw.id.peerId.namespace != Namespaces.Peer.SecretChat, raw.forwardInfo == nil,
                      FGStore.safe(EngineMessage(raw)), let op = FGCore.fromMessage(raw.text) else { return entry }
                guard op.kind == "hug" else { return nil }
                return .MessageEntry(raw.withUpdatedText(FGCore.visible(raw.text)), presentation, read, location, selection, attributes)
            case let .MessageGroupEntry(key, group, presentation):
                let filtered = group.compactMap { item -> (EngineRawMessage, Bool, ChatHistoryMessageSelection, ChatMessageEntryAttributes, EngineMessageHistoryEntryLocation?)? in
                    let (raw, read, selection, attributes, location) = item
                    guard raw.id.peerId.namespace != Namespaces.Peer.SecretChat, raw.forwardInfo == nil,
                          FGStore.safe(EngineMessage(raw)), let op = FGCore.fromMessage(raw.text) else { return item }
                    guard op.kind == "hug" else { return nil }
                    return (raw.withUpdatedText(FGCore.visible(raw.text)), read, selection, attributes, location)
                }
                return filtered.isEmpty ? nil : .MessageGroupEntry(key, filtered, presentation)
            default: return entry
            }
        }
    }
}

final class FGReactions {
    static func random(context: AccountContext, message: EngineMessage) {
        let store = FGStore.get(context)
        guard message.id.peerId == store.id(store.partner), store.accept("reaction:\(message.id.id)", delay: 0.8) else { return }
        let _ = (context.engine.stickers.availableReactions() |> take(1) |> deliverOnMainQueue).start(next: { reactions in
            let allowed = reactions?.reactions.compactMap { reaction -> String? in
                guard reaction.isEnabled, !reaction.isPremium, case let .builtin(value) = reaction.value, ["❤", "❤‍🔥", "💋"].contains(value) else { return nil }; return value
            } ?? []
            guard let value = allowed.randomElement() else { return }
            context.engine.messages.setMessageReactions(ids: [message.id], reactions: [.builtin(value)])
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        })
    }
}
