import AppKit
import Foundation
import ObjectiveC
import QuartzCore

@MainActor enum ControllerNativeCursorAppearance {
    @MainActor struct Environment {
        let petLocation: @MainActor () -> CGPoint?
        let targetFrame: @MainActor (UInt32, CGFloat) -> CGRect?
        let hitWindow: @MainActor (CGPoint) -> UInt32
        let fade: @MainActor (NSWindow, CALayer?, @escaping @MainActor () -> Void) -> Void
        static var native: Self {
            .init(petLocation: { ControllerNativeCursorAppearance.petLocation() },
                targetFrame: { ControllerNativeCursorAppearance.targetFrame($0, primaryHeight:$1) },
                hitWindow: { ControllerNativeCursorAppearance.hitWindow($0) },
                fade: { ControllerNativeCursorAppearance.fade(window:$0,layer:$1,completion:$2) })
        }
    }
    static let fadeDuration: TimeInterval = 0.44
    static let blurRadius: Double = 7
    static let blurKeyPath = "filters.gaussianBlur.inputRadius"
    static let blurAnimationKey = "cursorBlurTransition"

    @MainActor private final class FadeCompletion {
        let window: NSWindow, layer: CALayer?, completion: @MainActor () -> Void
        init(window: NSWindow, layer: CALayer?, completion: @escaping @MainActor () -> Void) {
            self.window = window; self.layer = layer; self.completion = completion
        }
        func finish() {
            layer?.filters = (layer?.filters ?? []).filter { !isBlur($0) }
            withExtendedLifetime(window) { completion() }
        }
    }

    static func targetFrame(_ id: UInt32, primaryHeight: CGFloat) -> CGRect? {
        guard let info = WindowDescription.lookup(id), let raw = info[kCGWindowBounds as String] as? NSDictionary,
              let cg = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
        return .init(x:cg.minX,y:primaryHeight-cg.maxY,width:cg.width,height:cg.height)
    }
    static func petLocation() -> CGPoint? { RemoteHostedPIPPetLocation.position }
    static func hitWindow(_ point: CGPoint) -> UInt32 {
        UInt32(NSWindow.windowNumber(at:point,belowWindowWithWindowNumber:0))
    }
    private static func isBlur(_ filter: Any) -> Bool {
        guard let object = filter as? NSObject else { return false }
        // CAFilter exposes its filter type and animatable name through KVC.
        guard object.responds(to:NSSelectorFromString("type")) else { return false }
        return object.value(forKey:"type") as? String == "gaussianBlur"
    }
    @discardableResult static func setBlur(_ radius: Double, layer: CALayer?) -> Bool {
        guard let layer else { return false }
        var filters = layer.filters ?? []
        let filter: NSObject
        if let existing = filters.first(where:isBlur) as? NSObject { filter = existing }
        else {
            guard let type = NSClassFromString("CAFilter"),
                  let method = class_getClassMethod(type,NSSelectorFromString("filterWithType:")) else { return false }
            typealias Make = @convention(c) (AnyClass, Selector, NSString) -> Unmanaged<NSObject>?
            guard let object = unsafeBitCast(method_getImplementation(method),to:Make.self)(type,NSSelectorFromString("filterWithType:"),"gaussianBlur")?.takeUnretainedValue() else { return false }
            filter = object; filter.setValue("gaussianBlur",forKey:"name"); filters.append(object)
        }
        filter.setValue(radius,forKey:"inputRadius")
        layer.filters = filters
        return true
    }
    static func prepareHidden(window: NSWindow, layer: CALayer?) {
        window.alphaValue = 0; setBlur(blurRadius,layer:layer)
    }
    static func beginMotion(window: NSWindow, layer: CALayer?) {
        window.alphaValue = 1; setBlur(0,layer:layer)
    }
    static func fade(window: NSWindow, layer: CALayer?, completion: @escaping @MainActor () -> Void) {
        // Retain the window independently through this animation.
        let retained = FadeCompletion(window:window,layer:layer,completion:completion)
        window.alphaValue = 0; setBlur(0,layer:layer)
        if let layer {
            let animation = CABasicAnimation(keyPath:blurKeyPath)
            animation.fromValue = blurRadius; animation.toValue = 0
            animation.duration = fadeDuration; animation.timingFunction = .init(name:.easeInEaseOut)
            layer.add(animation,forKey:blurAnimationKey)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeDuration; context.timingFunction = .init(name:.easeInEaseOut)
            window.animator().alphaValue = 1
        },completionHandler:{
            MainActor.assumeIsolated {
                // Remove all GaussianBlur filters, preserving others.
                retained.finish()
            }
        })
    }
}
