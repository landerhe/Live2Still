import SwiftUI

struct ConversionResultsView: View {
    var converter: LivePhotoConverter
    var onRetryKeepingOriginals: ((Set<String>, Bool) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(converter.lastSummary ?? "No conversion results yet.")
                        .font(.body)
                    Text("Removing a Live Photo removes its motion and editable history from your library. Originals may remain in Recently Deleted. Deletions can sync to your other devices through iCloud Photos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !converter.lastFailureMessages.isEmpty {
                        Text("Photos needing attention").font(.headline)
                        if let onRetryKeepingOriginals {
                            Button("Retry, Keep Originals") {
                                dismiss()
                                onRetryKeepingOriginals(Set(converter.lastFailureMessages.keys), false)
                            }.buttonStyle(.glassProminent)
                            Button("Save Fresh Copies, Keep Originals") {
                                dismiss()
                                onRetryKeepingOriginals(Set(converter.lastFailureMessages.keys), true)
                            }.buttonStyle(.glass)
                            Text("Fresh copies may create duplicates if an earlier output still exists.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(converter.lastFailureMessages.keys.sorted(), id: \.self) { id in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(converter.lastFailureMessages[id] ?? "Please review this photo.")
                                Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Last Conversion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
