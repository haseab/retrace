import Foundation

public enum RetraceCLI {
    public static func run(arguments: [String]) async -> Int32 {
        let parser = CLIArgumentParser()
        let service = RetraceCLIService()

        do {
            let command = try parser.parse(arguments: Array(arguments.dropFirst()))

            switch command {
            case .status:
                let output = try await service.status()
                try write(
                    CLICommandEnvelope(
                        command: command.name,
                        result: output
                    )
                )
            case .apps(let request):
                switch request {
                case .list(let listRequest):
                    let output = try await service.appsList(listRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "apps.\(request.subcommandName)",
                            result: output
                        )
                    )
                }
            case .search(let request):
                let output = try await service.search(request)
                try write(
                    CLICommandEnvelope(
                        command: command.name,
                        result: output
                    )
                )
            case .jump(let request):
                let output = try await service.jump(request)
                try write(
                    CLICommandEnvelope(
                        command: command.name,
                        result: output
                    )
                )
            case .around(let request):
                let output = try await service.around(request)
                try write(
                    CLICommandEnvelope(
                        command: command.name,
                        result: output
                    )
                )
            case .open(let request):
                let output = try await service.open(request)
                try write(
                    CLICommandEnvelope(
                        command: command.name,
                        result: output
                    )
                )
            case .config(let request):
                switch request {
                case .list:
                    let output = try await service.configList()
                    try write(
                        CLICommandEnvelope(
                            command: "config.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .get(let configRequest):
                    let output = try await service.configGet(configRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "config.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .set(let configRequest):
                    let output = try await service.configSet(configRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "config.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .reset(let configRequest):
                    let output = try await service.configReset(configRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "config.\(request.subcommandName)",
                            result: output
                        )
                    )
                }
            case .usage(let request):
                switch request {
                case .apps(let usageRequest):
                    let output = try await service.usageApps(usageRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "usage.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .websites(let usageRequest):
                    let output = try await service.usageWebsites(usageRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "usage.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .tabs(let usageRequest):
                    let output = try await service.usageTabs(usageRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "usage.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .sessions(let usageRequest):
                    let output = try await service.usageSessions(usageRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "usage.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .screenTime(let usageRequest):
                    let output = try await service.usageScreenTime(usageRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "usage.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .switches(let usageRequest):
                    let output = try await service.usageSwitches(usageRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "usage.\(request.subcommandName)",
                            result: output
                        )
                    )
                }
            case .extract(let request):
                switch request {
                case .text(let extractRequest):
                    let output = try await service.extractText(extractRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "extract.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .url(let extractRequest):
                    let output = try await service.extractURL(extractRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "extract.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .links(let extractRequest):
                    let output = try await service.extractLinks(extractRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "extract.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .ocr(let extractRequest):
                    let output = try await service.extractOCR(extractRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "extract.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .image(let extractRequest):
                    let output = try await service.extractImage(extractRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "extract.\(request.subcommandName)",
                            result: output
                        )
                    )
                }
            case .inspect(let request):
                switch request {
                case .system:
                    let output = try await service.inspectSystem()
                    try write(
                        CLICommandEnvelope(
                            command: "inspect.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .ocr:
                    let output = try await service.inspectOCR()
                    try write(
                        CLICommandEnvelope(
                            command: "inspect.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .queue:
                    let output = try await service.inspectQueue()
                    try write(
                        CLICommandEnvelope(
                            command: "inspect.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .storage:
                    let output = try await service.inspectStorage()
                    try write(
                        CLICommandEnvelope(
                            command: "inspect.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .metrics(let inspectRequest):
                    let output = try await service.inspectMetrics(inspectRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "inspect.\(request.subcommandName)",
                            result: output
                        )
                    )
                case .frame(let inspectRequest):
                    let output = try await service.inspectFrame(inspectRequest)
                    try write(
                        CLICommandEnvelope(
                            command: "inspect.\(request.subcommandName)",
                            result: output
                        )
                    )
                }
            case .help(let request):
                let output = try await service.help(request)
                try write(
                    CLICommandEnvelope(
                        command: command.name,
                        result: output
                    )
                )
            case .completions(let request):
                let output = try await service.completions(request)
                try write(
                    CLICommandEnvelope(
                        command: command.name,
                        result: output
                    )
                )
            }

            await service.shutdown()
            return 0
        } catch let error as CLIError {
            await service.shutdown()
            try? write(CLIErrorEnvelope(error: error.payload), to: .standardError)
            return error.exitCode
        } catch {
            await service.shutdown()
            try? write(
                CLIErrorEnvelope(
                    error: CLIErrorPayload(
                        code: "runtime_error",
                        message: error.localizedDescription
                    )
                ),
                to: .standardError
            )
            return 1
        }
    }

    private static func write<T: Encodable>(_ value: T, to handle: FileHandle = .standardOutput) throws {
        let encoder = JSONEncoder()
        CLIDateCoding.configure(encoder)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(value)
        handle.write(data)
        handle.write(Data([0x0A]))
    }
}
