//
//  ComposerDraft.swift
//  Minnow
//

import UIKit

/// What the user has typed or attached but not yet sent.
struct ComposerDraft {
    var text = ""
    var image: UIImage?

    /// Records the composer text. While an earlier message is being edited the composer holds
    /// that message's text, so keep the user's pre-edit draft instead.
    mutating func recordText(_ inputText: String, preEditText: String?) {
        text = preEditText ?? inputText
    }
}
