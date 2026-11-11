import SwiftUI
import UIKit
import RemoteCore

struct Trackpad: UIViewRepresentable {
    @EnvironmentObject private var model: AppModel
    @Binding var touching: Bool
    func makeUIView(context: Context) -> TrackpadSurface { let v = TrackpadSurface(); configure(v); return v }
    func updateUIView(_ view: TrackpadSurface, context: Context) { configure(view); view.isUserInteractionEnabled = model.connected }
    private func configure(_ v: TrackpadSurface) {
        v.speed = model.pointerSpeed; v.natural = model.naturalScrolling
        v.onMotion = { model.input(.move(dx:$0,dy:$1)) }
        v.onScroll = { model.input(.scroll(dx:$0,dy:$1)) }
        v.onClick = { model.click($0) }; v.onDrag = { model.drag($0) }
        v.onRelease = { model.release() }; v.onTouching = { touching = $0 }
    }
    static func dismantleUIView(_ view: TrackpadSurface, coordinator: ()) { view.cancelGesture() }
}

final class TrackpadSurface: UIView {
    var speed = 1.3
    var natural = true
    var onMotion: ((Int,Int)->Void)?
    var onScroll: ((Int,Int)->Void)?
    var onClick: ((String)->Void)?
    var onDrag: ((Bool)->Void)?
    var onRelease: (()->Void)?
    var onTouching: ((Bool)->Void)?
    private var fingers: Set<UITouch> = []
    private var started: TimeInterval = 0
    private var moved = 0.0
    private var wasTwo = false
    private var dragging = false
    private var longPress: Timer?
    private var link: CADisplayLink?
    private var motion = MotionAccumulator()
    private var scroll = MotionAccumulator()
    private var pendingMotion = CGPoint.zero
    private var pendingScroll = CGPoint.zero
    override init(frame: CGRect) {
        super.init(frame:frame); isMultipleTouchEnabled = true; backgroundColor = .clear
        isAccessibilityElement = true; accessibilityLabel = "Trackpad"
        accessibilityHint = "Move one finger to move the pointer. Tap to click. Use two fingers to scroll or tap to right-click. Hold to drag."
        accessibilityIdentifier = "trackpad"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name:"Left click",target:self,selector:#selector(accessibleClick)),UIAccessibilityCustomAction(name:"Right click",target:self,selector:#selector(accessibleRightClick)),UIAccessibilityCustomAction(name:"Scroll up",target:self,selector:#selector(accessibleUp)),UIAccessibilityCustomAction(name:"Scroll down",target:self,selector:#selector(accessibleDown))]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func accessibleClick() -> Bool { onClick?("left"); return true }
    @objc private func accessibleRightClick() -> Bool { onClick?("right"); return true }
    @objc private func accessibleUp() -> Bool { onScroll?(0,120); return true }
    @objc private func accessibleDown() -> Bool { onScroll?(0,-120); return true }
    @objc private func flush() {
        let (x,y) = motion.consume(dx:Double(pendingMotion.x),dy:Double(pendingMotion.y),scale:speed)
        pendingMotion = .zero; if x != 0 || y != 0 { onMotion?(x,y) }
        let direction = natural ? 1.0 : -1.0
        let (sx,sy) = scroll.consume(dx:Double(pendingScroll.x),dy:Double(pendingScroll.y),scale:3.2*direction)
        pendingScroll = .zero; if sx != 0 || sy != 0 { onScroll?(sx,sy) }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if fingers.isEmpty {
            started = touches.first?.timestamp ?? 0; moved = 0; wasTwo = false; motion.reset(); scroll.reset(); onTouching?(true)
            let l = CADisplayLink(target:self,selector:#selector(flush)); l.preferredFrameRateRange = CAFrameRateRange(minimum:60,maximum:120,preferred:120); l.add(to:.main,forMode:.common); link = l
            longPress = Timer.scheduledTimer(withTimeInterval:0.35,repeats:false) { [weak self] _ in
                guard let self, self.fingers.count == 1, !self.wasTwo, self.moved < 6 else { return }
                self.flush(); self.dragging = true; self.onDrag?(true)
            }
        }
        fingers.formUnion(touches)
        if fingers.count > 1 { wasTwo = true; longPress?.invalidate(); if dragging { flush(); dragging = false; onDrag?(false) } }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !fingers.isEmpty else { return }
        var dx = 0.0, dy = 0.0
        for t in touches { let a = t.preciseLocation(in:self), b = t.previousLocation(in:self); dx += Double(a.x-b.x); dy += Double(a.y-b.y) }
        // Divide by all current fingers; stationary fingers contribute zero.
        dx /= Double(fingers.count); dy /= Double(fingers.count)
        moved += hypot(dx,dy)
        if moved >= 6 { longPress?.invalidate() }
        if fingers.count == 2 { pendingScroll.x += dx; pendingScroll.y += dy }
        else if fingers.count == 1 && !wasTwo { pendingMotion.x += dx; pendingMotion.y += dy }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        flush(); fingers.subtract(touches)
        guard fingers.isEmpty else { return }
        let elapsed = (touches.first?.timestamp ?? started)-started
        if dragging { dragging = false; onDrag?(false) }
        else if elapsed < 0.3 && moved < 6 { onClick?(wasTwo ? "right" : "left") }
        stop()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelGesture() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancelGesture() } }
    func cancelGesture() { if dragging || !fingers.isEmpty { onRelease?() }; dragging = false; fingers.removeAll(); pendingMotion = .zero; pendingScroll = .zero; stop() }
    private func stop() { longPress?.invalidate(); longPress = nil; link?.invalidate(); link = nil; onTouching?(false) }
}
