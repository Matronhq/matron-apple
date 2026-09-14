import SwiftUI
import MatronModels

public enum ItemGlyph {
    public static func symbol(_ kind: ItemKind) -> String {
        switch kind { case .question: return "questionmark.circle.fill"; case .task: return "checklist"; case .decision: return "scalemass.fill" }
    }
    public static func tint(_ kind: ItemKind) -> Color {
        switch kind { case .question: return .orange; case .task: return .accentColor; case .decision: return .purple }
    }
    public static func label(_ kind: ItemKind) -> String {
        switch kind { case .question: return "Question"; case .task: return "Task"; case .decision: return "Decision" }
    }
    public static func label(_ r: ItemResolution) -> String {
        switch r { case .done: return "Done"; case .answered: return "Answered"; case .decided: return "Decided"; case .reversed: return "Reversed"; case .cancelled: return "Cancelled" }
    }
}
