import CoreGraphics
import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What JS sends for one request (see src/lib/engines/apple.ts).
struct IntelPayload: Decodable {
  struct Box: Decodable { let x: Double; let y: Double; let w: Double; let h: Double }
  struct Mark: Decodable { let mark: Int; let kind: String; let text: String?; let box: Box }
  struct Turn: Decodable { let question: String; let answer: String }

  let imageUri: String
  let lens: String
  let hint: String?
  let question: String?
  let walkthrough: Bool
  let history: [Turn]
  let marks: [Mark]
}

/// Entry points that compile on any SDK and degrade cleanly below iOS 26.
enum IntelligenceBridge {
  static func status() -> [String: Any] {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available:
        return ["available": true, "images": imagesSupported(), "reason": ""]
      case .unavailable(let reason):
        return ["available": false, "images": false, "reason": describe(reason)]
      }
    }
    #endif
    return ["available": false, "images": false, "reason": "Needs iOS 26 or later with Apple Intelligence."]
  }

  static func start(requestId: String, json: String, emit: @escaping ([String: Any]) -> Void) throws {
    guard let data = json.data(using: .utf8) else { throw LensiError.unavailable("Bad request.") }
    let payload = try JSONDecoder().decode(IntelPayload.self, from: data)
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      IntelligenceRunner.shared.start(id: requestId, payload: payload, emit: emit)
      return
    }
    #endif
    throw LensiError.unavailable("Apple Intelligence needs iOS 26 or later.")
  }

  static func cancel(requestId: String) {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      IntelligenceRunner.shared.cancel(id: requestId)
    }
    #endif
  }

  static func imagesSupported() -> Bool {
    if #available(iOS 27.0, *) { return true }
    return false
  }

  #if canImport(FoundationModels)
  @available(iOS 26.0, *)
  static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
    switch reason {
    case .deviceNotEligible: return "This iPhone doesn't support Apple Intelligence."
    case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings."
    case .modelNotReady: return "Apple Intelligence is still downloading."
    @unknown default: return "Apple Intelligence is unavailable."
    }
  }
  #endif
}

/// Numbered circles drawn on the photo so a model can point by number
/// (set-of-marks prompting). The numbers match Region.mark on the JS side.
enum SetOfMarks {
  static let pen = UIColor(red: 0.894, green: 1, blue: 0.31, alpha: 1)

  static func draw(on image: CGImage, marks: [IntelPayload.Mark]) -> CGImage {
    guard !marks.isEmpty else { return image }
    let w = CGFloat(image.width)
    let h = CGFloat(image.height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
    let out = renderer.image { ctx in
      UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: w, height: h))
      let r = max(11, min(w, h) * 0.022)
      let font = UIFont.systemFont(ofSize: r * 1.15, weight: .heavy)
      let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
      for m in marks {
        let c = CGPoint(x: CGFloat(m.box.x + m.box.w / 2) * w, y: CGFloat(m.box.y + m.box.h / 2) * h)
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
        ctx.cgContext.fillEllipse(in: rect.insetBy(dx: -2, dy: -2))
        ctx.cgContext.setFillColor(pen.cgColor)
        ctx.cgContext.fillEllipse(in: rect)
        let label = "\(m.mark)" as NSString
        let size = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
      }
    }
    return out.cgImage ?? image
  }

  static func place(_ b: IntelPayload.Box) -> String {
    let cx = b.x + b.w / 2
    let cy = b.y + b.h / 2
    let v = cy < 0.33 ? "top" : cy > 0.67 ? "bottom" : "middle"
    let hz = cx < 0.33 ? "left" : cx > 0.67 ? "right" : "center"
    return v == "middle" && hz == "center" ? "center" : "\(v) \(hz)"
  }
}

#if canImport(FoundationModels)

// MARK: - Schemas

@available(iOS 26.0, *)
@Generable(description: "Labels for a photo someone just took")
struct LensiAnnotation {
  @Guide(description: "What the main thing is, 1 to 4 words, as specific as you can tell")
  var title: String

  @Guide(description: "One sentence of at most 16 words: the most useful thing to know right now")
  var summary: String

  @Guide(description: "Marked parts worth labelling, most important first", .maximumCount(5))
  var callouts: [LensiCallout]

  @Guide(description: "Short specific facts for the lens, each under 15 words", .maximumCount(3))
  var facts: [String]

  @Guide(description: "Two short questions the user is likely to ask next about this thing, each under 9 words", .maximumCount(2))
  var followUps: [String]
}

@available(iOS 26.0, *)
@Generable
struct LensiCallout {
  @Guide(description: "The number of the mark this label belongs to")
  var mark: Int

  @Guide(description: "Label for that part, 1 to 3 words")
  var label: String
}

@available(iOS 26.0, *)
@Generable(description: "A short walkthrough the user can follow with the thing in front of them")
struct LensiGuide {
  @Guide(description: "What the thing is, 1 to 4 words")
  var title: String

  @Guide(description: "Steps in order", .maximumCount(8))
  var steps: [LensiStep]
}

@available(iOS 26.0, *)
@Generable
struct LensiStep {
  @Guide(description: "One instruction in the imperative, at most 14 words")
  var instruction: String

  @Guide(description: "Number of the mark to act on, or 0 if none fits")
  var mark: Int
}

@available(iOS 26.0, *)
@Generable(description: "An answer to a question about the photo")
struct LensiAnswer {
  @Guide(description: "The answer in one to three short sentences", .maximumCount(3))
  var sentences: [String]

  @Guide(description: "Marked parts the answer refers to", .maximumCount(3))
  var callouts: [LensiCallout]
}

// MARK: - Runner

@available(iOS 26.0, *)
final class IntelligenceRunner: @unchecked Sendable {
  static let shared = IntelligenceRunner()
  private var tasks: [String: Task<Void, Never>] = [:]
  private let lock = NSLock()

  func start(id: String, payload: IntelPayload, emit: @escaping ([String: Any]) -> Void) {
    // Registered under the lock before the task can run, so a task that ends
    // at once can't remove itself before it was added (leaving a dead entry).
    lock.lock()
    defer { lock.unlock() }
    tasks[id] = Task.detached(priority: .userInitiated) {
      do {
        try await IntelligenceRunner.run(payload) { event in
          emit(["requestId": id, "type": "event", "event": event])
        }
        if !Task.isCancelled { emit(["requestId": id, "type": "done"]) }
      } catch is CancellationError {
        // Cancelled from JS; nothing to report.
      } catch {
        if !Task.isCancelled {
          emit(["requestId": id, "type": "error", "message": IntelligenceRunner.message(for: error)])
        }
      }
      IntelligenceRunner.shared.remove(id)
    }
  }

  func cancel(id: String) {
    lock.lock()
    tasks[id]?.cancel()
    tasks[id] = nil
    lock.unlock()
  }

  private func remove(_ id: String) {
    lock.lock()
    tasks[id] = nil
    lock.unlock()
  }

  static func run(_ p: IntelPayload, emit: @escaping ([String: Any]) -> Void) async throws {
    let image = try Analyzer.loadUpright(uri: p.imageUri, maxSide: 1280)
    let marked = SetOfMarks.draw(on: image, marks: p.marks)
    let session = LanguageModelSession(instructions: instructions(for: p))
    let prompt = makePrompt(text: promptText(for: p), image: marked)
    let valid = Set(p.marks.map(\.mark))

    if p.walkthrough {
      let stream = session.streamResponse(to: prompt, generating: LensiGuide.self, options: GenerationOptions(temperature: 0.3))
      var out = GuideEmitter(valid: valid, emit: emit)
      var last: LensiGuide.PartiallyGenerated?
      for try await snapshot in stream {
        try Task.checkCancellation()
        out.update(snapshot.content, final: false)
        last = snapshot.content
      }
      if let last { out.update(last, final: true) }
    } else if let q = p.question, !q.isEmpty {
      let stream = session.streamResponse(to: prompt, generating: LensiAnswer.self, options: GenerationOptions(temperature: 0.4))
      var out = AnswerEmitter(valid: valid, emit: emit)
      var last: LensiAnswer.PartiallyGenerated?
      for try await snapshot in stream {
        try Task.checkCancellation()
        out.update(snapshot.content, final: false)
        last = snapshot.content
      }
      if let last { out.update(last, final: true) }
    } else {
      let stream = session.streamResponse(to: prompt, generating: LensiAnnotation.self, options: GenerationOptions(temperature: 0.4))
      var out = AnnotationEmitter(valid: valid, emit: emit)
      var last: LensiAnnotation.PartiallyGenerated?
      for try await snapshot in stream {
        try Task.checkCancellation()
        out.update(snapshot.content, final: false)
        last = snapshot.content
      }
      if let last { out.update(last, final: true) }
    }
  }

  /// iOS 27 sees the marked photo itself; iOS 26 reasons over the mark list.
  static func makePrompt(text: String, image: CGImage) -> Prompt {
    if #available(iOS 27.0, *) {
      return Prompt {
        text
        Attachment(image)
      }
    }
    return Prompt {
      text
    }
  }

  static func instructions(for p: IntelPayload) -> String {
    """
    You are Lensi, a camera assistant. Someone just pointed their phone at something; help them understand it or do something with it.
    The photo has small numbered circles drawn on things the phone found, and a list says what each number is. Point at parts only by those numbers, and never use a number that isn't in the list. Use 0 when no number fits.
    Be specific, practical and brief. No hedging, no markdown.
    \(lensBrief(p.lens))
    """
  }

  static func lensBrief(_ lens: String) -> String {
    switch lens {
    case "guide": return "Focus: how to use it, step by step."
    case "fix": return "Focus: what might be wrong and how to fix it. Point at controls, ports and parts."
    case "shop": return "Focus: whether it is worth buying: rough price, what to check, an alternative."
    case "safe": return "Focus: safety: hazards, allergens, warnings, expiry. Say so plainly if nothing is concerning."
    case "learn": return "Focus: how it works and why, in plain words."
    default: return "Focus: what it is, what it is for, and one interesting detail."
    }
  }

  static func promptText(for p: IntelPayload) -> String {
    var lines: [String] = ["Numbered marks on the photo:"]
    if p.marks.isEmpty { lines.append("(none)") }
    for m in p.marks {
      let what: String
      switch m.kind {
      case "text": what = "text \"\(m.text ?? "")\""
      case "barcode": what = "barcode \"\(m.text ?? "")\""
      default: what = m.text.map { "\(m.kind) (\($0))" } ?? m.kind
      }
      lines.append("\(m.mark): \(what), \(SetOfMarks.place(m.box))")
    }
    if let hint = p.hint, !hint.isEmpty {
      lines.append("The phone's quick guess for the main thing: \"\(hint)\" (it may be wrong).")
    }
    for t in p.history.suffix(3) {
      lines.append("Earlier question: \(t.question)\nEarlier answer: \(t.answer)")
    }
    if p.walkthrough {
      let goal = (p.question?.isEmpty == false) ? p.question! : "using this"
      lines.append("Write a short step-by-step walkthrough for: \(goal). Give each step the number of the mark to act on.")
    } else if let q = p.question, !q.isEmpty {
      lines.append("Their question: \(q)")
      lines.append("Answer in one to three short sentences, and point at marked parts if that helps.")
    } else {
      lines.append("Say what this is, give the most useful one-line summary, label the marked parts worth knowing, and add a few facts.")
    }
    return lines.joined(separator: "\n")
  }

  static func message(for error: Error) -> String {
    if let e = error as? LanguageModelSession.GenerationError {
      switch e {
      case .guardrailViolation: return "That one is off limits for the on-device model."
      case .exceededContextWindowSize: return "Too much to think about at once. Try a simpler question."
      case .unsupportedLanguageOrLocale: return "The on-device model doesn't speak this language yet."
      case .assetsUnavailable: return "Apple Intelligence is still getting ready. Try again shortly."
      case .rateLimited: return "Apple Intelligence is busy. Try again in a moment."
      case .refusal: return "The on-device model chose not to answer that."
      default: return "Apple Intelligence couldn't answer that one."
      }
    }
    return error.localizedDescription
  }
}

// MARK: - Streaming emitters
//
// Snapshots are partial: strings grow token by token. A field is only sent
// once it is finished, i.e. once the model has moved on to the next field or
// array element (or the stream ended), so labels land whole.

@available(iOS 26.0, *)
private struct AnnotationEmitter {
  let valid: Set<Int>
  let emit: ([String: Any]) -> Void
  var titleSent = false
  var summarySent = false
  var callouts = 0
  var facts = 0
  var followUps = 0

  mutating func update(_ c: LensiAnnotation.PartiallyGenerated, final: Bool) {
    if !titleSent, let t = c.title, c.summary != nil || final {
      titleSent = true
      if !t.isEmpty { emit(["kind": "title", "text": t]) }
    }
    if !summarySent, let s = c.summary, c.callouts != nil || final {
      summarySent = true
      if !s.isEmpty { emit(["kind": "summary", "text": s]) }
    }
    if let list = c.callouts {
      let ready = (final || c.facts != nil) ? list.count : max(0, list.count - 1)
      while callouts < ready {
        let k = list[callouts]
        callouts += 1
        guard let label = k.label, !label.isEmpty else { continue }
        var e: [String: Any] = ["kind": "callout", "label": label]
        if let m = k.mark, valid.contains(m) { e["mark"] = m }
        emit(e)
      }
    }
    if let list = c.facts {
      let ready = (final || c.followUps != nil) ? list.count : max(0, list.count - 1)
      while facts < ready {
        let f = list[facts]
        facts += 1
        if !f.isEmpty { emit(["kind": "fact", "text": f]) }
      }
    }
    if let list = c.followUps {
      let ready = final ? list.count : max(0, list.count - 1)
      while followUps < ready {
        let q = list[followUps]
        followUps += 1
        if !q.isEmpty { emit(["kind": "suggest", "text": q]) }
      }
    }
  }
}

@available(iOS 26.0, *)
private struct GuideEmitter {
  let valid: Set<Int>
  let emit: ([String: Any]) -> Void
  var titleSent = false
  var steps = 0

  mutating func update(_ c: LensiGuide.PartiallyGenerated, final: Bool) {
    if !titleSent, let t = c.title, c.steps != nil || final {
      titleSent = true
      if !t.isEmpty { emit(["kind": "title", "text": t]) }
    }
    if let list = c.steps {
      let ready = final ? list.count : max(0, list.count - 1)
      while steps < ready {
        let s = list[steps]
        steps += 1
        guard let text = s.instruction, !text.isEmpty else { continue }
        var e: [String: Any] = ["kind": "step", "text": text]
        if let m = s.mark, valid.contains(m) { e["mark"] = m }
        emit(e)
      }
    }
  }
}

@available(iOS 26.0, *)
private struct AnswerEmitter {
  let valid: Set<Int>
  let emit: ([String: Any]) -> Void
  var sentences = 0
  var callouts = 0

  mutating func update(_ c: LensiAnswer.PartiallyGenerated, final: Bool) {
    if let list = c.sentences {
      let ready = (final || c.callouts != nil) ? list.count : max(0, list.count - 1)
      while sentences < ready {
        let s = list[sentences]
        sentences += 1
        if !s.isEmpty { emit(["kind": "answer", "text": s]) }
      }
    }
    if let list = c.callouts {
      let ready = final ? list.count : max(0, list.count - 1)
      while callouts < ready {
        let k = list[callouts]
        callouts += 1
        guard let label = k.label, !label.isEmpty else { continue }
        var e: [String: Any] = ["kind": "callout", "label": label]
        if let m = k.mark, valid.contains(m) { e["mark"] = m }
        emit(e)
      }
    }
  }
}

#endif
