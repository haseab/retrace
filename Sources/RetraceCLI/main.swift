import App
import Darwin
import Foundation
import Shared

@main
struct RetraceCLIExecutable {
    static func main() async {
        Log.disableConsolePrinting()
        let code = await RetraceCLI.run(arguments: CommandLine.arguments)
        await Log.flush()
        exit(code)
    }
}
