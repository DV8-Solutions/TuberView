import AppKit

// TuberView starts here. There is no storyboard: the menus and windows are
// built in code so the whole app can be read top to bottom.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
