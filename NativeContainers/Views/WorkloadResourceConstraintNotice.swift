import SwiftUI

struct WorkloadResourceConstraintNotice: View {
  let constraint: ResourceDefaultConstraint?

  var body: some View {
    if let constraint {
      Label {
        Text(constraint.notice)
      } icon: {
        Image(systemName: "leaf.fill")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

#Preview("Low Power resource defaults") {
  Form {
    Section("Resources") {
      LabeledContent("Virtual CPUs", value: "2")
      WorkloadResourceConstraintNotice(constraint: .lowPowerMode)
    }
  }
  .formStyle(.grouped)
  .frame(width: 420)
}
