import SwiftUI

struct ImageBuildsView: View {
  @State private var selection = ImageBuildWorkspaceSection.newBuild
  @State private var imageBuildModel: ImageBuildModel
  @State private var builderModel: ContainerBuilderManagementModel

  init(appModel: AppModel) {
    _imageBuildModel = State(initialValue: appModel.makeImageBuildModel())
    _builderModel = State(initialValue: appModel.makeContainerBuilderManagementModel())
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("Build workspace", selection: $selection) {
        ForEach(ImageBuildWorkspaceSection.allCases) { section in
          Text(section.title).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 420)
      .padding()

      Divider()

      switch selection {
      case .newBuild:
        ImageBuildCreationView(model: imageBuildModel)
      case .builderAndCache:
        ContainerBuilderManagementView(model: builderModel)
      }
    }
    .navigationTitle("Builds")
  }
}

private enum ImageBuildWorkspaceSection: String, CaseIterable, Identifiable {
  case newBuild
  case builderAndCache

  var id: Self { self }

  var title: String {
    switch self {
    case .newBuild: "New Build"
    case .builderAndCache: "Builder & Cache"
    }
  }
}
