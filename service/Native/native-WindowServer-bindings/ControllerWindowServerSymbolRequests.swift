import Foundation

/// The mandatory WindowServer symbol table and a separately lazy capture request.
/// The native backend is supplied explicitly; this does not silently fall back
/// to dlsym on an unrelated image or accept a missing required function.
enum ControllerWindowServerSymbolRequests {
    static let images: [UInt64] = [0x6a70b4eb9dcbdd, 0xe7e2cd7db0bcc2, 0xc715e25929c715, 0x2e4d11d2a52678, 0x3c4c59c164460d]
    static let captureImages: [UInt64] = [0x1e01d88df9a29c0, 0x1e2f4fe711fa87f, 0x1299de46c792a17, 0x1eb076bb1a4dee8, 0x1cdd05a03c6b40b]
    static let captureRequest: [UInt64] = [0x7861fa62d7cd18dd, 0x626a131e3cae860b]
    static let salt = "5bf55cb05ac41e12d460d9f3931f48b6d11b6908f5374963aa307757875aa2a143d9ebeaeaa04860e6fd5c535f5451f38f93c57299a9c05d3bd9258e760360f"
    static let captureSalt = "d3c945d6aaef5558c0986caae9ba9f70107322c483a0722374d366c6b8d095746658758791b91db8250396d64839e17a59c3b67d3c7a2817f00ea01cdeaf122"
    static let required: [[UInt64]] = [
        [0xb5ba643566567e83, 0x4834ef5d7e131902],
        [0xe95cf663adbaf5f1, 0x86101423ae0c2baf],
        [0x62f8dd9aae3a4680, 0x9e0f3df5d3edf4c0],
        [0xcfd86ea8b4ebf104, 0xd7cdc80ef2af5c52],
        [0x75f40964926064cc, 0xe29a29aba3bde7fc],
        [0xdd25d9641948215a, 0x9a5e50e4a2e79300],
        [0x64bff03d06ff594, 0xfdad5427116ccac2],
        [0xc669fd4edd8a61a6, 0x6ba1cf4a08efaf2d],
        [0x1f38deeee1290529, 0xc6e63179257870dd],
        [0xbce450a4b4b5f643, 0x8ab4e1c33083ab0c],
        [0xa41da438d775b3a4, 0x175d2d3025f9119],
        [0xa388d9481ce6f81b, 0x82358993e164d551],
        [0xa01a82c132d72023, 0x388198f269bffae1],
    ]
    static func resolveRequired<Backend: ControllerSoftLinkBackend>(using backend: Backend) -> [ControllerSoftLinkSymbol] {
        require(ControllerSoftLink.resolve(images: images, requests: required, salt: salt, backend: backend))
    }
    static func resolveCapture<Backend: ControllerSoftLinkBackend>(using backend: Backend) -> ControllerSoftLinkSymbol? {
        ControllerSoftLink.resolve(images: captureImages, requests: [captureRequest], salt: captureSalt, backend: backend).first ?? nil
    }
    // Consume all 13 sequentially; every missing slot is a trap even
    // when the eventual caller only uses mainConnectionID.
    static func require(_ values: [ControllerSoftLinkSymbol?]) -> [ControllerSoftLinkSymbol] {
        (0..<13).map { index in
            guard let value = values[index] else { preconditionFailure("Required WindowServer symbol is unavailable") }
            return value
        }
    }
    static let disableImages: [UInt64] = [0x132c2630f178249, 0x1e234e47584654c, 0x13821a514b09621, 0x16365861785c673, 0x128ce43d5b143d2]
    static let disableRequest: [UInt64] = [0x20f3e90088743c0b, 0x90c902f804b97bb]
    static let reenableImages: [UInt64] = [0x115d56baf2f7531, 0x18234cb7592fd8b, 0x15473a953e10ae2, 0x134597f832ec5df, 0x14736fb28fc1025]
    static let reenableRequest: [UInt64] = [0xbcb63a28ad810e32, 0x74c79b0d10c8a1cf]
    static let disableSalt = "cb9ded3256b250c2b0013afea1eaf512c32fd985e9f230ed22486b110d60299a321337b2c26791197808629904bfd8806657dd2f3840b198c7dd09e2bcab4"
    static let reenableSalt = "5c5533e19167c23fad99d1468ca63b1dbf926594e31b164535bcab299f7a9a0d143f20742b203ced76947f5dad1d8c75c61d14415e46b137dd09a3f6acafa62"
    static func resolveUpdate<Backend: ControllerSoftLinkBackend>(reenable: Bool, using backend: Backend) -> ControllerSoftLinkSymbol? {
        ControllerSoftLink.resolve(images: reenable ? reenableImages : disableImages,
            requests: [reenable ? reenableRequest : disableRequest],
            salt: reenable ? reenableSalt : disableSalt, backend: backend).first ?? nil
    }

}
