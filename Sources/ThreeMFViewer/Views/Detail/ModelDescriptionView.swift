import SwiftUI
import ThreeMFKit

/// The author's description and print profile notes.
struct ModelDescriptionView: View {
    let model: ThreeMFModel?
    let extras: ModelExtras

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let title = model?.metadataValue("Title"), !title.isEmpty {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                }
                if let designer = model?.metadataValue("Designer"), !designer.isEmpty {
                    Label(designer, systemImage: "person.crop.circle")
                        .foregroundStyle(.secondary)
                }
                if let description = extras.description {
                    Text(description)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if extras.profileTitle != nil || extras.profileDescription != nil {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            if let profileTitle = extras.profileTitle {
                                Text(profileTitle)
                                    .font(.headline)
                            }
                            if let profileDescription = extras.profileDescription {
                                Text(profileDescription)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    } label: {
                        Label("Print profile", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
