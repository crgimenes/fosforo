#if os(iOS)
  import UIKit

  UIApplicationMain(
    CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
#else
  import Foundation

  FileHandle.standardError.write(Data("fosforo-ios runs on iOS; the Mac app is fosforo\n".utf8))
  exit(2)
#endif
