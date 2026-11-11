import Foundation

/// Carries fractional movement forward so a slow finger never feels sticky.
public struct MotionAccumulator: Sendable {
    private var x = 0.0
    private var y = 0.0
    public init() {}
    public mutating func consume(dx: Double, dy: Double, scale: Double = 1) -> (Int, Int) {
        guard dx.isFinite, dy.isFinite, scale.isFinite else { return (0,0) }
        x += dx * scale; y += dy * scale
        let a = Int(min(10000,max(-10000,x.rounded(.towardZero))))
        let b = Int(min(10000,max(-10000,y.rounded(.towardZero))))
        x -= Double(a); y -= Double(b)
        return (a,b)
    }
    public mutating func reset() { x = 0; y = 0 }
}

public struct TypingEdit: Equatable, Sendable {
    public let backspaces: Int
    public let insertion: String
    public static func between(_ old: String, _ new: String) -> TypingEdit {
        let a = Array(old), b = Array(new)
        var n = 0
        while n < a.count && n < b.count && a[n] == b[n] { n += 1 }
        return TypingEdit(backspaces: a.count-n, insertion: String(b.dropFirst(n)))
    }
    public var commands: [Command] {
        var result = Array(repeating: Command.key("backspace"), count: min(backspaces,128))
        var chunk = ""
        for c in insertion {
            if (chunk + String(c)).utf16.count > 2048 { result.append(.text(chunk)); chunk = "" }
            chunk.append(c)
        }
        if !chunk.isEmpty { result.append(.text(chunk)) }
        return result
    }
}

/// An ordered, bounded input queue. Adjacent motion coalesces without crossing
/// a mouse-down/up or keystroke boundary; a slow network cannot replay a trail.
public struct InputQueue: Sendable {
    private var items: [Command] = []
    public init() {}
    public var count: Int { items.count }
    public mutating func append(_ c: Command) -> Bool {
        if let last = items.last, c.id == nil, last.id == nil, c.op == last.op, c.op == "mouse.move" || c.op == "mouse.scroll" {
            let dx = (last.dx ?? 0) + (c.dx ?? 0), dy = (last.dy ?? 0) + (c.dy ?? 0)
            if abs(dx) <= 10000 && abs(dy) <= 10000 { items[items.count-1] = c.op == "mouse.move" ? .move(dx:dx,dy:dy) : .scroll(dx:dx,dy:dy); return true }
        }
        guard items.count < 64 else { return false }
        items.append(c); return true
    }
    public mutating func popFirst() -> Command? { items.isEmpty ? nil : items.removeFirst() }
    public mutating func clear() { items.removeAll(keepingCapacity: true) }
}
