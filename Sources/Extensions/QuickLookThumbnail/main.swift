import Foundation

// An app extension starts in NSExtensionMain (Foundation). It reads the NSExtension dictionary from
// Info.plist and instantiates NSExtensionPrincipalClass — here `ThumbnailProvider`.
@_silgen_name("NSExtensionMain")
private func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

// Reference the principal class so the linker never strips it.
_ = ThumbnailProvider.self
exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
