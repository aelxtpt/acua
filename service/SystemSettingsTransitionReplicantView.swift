import AppKit

/// The fixed screen window contains this replica of the System Settings window.
@MainActor final class SystemSettingsTransitionReplicantView: NSView {
    let replicaContainer = NSView()
    let clippingView = NSView()
    let strokeOverlayView = NSView()
    let destinationShadow = CALayer()
    let keyShadow = CALayer()
    let ambientShadow = CALayer()
    let stroke = CAShapeLayer()
    let artwork: NSView
    private(set) var cornerRadius: CGFloat = 24

    init(frame: CGRect, artwork: NSView) {
        self.artwork = artwork
        super.init(frame: frame)
        wantsLayer = true
        replicaContainer.wantsLayer = true
        replicaContainer.layer?.masksToBounds = false
        replicaContainer.translatesAutoresizingMaskIntoConstraints = true
        addSubview(replicaContainer)
        configureShadow(destinationShadow, radius: 2, offset: -3, opacity: 0.06)
        configureShadow(keyShadow, radius: 15, offset: -5, opacity: 0.09)
        configureShadow(ambientShadow, radius: 3, offset: 0, opacity: 0.2)
        destinationShadow.opacity = 0
        clippingView.wantsLayer = true
        clippingView.layer?.masksToBounds = false
        clippingView.layer?.cornerRadius = cornerRadius
        clippingView.translatesAutoresizingMaskIntoConstraints = false
        replicaContainer.addSubview(clippingView)
        strokeOverlayView.wantsLayer = true
        strokeOverlayView.layer?.masksToBounds = false
        strokeOverlayView.layer?.cornerRadius = cornerRadius
        strokeOverlayView.translatesAutoresizingMaskIntoConstraints = true
        stroke.fillColor = NSColor.clear.cgColor
        stroke.strokeColor = NSColor.black.cgColor
        stroke.lineWidth = 0.5
        stroke.opacity = 0
        strokeOverlayView.layer?.addSublayer(stroke)
        replicaContainer.addSubview(strokeOverlayView)
        artwork.translatesAutoresizingMaskIntoConstraints = false
        clippingView.addSubview(artwork)
        NSLayoutConstraint.activate([
            clippingView.topAnchor.constraint(equalTo: replicaContainer.topAnchor, constant: 30),
            clippingView.bottomAnchor.constraint(equalTo: replicaContainer.bottomAnchor, constant: -30),
            clippingView.leadingAnchor.constraint(equalTo: replicaContainer.leadingAnchor, constant: 30),
            clippingView.trailingAnchor.constraint(equalTo: replicaContainer.trailingAnchor, constant: -30),
            artwork.topAnchor.constraint(equalTo: clippingView.topAnchor),
            artwork.bottomAnchor.constraint(equalTo: clippingView.bottomAnchor),
            artwork.leadingAnchor.constraint(equalTo: clippingView.leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: clippingView.trailingAnchor)
        ])
        updatePaths()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureShadow(_ shadow: CALayer, radius: CGFloat, offset: CGFloat, opacity: Float) {
        shadow.backgroundColor = NSColor.clear.cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = opacity
        shadow.shadowOffset = CGSize(width: 0, height: offset)
        shadow.shadowRadius = radius
        shadow.masksToBounds = false
        shadow.mask = CAShapeLayer()
        replicaContainer.layer?.addSublayer(shadow)
    }

    static func containerFrame(for frame: CGRect, on screen: CGRect) -> CGRect {
        CGRect(x: frame.origin.x - screen.origin.x - 30,
               y: frame.origin.y - screen.origin.y - 30,
               width: frame.width + 60, height: frame.height + 60).integral
    }

    func setReplicaFrame(_ frame: CGRect, on screen: CGRect) {
        replicaContainer.frame = Self.containerFrame(for: frame, on: screen)
        replicaContainer.layoutSubtreeIfNeeded()
        updatePaths()
    }

    func setCornerRadius(_ radius: CGFloat) {
        cornerRadius = radius
        for view in [replicaContainer, clippingView, strokeOverlayView] { view.layer?.cornerRadius = radius }
        updatePaths()
    }

    func setProgress(_ progress: Double) {
        let appearance = SystemSettingsTransitionAppearance(progress: progress)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        destinationShadow.opacity = appearance.destinationShadowOpacity
        stroke.opacity = Float(appearance.strokeOpacity)
        CATransaction.commit()
    }

    func updatePaths() {
        let bounds = replicaContainer.bounds
        let shadows = [destinationShadow, keyShadow, ambientShadow]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for shadow in shadows { shadow.frame = bounds; shadow.mask?.frame = bounds }
        guard !bounds.isEmpty else {
            for shadow in shadows { shadow.shadowPath = nil; (shadow.mask as? CAShapeLayer)?.path = nil }
            return
        }
        strokeOverlayView.frame = clippingView.frame
        stroke.frame = strokeOverlayView.bounds
        let insetRadius = cornerRadius - 0.25
        let strokeRadius = insetRadius < 0 ? 0 : insetRadius
        stroke.path = CGPath(roundedRect: strokeOverlayView.bounds.insetBy(dx: 0.25, dy: 0.25),
                             cornerWidth: strokeRadius, cornerHeight: strokeRadius, transform: nil)
        let path = CGPath(roundedRect: clippingView.frame, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let maskPath = CGMutablePath()
        maskPath.addRect(bounds)
        maskPath.addPath(path)
        for shadow in shadows {
            shadow.shadowPath = path
            if let mask = shadow.mask as? CAShapeLayer {
                mask.fillRule = .evenOdd
                mask.path = maskPath
                mask.fillColor = NSColor.white.cgColor
            }
        }
    }
}
