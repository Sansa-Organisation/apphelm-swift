#if canImport(SwiftUI) && !os(watchOS)
import Foundation
import SwiftUI

/// The state behind a drawn survey: the flow, the text being typed, the options picked, and
/// what happens when it is answered, left or closed. Kept apart from the view so the logic is
/// testable, and so the sheet can tell a swipe-down from a finished survey.
@MainActor
final class SurveyViewModel: ObservableObject {
  @Published private(set) var flow: SurveyFlow
  @Published var text = ""
  @Published private(set) var picked: [String] = []
  @Published private(set) var finished = false
  let offer: SurveyOffer
  let appearance: SurveyAppearance
  var onRespond: (SurveyAnswer) -> Void
  var onDismiss: () -> Void
  var onClose: () -> Void
  /// How long the thank-you stays before the survey closes itself.
  var thankYouSeconds: Double = 1.6
  private(set) var settled = false
  private var closed = false

  init(offer: SurveyOffer, onRespond: @escaping (SurveyAnswer) -> Void, onDismiss: @escaping () -> Void, onClose: @escaping () -> Void) {
    self.offer = offer
    self.flow = SurveyFlow(offer)
    self.appearance = offer.appearance ?? SurveyAppearance()
    self.onRespond = onRespond
    self.onDismiss = onDismiss
    self.onClose = onClose
  }

  var step: SurveyStep? { flow.current }

  /// Answer the current step (nil skips an optional one); sends the response at the end.
  func answer(_ value: SurveyValue?) {
    guard !settled else { return }
    let before = flow.progress.step
    flow.answer(value)
    // A required step left empty keeps what was typed.
    if flow.progress.step != before { text = ""; picked = [] }
    guard flow.isDone else { return }
    settled = true
    finished = true
    onRespond(flow.response)
    let delay = thankYouSeconds
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.close() }
  }

  /// Submit what was typed: the open text, or the options picked.
  func submit() {
    guard let step else { return }
    switch step.type {
    case .open: answer(.text(text))
    case .multipleChoice: answer(picked.isEmpty ? nil : .list(step.options.filter(picked.contains)))
    default: answer(nil)
    }
  }

  func toggle(_ option: String) {
    if let at = picked.firstIndex(of: option) { picked.remove(at: at) } else { picked.append(option) }
  }

  /// Whether the submit button does anything now.
  var canSubmit: Bool {
    guard let step else { return false }
    if step.optional { return true }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// "Not now", or the sheet swiped away: the answers so far are sent once the primary
  /// question is answered (they are a valid response), otherwise the survey is dismissed.
  func leave() {
    if !settled {
      settled = true
      if flow.hasAnswer { onRespond(flow.response) } else { onDismiss() }
    }
    close()
  }

  func close() {
    guard !closed else { return }
    closed = true
    onClose()
  }
}

extension Color {
  /// A `#rrggbb` colour; black when it is not one.
  init(surveyHex hex: String) {
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
    self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
  }
}

/// A drawn survey for an offer from `ApphelmClient.surveyEligible`, in the program's
/// colours and texts: every question type (numbers or faces, single and multiple choice,
/// open text, a link button), progress, "Not now", a thank-you, and "Survey by AppHelm"
/// unless the program hides it. It walks `SurveyFlow`; send what `onRespond` gets with
/// `surveyRespond`, and call `surveyDismiss` from `onDismiss`. `onClose` is when to take it
/// away. `ApphelmSurveyPresenter` does all of this for you on iOS.
public struct ApphelmSurveyView: View {
  @StateObject private var model: SurveyViewModel
  @Environment(\.openURL) private var openURL
  private let openLink: ((URL) -> Void)?

  /// `openLink` opens a link question's https link (default: the system, via `openURL`).
  public init(offer: SurveyOffer, openLink: ((URL) -> Void)? = nil, onRespond: @escaping (SurveyAnswer) -> Void, onDismiss: @escaping () -> Void, onClose: @escaping () -> Void) {
    _model = StateObject(wrappedValue: SurveyViewModel(offer: offer, onRespond: onRespond, onDismiss: onDismiss, onClose: onClose))
    self.openLink = openLink
  }

  init(model: SurveyViewModel, openLink: ((URL) -> Void)? = nil) {
    _model = StateObject(wrappedValue: model)
    self.openLink = openLink
  }

  private var appearance: SurveyAppearance { model.appearance }
  private var textColor: Color { Color(surveyHex: appearance.textColor) }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        if !model.finished {
          let progress = model.flow.progress
          Text("\(progress.step) of \(progress.total)").font(.caption).opacity(0.7)
        }
        Spacer()
        if !model.finished {
          Button("Not now") { model.leave() }.font(.subheadline).foregroundColor(textColor.opacity(0.8))
        }
      }
      if model.finished {
        Text(appearance.thankYouText ?? "Thank you for your feedback!").font(.headline).fixedSize(horizontal: false, vertical: true)
      } else if let step = model.step {
        Text(step.text).font(.headline).fixedSize(horizontal: false, vertical: true)
        content(step)
      }
      footer
    }
    .padding(20)
    .foregroundColor(textColor)
    .background(Color(surveyHex: appearance.backgroundColor))
  }

  @ViewBuilder private func content(_ step: SurveyStep) -> some View {
    switch step.type {
    case .rating: rating(step)
    case .choice:
      VStack(spacing: 8) {
        ForEach(step.options, id: \.self) { option in
          Button { model.answer(.text(option)) } label: { optionLabel(step.label(option), checked: nil) }.buttonStyle(.plain)
        }
        if step.optional { skip }
      }
    case .multipleChoice:
      VStack(spacing: 8) {
        ForEach(step.options, id: \.self) { option in
          Button { model.toggle(option) } label: { optionLabel(step.label(option), checked: model.picked.contains(option)) }.buttonStyle(.plain)
        }
        submitButton(appearance.submitText)
      }
    case .open:
      VStack(spacing: 10) {
        TextField(appearance.placeholder ?? "Type your answer", text: $model.text, axis: .vertical)
          .lineLimit(3...6)
          .padding(10)
          .background(RoundedRectangle(cornerRadius: 8).stroke(textColor.opacity(0.3)))
        submitButton(appearance.submitText)
      }
    case .link:
      VStack(spacing: 8) {
        primaryButton(step.buttonText ?? "Open") {
          if let url = safeSurveyLink(step.link) { if let openLink { openLink(url) } else { openURL(url) } }
          model.answer(.text("clicked"))
        }
        if step.optional { skip }
      }
    }
  }

  @ViewBuilder private func rating(_ step: SurveyStep) -> some View {
    VStack(spacing: 6) {
      HStack(spacing: 4) {
        if step.showsFaces {
          ForEach(Array(ratingFaces(step.scale.upperBound).enumerated()), id: \.offset) { offset, face in
            Button { model.answer(.number(Double(offset + 1))) } label: {
              Text(face).font(.title).frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel("\(offset + 1) of \(step.scale.upperBound)")
          }
        } else {
          ForEach(Array(step.scale), id: \.self) { value in
            Button { model.answer(.number(Double(value))) } label: {
              Text("\(value)").font(.callout.weight(.medium)).frame(maxWidth: .infinity, minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 6).stroke(textColor.opacity(0.3)))
            }.buttonStyle(.plain)
          }
        }
      }
      if step.lowerLabel != nil || step.upperLabel != nil {
        HStack {
          Text(step.lowerLabel ?? "")
          Spacer()
          Text(step.upperLabel ?? "")
        }.font(.caption).opacity(0.7)
      }
      if step.optional { skip }
    }
  }

  private func optionLabel(_ text: String, checked: Bool?) -> some View {
    HStack {
      if let checked {
        Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundColor(checked ? Color(surveyHex: appearance.buttonColor) : textColor.opacity(0.6))
      }
      Text(text).multilineTextAlignment(.leading)
      Spacer()
    }
    .padding(12)
    .contentShape(Rectangle())
    .background(RoundedRectangle(cornerRadius: 8).stroke(textColor.opacity(0.3)))
  }

  private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
        .foregroundColor(Color(surveyHex: appearance.buttonTextColor))
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(surveyHex: appearance.buttonColor)))
    }.buttonStyle(.plain)
  }

  private func submitButton(_ title: String) -> some View {
    primaryButton(title) { model.submit() }.disabled(!model.canSubmit).opacity(model.canSubmit ? 1 : 0.5)
  }

  private var skip: some View {
    Button("Skip") { model.answer(nil) }.font(.subheadline).foregroundColor(textColor.opacity(0.7)).frame(maxWidth: .infinity)
  }

  @ViewBuilder private var footer: some View {
    let notice = safeSurveyLink(model.offer.privacyNoticeUrl)
    if notice != nil || !appearance.hideBranding {
      HStack {
        if let notice {
          Button("How we use this") { if let openLink { openLink(notice) } else { openURL(notice) } }.buttonStyle(.plain).underline()
        }
        Spacer()
        if !appearance.hideBranding { Text("Survey by AppHelm") }
      }.font(.caption2).opacity(0.6)
    }
  }
}
#endif

#if canImport(UIKit) && canImport(SwiftUI) && !os(watchOS)
import UIKit

/// A hosting controller that treats a swipe-down as "Not now".
final class SurveyHostingController: UIHostingController<AnyView>, UIAdaptivePresentationControllerDelegate {
  var onSwipeDismiss: (() -> Void)?
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onSwipeDismiss?() }
}

/// The card position: a dimmed screen with the survey centred or at the top.
private struct SurveyCard: View {
  @ObservedObject var model: SurveyViewModel

  var body: some View {
    ZStack(alignment: model.appearance.position == "top_center" ? .top : .center) {
      Color.black.opacity(0.35).ignoresSafeArea()
      ApphelmSurveyView(model: model)
        .frame(maxWidth: CGFloat(model.appearance.maxWidth))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 12)
        .padding(16)
    }
  }
}

/// Presents a survey offer with `ApphelmSurveyView` and sends the answers through the client.
/// Bottom positions (the default) open a sheet at half height; `center` and `top_center`
/// open a card over a dimmed screen.
@MainActor
public enum ApphelmSurveyPresenter {
  /// Present `offer` over `presenter` (default: the top view controller of the key window).
  /// `onClose` runs once when the survey is gone. Returns false when there was nowhere to show it.
  @discardableResult
  public static func present(_ offer: SurveyOffer, client: ApphelmClient, from presenter: UIViewController? = nil, onClose: (() -> Void)? = nil) -> Bool {
    guard let host = presenter ?? topViewController() else { return false }
    let model = SurveyViewModel(
      offer: offer,
      onRespond: { answer in Task { _ = try? await client.surveyRespond(exposureId: offer.exposureId, answer: answer) } },
      onDismiss: { Task { _ = try? await client.surveyDismiss(exposureId: offer.exposureId) } },
      onClose: {})
    let appearance = model.appearance
    let controller: SurveyHostingController
    if appearance.isCard {
      controller = SurveyHostingController(rootView: AnyView(SurveyCard(model: model)))
      controller.modalPresentationStyle = .overFullScreen
      controller.modalTransitionStyle = .crossDissolve
      controller.view.backgroundColor = .clear
    } else {
      controller = SurveyHostingController(rootView: AnyView(ScrollView { ApphelmSurveyView(model: model) }.background(Color(surveyHex: appearance.backgroundColor).ignoresSafeArea())))
      controller.modalPresentationStyle = .pageSheet
      if let sheet = controller.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
      }
      controller.view.backgroundColor = UIColor(Color(surveyHex: appearance.backgroundColor))
    }
    var gone = false
    model.onClose = { [weak controller] in
      guard !gone else { return }
      gone = true
      controller?.dismiss(animated: true)
      onClose?()
    }
    controller.onSwipeDismiss = { [weak model] in
      gone = true
      model?.leave()
      onClose?()
    }
    controller.presentationController?.delegate = controller
    host.present(controller, animated: true)
    return true
  }

  static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let active = scenes.filter { $0.activationState == .foregroundActive }
    let windows = (active.isEmpty ? scenes : active).flatMap(\.windows)
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
    return top
  }
}
#endif
