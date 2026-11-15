import App
import Darwin
import Foundation
import Shared

@main
struct RetraceCLIExecutable {
    static func main() async {
        Log.disableConsolePrinting()
        exit(await RetraceCLI.run(arguments: CommandLine.arguments))
    }
}
