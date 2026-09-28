enum BuildVariant {
    #if OFFLINE
    static let isOffline = true
    static let displayName = "Markclip Offline"
    #else
    static let isOffline = false
    static let displayName = "Markclip"
    #endif
}
