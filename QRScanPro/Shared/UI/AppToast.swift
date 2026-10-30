import SwiftUI

struct ToastData: Equatable, Hashable {
    let message: String
    let isError: Bool

    init(_ message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var toast: ToastData?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = toast {
                HStack(spacing: 6) {
                    if t.isError {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.white)
                    }
                    Text(t.message)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(t.isError ? Color.red.opacity(0.9) : Color.black.opacity(0.78), in: Capsule())
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                        withAnimation(.easeOut(duration: 0.25)) { toast = nil }
                    }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: toast)
    }
}

extension View {
    func appToast(_ toast: Binding<ToastData?>) -> some View {
        modifier(ToastModifier(toast: toast))
    }
}
