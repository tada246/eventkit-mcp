import EventKit
import EventKitCore
import Foundation

reexecDisclaimed()

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("no subcommand. usage: eventkit-cli <lists|reminders|search|create-reminder|update-reminder|delete-reminder|complete-reminder|calendars|events|search-events|create-event|update-event|delete-event|diag>")
}

let rest = Args(Array(args.dropFirst()))

do {
    switch command {
    case "lists":
        try cmdLists()
    case "reminders":
        try cmdReminders(rest)
    case "search":
        try cmdSearch(rest)
    case "create-reminder":
        try cmdCreateReminder(rest)
    case "update-reminder":
        try cmdUpdateReminder(rest)
    case "delete-reminder":
        try cmdDeleteReminder(rest)
    case "complete-reminder":
        try cmdCompleteReminder(rest)
    case "calendars":
        try cmdCalendars()
    case "events":
        try cmdEvents(rest)
    case "search-events":
        try cmdSearchEvents(rest)
    case "create-event":
        try cmdCreateEvent(rest)
    case "update-event":
        try cmdUpdateEvent(rest)
    case "delete-event":
        try cmdDeleteEvent(rest)
    case "diag":
        cmdDiag()
    default:
        fail("unknown subcommand: \(command)")
    }
} catch let error as CoreError {
    fail(error.message)
} catch {
    fail(error.localizedDescription)
}
