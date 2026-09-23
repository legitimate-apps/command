import Foundation

enum AssistantSchemaDonations {
    static func assignmentCreated(_ assignment: Assignment) async {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            var intent = CreateCommandReminderAssistantIntent()
            intent.title = assignment.title
            intent.dueDate = assignment.scheduledStart.flatMap(IntentFormat.date(from:))
            try? await intent.donate()
        }
        #endif
    }
}
