import Foundation

@MainActor protocol EventStreamTransformationContextBackend {
    associatedtype Element
    func isCatalystApp(_ application:Element)->Bool
    func isWebShaped(_ application:Element)->Bool
    func firstChildHasChromeNodeID(_ window:Element)->Bool
    func frame(_ window:Element)->CGRect?
}

@MainActor enum EventStreamTransformationContextFactory {
    //0x100762F04. The second web-shape query is independent of the stored flag,
    // including when window is nil. Assembly selects nil limits/true query and
    // fragment bits for a missing URL configuration (optional tag0x200).
    static func make<Backend:EventStreamTransformationContextBackend>(
        type:EventStreamElementContextType,application:Backend.Element?,window:Backend.Element?,
        urlConfiguration:EventStreamURLShortener.Configuration?=nil,backend:Backend
    )->EventStreamMacTransformationContext {
        var catalyst=false,web=false,chrome=false
        if let application {
            catalyst=backend.isCatalystApp(application)
            web=backend.isWebShaped(application)
            if backend.isWebShaped(application),let window {chrome=backend.firstChildHasChromeNodeID(window)}
        }
        let frame=window.flatMap {backend.frame($0)}
        return .init(type:type,isCatalyst:catalyst,isWebShaped:web,isChromium:chrome,windowFrame:frame,
            urlShortener:.init(configuration:urlConfiguration ?? .init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true)))
    }
}

enum EventStreamBundleShape {
    //0x100260D58: the entire URLTypes value must cast to [[String:Any]].
    // Scheme/principal comparisons use native String equality, without folding.
    static func supportsHTTP(_ value:Any?)->Bool {
        guard let types=value as? [[String:Any]] else {return false}
        return types.contains {($0["CFBundleURLSchemes"] as? [String])?.contains("http")==true}
    }
    //0x100728FF0: preserve short circuit and separate principal-class reads.
    static func isWebShaped(read:(String)->Any?)->Bool {
        if supportsHTTP(read("CFBundleURLTypes")) {return true}
        if read("NSPrincipalClass") as? String == "AtomApplication" {return true}
        return read("NSPrincipalClass") as? String == "BrowserCrApplication"
    }
}
