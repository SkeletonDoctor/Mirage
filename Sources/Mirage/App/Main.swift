import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        } else {
            MirageApp.main()
        }
    }
}
