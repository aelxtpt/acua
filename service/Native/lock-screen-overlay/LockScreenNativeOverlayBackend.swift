import AppKit
import OpenDirectory
import Combine

@MainActor protocol LockScreenWallpaperProviding:AnyObject {
    func cachedWallpaper(for screen:NSScreen)->CGImage?
    func monitorWallpaper(for screen:NSScreen) throws -> AsyncThrowingStream<CGImage,Error>
}

@MainActor final class LockScreenNativeOverlayBackend:LockScreenOverlayBackend {
    typealias Screen=NSScreen
    typealias Window=NSWindow
    typealias WallpaperTarget=NSView
    typealias Wallpaper=CGImage
    typealias ProfileImage=NSImage
    private let wallpaper:any LockScreenWallpaperProviding
    private let profileError:(Error)->Void
    private let wallpaperError:(Error)->Void
    init(wallpaper:any LockScreenWallpaperProviding,profileError:@escaping(Error)->Void={_ in},
         wallpaperError:@escaping(Error)->Void={_ in}){
        self.wallpaper=wallpaper;self.profileError=profileError;self.wallpaperError=wallpaperError
    }
    func screens()->[NSScreen]{NSScreen.screens}
    func observeScreens(_ changed:@escaping @MainActor ()->Void)->LockScreenOverlayScreenObservation{
        let token=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){_ in
            MainActor.assumeIsolated{changed()}
        }
        return .init(remove:{NotificationCenter.default.removeObserver(token)})
    }
    func orderOut(_ window:NSWindow){window.orderOut(nil)}
    func orderFront(_ window:NSWindow){window.orderFrontRegardless()}
    func cachedWallpaper(for screen:NSScreen)->CGImage?{wallpaper.cachedWallpaper(for:screen)}
    func monitorWallpaper(for screen:NSScreen)throws->AsyncThrowingStream<CGImage,Error>{try wallpaper.monitorWallpaper(for:screen)}
    func setWallpaper(_ image:CGImage?,on target:NSView){target.layer?.contents=image}
    func wallpaperFailed(_ error:Error){wallpaperError(error)}
    func loadProfileImage()->NSImage?{
        let session=ODSession.default()
        let loader=LockScreenProfileImageLoader<ODRecord,NSImage>(userName:NSUserName,
            record:{type,name,attributes in
                let node=try ODNode(session:session,type:ODNodeType(type))
                return try node.record(withRecordType:kODRecordTypeUsers,name:name,attributes:attributes)
            },values:{try $0.values(forAttribute:$1)},decodeData:{NSImage(data:$0)},decodePath:{NSImage(contentsOfFile:$0)})
        do{return try loader.load()}catch{profileError(error);return nil}
    }
    func fallbackProfileImage()->NSImage{
        NSImage(systemSymbolName:LockScreenOverlayLayout.fallbackSymbol,accessibilityDescription:nil) ?? NSImage()
    }
    func makeWindow(for screen:NSScreen,profile:()->NSImage,configureWallpaper:(NSView)->Void)->NSWindow{
        let layout=LockScreenOverlayLayout.self
        let window=NSWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.animationBehavior = .none;window.backgroundColor = .black;window.isOpaque=true
        window.hasShadow=false;window.ignoresMouseEvents=true
        window.level = .init(rawValue:Int(CGShieldingWindowLevel())+1)
        window.collectionBehavior = .init(rawValue:layout.windowCollectionBehavior)
        let content=NSView(frame:.init(origin:.zero,size:screen.frame.size))
        content.wantsLayer=true;content.layer?.backgroundColor=NSColor.black.cgColor
        let background=NSView();background.translatesAutoresizingMaskIntoConstraints=false;background.wantsLayer=true
        background.layer?.contentsGravity = .resizeAspectFill
        background.layer?.backgroundColor=NSColor.black.cgColor
        configureWallpaper(background)
        let tint=NSView();tint.translatesAutoresizingMaskIntoConstraints=false;tint.wantsLayer=true
        tint.layer?.backgroundColor=NSColor.black.withAlphaComponent(layout.tintAlpha).cgColor
        let graphic=makeGraphic(profile:profile())
        content.addSubview(background);content.addSubview(tint);content.addSubview(graphic)
        NSLayoutConstraint.activate([background.leadingAnchor.constraint(equalTo:content.leadingAnchor),background.trailingAnchor.constraint(equalTo:content.trailingAnchor),
            background.topAnchor.constraint(equalTo:content.topAnchor),background.bottomAnchor.constraint(equalTo:content.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo:content.leadingAnchor),tint.trailingAnchor.constraint(equalTo:content.trailingAnchor),
            tint.topAnchor.constraint(equalTo:content.topAnchor),tint.bottomAnchor.constraint(equalTo:content.bottomAnchor),
            graphic.centerXAnchor.constraint(equalTo:content.centerXAnchor),graphic.centerYAnchor.constraint(equalTo:content.centerYAnchor,constant:layout.centerOffset)])
        window.contentView=content;return window
    }
    private func makeGraphic(profile:NSImage)->NSView{
        let layout=LockScreenOverlayLayout.self
        let photo=NSImageView(image:profile);photo.translatesAutoresizingMaskIntoConstraints=false
        photo.imageScaling = .scaleAxesIndependently;photo.wantsLayer=true
        photo.layer?.cornerRadius=layout.avatarCornerRadius;photo.layer?.masksToBounds=true
        photo.layer?.borderWidth=layout.avatarBorder;photo.layer?.borderColor=NSColor.white.withAlphaComponent(layout.avatarBorderAlpha).cgColor
        let backing=NSView();backing.translatesAutoresizingMaskIntoConstraints=false;backing.wantsLayer=true
        backing.layer?.backgroundColor=NSColor.black.withAlphaComponent(layout.shadowBackgroundAlpha).cgColor
        backing.layer?.cornerRadius=layout.avatarCornerRadius;backing.layer?.shadowColor=NSColor.black.withAlphaComponent(layout.shadowAlpha).cgColor
        backing.layer?.shadowOpacity=1;backing.layer?.shadowRadius=layout.shadowRadius;backing.layer?.shadowOffset=layout.shadowOffset
        backing.addSubview(photo)
        let icon=NSImageView(image:NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints=false;icon.imageScaling = .scaleProportionallyUpOrDown
        let emblem=NSView();emblem.translatesAutoresizingMaskIntoConstraints=false;emblem.addSubview(backing);emblem.addSubview(icon)
        NSLayoutConstraint.activate([emblem.widthAnchor.constraint(equalToConstant:layout.emblemSize),emblem.heightAnchor.constraint(equalToConstant:layout.emblemSize),
            backing.topAnchor.constraint(equalTo:emblem.topAnchor),backing.leadingAnchor.constraint(equalTo:emblem.leadingAnchor),
            backing.widthAnchor.constraint(equalToConstant:layout.avatarSize),backing.heightAnchor.constraint(equalToConstant:layout.avatarSize),
            photo.leadingAnchor.constraint(equalTo:backing.leadingAnchor),photo.trailingAnchor.constraint(equalTo:backing.trailingAnchor),
            photo.topAnchor.constraint(equalTo:backing.topAnchor),photo.bottomAnchor.constraint(equalTo:backing.bottomAnchor),
            icon.trailingAnchor.constraint(equalTo:emblem.trailingAnchor),icon.bottomAnchor.constraint(equalTo:emblem.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant:layout.applicationIconSize),icon.heightAnchor.constraint(equalToConstant:layout.applicationIconSize)])
        let title=NSTextField(labelWithString:layout.title),subtitle=NSTextField(labelWithString:layout.subtitle)
        title.font = .systemFont(ofSize:layout.titleFontSize,weight:.medium)
        subtitle.font = .systemFont(ofSize:layout.subtitleFontSize,weight:.semibold)
        for label in [title,subtitle]{label.textColor=NSColor.white.withAlphaComponent(layout.textAlpha);label.alignment = .center;label.translatesAutoresizingMaskIntoConstraints=false}
        let text=NSStackView(views:[title,subtitle]);text.orientation = .vertical;text.alignment = .centerX;text.spacing=layout.textSpacing;text.translatesAutoresizingMaskIntoConstraints=false
        let container=NSView();container.translatesAutoresizingMaskIntoConstraints=false;container.addSubview(emblem);container.addSubview(text)
        NSLayoutConstraint.activate([title.widthAnchor.constraint(equalToConstant:layout.titleSize.width),title.heightAnchor.constraint(equalToConstant:layout.titleSize.height),
            subtitle.widthAnchor.constraint(equalToConstant:layout.subtitleSize.width),subtitle.heightAnchor.constraint(equalToConstant:layout.subtitleSize.height),
            emblem.topAnchor.constraint(equalTo:container.topAnchor),emblem.centerXAnchor.constraint(equalTo:text.centerXAnchor,constant:layout.emblemOffset),
            text.leadingAnchor.constraint(equalTo:container.leadingAnchor),text.trailingAnchor.constraint(equalTo:container.trailingAnchor),
            text.topAnchor.constraint(equalTo:emblem.bottomAnchor,constant:layout.emblemSpacing),text.bottomAnchor.constraint(equalTo:container.bottomAnchor)])
        return container
    }
}
