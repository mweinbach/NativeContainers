import SwiftUI

struct ImageBuildsView: View {
  @State private var selection = ImageBuildWorkspaceSection.newBuild
  @State private var imageBuildModel: ImageBuildModel
  @State private var historyModel: ImageBuildHistoryModel
  @State private var builderModel: ContainerBuilderManagementModel

  init(appModel: AppModel) {
    _imageBuildModel = State(initialValue: appModel.makeImageBuildModel())
    _historyModel = State(initialValue: appModel.makeImageBuildHistoryModel())
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
      .frame(maxWidth: 560)
      .disabled(
        imageBuildModel.plan != nil
          || imageBuildModel.isWorking
          || builderModel.plan != nil
          || builderModel.isBusy
      )
      .padding()

      Divider()

      switch selection {
      case .newBuild:
        ImageBuildCreationView(model: imageBuildModel)
      case .history:
        ImageBuildHistoryView(model: historyModel)
      case .builderAndCache:
        ContainerBuilderManagementView(model: builderModel)
      }
    }
    .navigationTitle("Builds")
  }
}

private enum ImageBuildWorkspaceSection: String, CaseIterable, Identifiable {
  case newBuild
  case history
  case builderAndCache

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .newBuild: "New Build"
    case .history: "History"
    case .builderAndCache: "Builder & Cache"
    }
  }
}
