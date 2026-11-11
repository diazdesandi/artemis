// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Accelerate
import Foundation
import NaturalLanguage
import Synchronization

/// on-device word meaning for local search: interns a corpus's words with their
/// embedding vectors, then scores every interned word against a typed one, 0…1
nonisolated final class WordMeaning {
    /// one model for every search; NLEmbedding isn't documented as thread-safe
    private static let embedding = Mutex(NLEmbedding.wordEmbedding(for: .english))

    private(set) var vocab: [String] = []
    private var index: [String: Int] = [:]
    /// unit vectors, row-major `vocab.count × dim`; zero rows for words the embedding lacks
    private var vectors: [Float] = []
    private let dim = embedding.withLock { $0?.dimension ?? 0 }

    static func knows(_ word: String) -> Bool { embedding.withLock { $0?.contains(word) == true } }

    /// lowercased words of `text`, without one-letter words and `dropping`
    static func words(_ text: String, dropping: Set<String>) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 1 && !dropping.contains($0) }
    }

    func intern(_ word: String) -> Int {
        if let i = index[word] { return i }
        index[word] = vocab.count
        vocab.append(word)
        vectors += Self.unitVector(word) ?? [Float](repeating: 0, count: dim)
        return vocab.count - 1
    }

    private static func unitVector(_ word: String) -> [Float]? {
        guard let v = embedding.withLock({ $0?.vector(for: word) }) else { return nil }
        let f = v.map(Float.init)
        let norm = sqrt(f.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? f.map { $0 / norm } : nil
    }

    /// `typed`'s score against every vocab word: 1 for itself, its lemma and
    /// `synonyms`, cosine similarity otherwise. `partial`: an unfinished word
    /// the embedding doesn't know matches 0.85 as a prefix
    func scores(_ typed: String, synonyms: [String] = [], partial: Bool) -> [Float] {
        var terms = [typed] + synonyms
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = typed
        if let lemma = tagger.tag(at: typed.startIndex, unit: .word, scheme: .lemma).0?.rawValue.lowercased(),
            lemma != typed
        {
            terms.append(lemma)
        }
        var scores = [Float](repeating: 0, count: vocab.count)
        for term in terms {
            guard let q = Self.unitVector(term) else { continue }
            var sims = [Float](repeating: 0, count: vocab.count)
            vDSP_mmul(vectors, 1, q, 1, &sims, 1, vDSP_Length(vocab.count), 1, vDSP_Length(dim))
            vDSP_vmax(scores, 1, sims, 1, &scores, 1, vDSP_Length(vocab.count))
        }
        let prefix = partial && synonyms.isEmpty && !Self.knows(typed)
        for (i, word) in vocab.enumerated() {
            if terms.contains(word) {
                scores[i] = 1
            } else if prefix, word.hasPrefix(typed) {
                scores[i] = max(scores[i], 0.85)
            }
        }
        return scores
    }
}
