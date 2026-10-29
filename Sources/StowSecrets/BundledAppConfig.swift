/// The client IDs a bundled-config build carries (D-512).
///
/// `scripts/bundle-config.sh` writes `BundledAppConfigValues.generated.swift`
/// beside this file from a configuration file. That file is git-ignored and
/// its contents are inside `#if STOW_BUNDLED_CONFIG`, so a build without the
/// condition compiles none of it, and a build with the condition but no
/// generated file fails to compile instead of shipping without IDs.
public enum BundledAppConfig {
    /// The built-in values, or nil in a source build.
    public static var values: [String: String]? {
        #if STOW_BUNDLED_CONFIG
        BundledAppConfigValues.values
        #else
        nil
        #endif
    }
}
