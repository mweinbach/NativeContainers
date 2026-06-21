import Foundation

struct ComposePreparedProjectPlan: Equatable, Sendable {
  let plan: ComposeProjectPlan
  let directoryURL: URL
  let expiresAt: Date
}

protocol ComposePreparedPlanStoring: Sendable {
  func store(plan: ComposeProjectPlan, directoryURL: URL) async
  func consume(_ submittedPlan: ComposeProjectPlan) async throws -> ComposePreparedProjectPlan
  func discard(planID: UUID) async
}

actor ComposePreparedPlanStore: ComposePreparedPlanStoring {
  private let timeToLive: TimeInterval
  private let maximumPreparedPlans: Int
  private let now: @Sendable () -> Date
  private var prepared: [UUID: ComposePreparedProjectPlan] = [:]

  init(
    timeToLive: TimeInterval = 10 * 60,
    maximumPreparedPlans: Int = 16,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    precondition(timeToLive > 0)
    precondition(maximumPreparedPlans > 0)
    self.timeToLive = timeToLive
    self.maximumPreparedPlans = maximumPreparedPlans
    self.now = now
  }

  func store(plan: ComposeProjectPlan, directoryURL: URL) {
    let currentTime = now()
    removeExpired(at: currentTime)
    if prepared.count >= maximumPreparedPlans,
      let oldest = prepared.values.min(by: preparedPlanOrder)
    {
      prepared.removeValue(forKey: oldest.plan.id)
    }
    prepared[plan.id] = ComposePreparedProjectPlan(
      plan: plan,
      directoryURL: directoryURL.standardizedFileURL,
      expiresAt: currentTime.addingTimeInterval(timeToLive)
    )
  }

  func consume(
    _ submittedPlan: ComposeProjectPlan
  ) throws -> ComposePreparedProjectPlan {
    let currentTime = now()
    removeExpired(at: currentTime)
    guard let stored = prepared[submittedPlan.id], stored.plan == submittedPlan else {
      throw ComposeProjectLifecycleError.stalePlan
    }
    prepared.removeValue(forKey: submittedPlan.id)
    return stored
  }

  func discard(planID: UUID) {
    prepared.removeValue(forKey: planID)
  }

  private func removeExpired(at date: Date) {
    prepared = prepared.filter { _, value in value.expiresAt > date }
  }

  private func preparedPlanOrder(
    _ lhs: ComposePreparedProjectPlan,
    _ rhs: ComposePreparedProjectPlan
  ) -> Bool {
    if lhs.plan.generatedAt != rhs.plan.generatedAt {
      return lhs.plan.generatedAt < rhs.plan.generatedAt
    }
    return lhs.plan.id.uuidString < rhs.plan.id.uuidString
  }
}
