import EventKit
import Foundation

reexecDisclaimed()

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("no subcommand. usage: eventkit-cli <lists|reminders|search|create-reminder|complete-reminder|calendars|events|search-events|create-event>")
}

let rest = Args(Array(args.dropFirst()))

switch command {
case "lists":
    cmdLists()
case "reminders":
    cmdReminders(rest)
case "search":
    cmdSearch(rest)
case "create-reminder":
    cmdCreateReminder(rest)
case "complete-reminder":
    cmdCompleteReminder(rest)
case "calendars":
    cmdCalendars()
case "events":
    cmdEvents(rest)
case "search-events":
    cmdSearchEvents(rest)
case "create-event":
    cmdCreateEvent(rest)
case "diag":
    cmdDiag()
default:
    fail("unknown subcommand: \(command)")
}
