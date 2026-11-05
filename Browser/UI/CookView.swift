import SwiftUI
import WebKit

/// A recipe as its page publishes it (schema.org): the site's own amounts and
/// steps, with nothing written by a model, since a wrong amount spoils the dish.
struct Recipe: Sendable {
    let title: String
    let site: String
    let servings: String?
    let time: String?
    let ingredients: [String]
    let steps: [String]
}

enum RecipeReader {
    private static let script = """
    const recipes = n => {
      if (!n) return [];
      if (Array.isArray(n)) return n.flatMap(recipes);
      if (typeof n !== "object") return [];
      const type = n["@type"];
      if (type === "Recipe" || (Array.isArray(type) && type.includes("Recipe"))) return [n];
      return recipes(n["@graph"]).concat(recipes(n.mainEntity), recipes(n.mainEntityOfPage));
    };
    let recipe = null;
    for (const tag of document.querySelectorAll('script[type="application/ld+json"]')) {
      try { recipe = recipes(JSON.parse(tag.textContent))[0] || null; } catch (e) {}
      if (recipe) break;
    }
    if (!recipe) return null;
    const clean = t => new DOMParser().parseFromString(String(t), "text/html").body.textContent.replace(/\\s+/g, " ").trim();
    const steps = [];
    const walk = i => {
      if (!i) return;
      if (typeof i === "string") { for (const part of i.split(/\\n+|<\\/(?:p|li)>/i)) { const s = clean(part); if (s) steps.push(s); } return; }
      if (Array.isArray(i)) { i.forEach(walk); return; }
      if (i.itemListElement) { walk(i.itemListElement); return; }
      const s = clean(i.text || i.name || "");
      if (s) steps.push(s);
    };
    walk(recipe.recipeInstructions);
    const given = [].concat(recipe.recipeIngredient || recipe.ingredients || []);
    const servings = [].concat(recipe.recipeYield || [])[0];
    return {
      title: clean(recipe.name || document.title),
      site: location.hostname.replace(/^www\\./, ""),
      servings: servings === undefined ? "" : clean(servings),
      time: String(recipe.totalTime || ""),
      ingredients: given.map(clean).filter(Boolean),
      steps: steps
    };
    """

    static func read(_ webView: WKWebView) async -> Recipe? {
        let result = try? await webView.callAsyncJavaScript(script, contentWorld: .world(name: "reader"))
        guard let fields = result as? [String: Any],
              let ingredients = fields["ingredients"] as? [String], ingredients.count >= 2,
              let steps = fields["steps"] as? [String], !steps.isEmpty else { return nil }
        let servings = fields["servings"] as? String ?? ""
        return Recipe(title: fields["title"] as? String ?? "", site: fields["site"] as? String ?? "",
                      servings: servings.isEmpty ? nil : servings.allSatisfy(\.isNumber) ? "Serves \(servings)" : servings,
                      time: minutes(fields["time"] as? String ?? ""),
                      ingredients: ingredients, steps: steps)
    }

    /// "PT1H15M" as "1 h 15 min".
    private static func minutes(_ duration: String) -> String? {
        guard let match = duration.wholeMatch(of: /P(?:0D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:\d+S)?/) else { return nil }
        let parts = [match.1.map { "\($0) h" }, match.2.flatMap { $0 == "0" ? nil : "\($0) min" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

@Observable
final class CookModel: Identifiable {
    let recipe: Recipe
    var step = 0
    var ticked: Set<Int> = []

    init(recipe: Recipe) {
        self.recipe = recipe
    }
}

/// Cook Mode: one step at a time in big type, the ingredients to tick off, the
/// screen kept awake. It takes the pose it's given. Propped open, the step stands
/// above the fold and the rest lies below it, so a floury finger never has to push
/// on the part standing up. Held open sideways, a page each side of the fold.
struct CookView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.fold) private var fold
    let model: CookModel
    /// Which way the last turn went, for the way the next step slides in.
    @State private var goingOn = true

    private var ink: Color { Color(uiColor: BookStyle.ink) }
    private var faint: Color { Color(uiColor: BookStyle.faint) }
    private var tint: Color { PageKind.recipe.tint }
    private var steps: [String] { model.recipe.steps }
    private var isLast: Bool { model.step >= steps.count - 1 }
    private var timers: CookTimers { .shared }

    var body: some View {
        GeometryReader { proxy in
            let safe = proxy.safeAreaInsets
            let size = CGSize(width: proxy.size.width + safe.leading + safe.trailing,
                              height: proxy.size.height + safe.top + safe.bottom)
            arrangement(size: size, safe: safe)
                .frame(width: size.width, height: size.height)
                .background(Color(uiColor: BookStyle.paper))
                .ignoresSafeArea()
        }
        .foregroundStyle(ink)
        .statusBarHidden(false)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder
    private func arrangement(size: CGSize, safe: EdgeInsets) -> some View {
        if let fold, fold.height > fold.width {
            // Held open sideways: what to have on the left, what to do on the right.
            HStack(spacing: 0) {
                ingredients.padding(.top, BookStyle.topMargin).frame(width: fold.minX)
                Color.clear.frame(width: fold.width)
                VStack(spacing: 16) {
                    stepPanel(close: false)
                    turnRow
                }
                .padding(.top, BookStyle.topMargin)
                .padding(.leading, 28)
                .padding(.trailing, BookStyle.outerMargin)
                .padding(.bottom, max(safe.bottom, 20))
            }
            .overlay(alignment: .topTrailing) {
                closeButton.padding(.top, BookStyle.clockClearance).padding(.trailing, 24)
            }
        } else if let fold {
            // Propped open: the step stands up, everything to touch lies flat.
            VStack(spacing: 0) {
                stepPanel(close: true)
                    .padding(.top, safe.top + 4)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
                    .frame(height: fold.minY)
                Color.clear.frame(height: fold.height)
                HStack(spacing: 8) {
                    ingredients
                    VStack(spacing: 8) {
                        nextButton.frame(maxHeight: .infinity)
                        backButton
                    }
                    .frame(width: 190)
                    .padding(.trailing, 20)
                }
                .padding(.top, 14)
                .padding(.bottom, max(safe.bottom, 20))
            }
        } else if size.width > size.height {
            HStack(spacing: 0) {
                ingredients.frame(width: size.width * 0.4)
                VStack(spacing: 12) {
                    stepPanel(close: true)
                    turnRow
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 16)
            .padding(.leading, safe.leading)
            .padding(.trailing, safe.trailing)
            .padding(.bottom, max(safe.bottom, 12))
        } else {
            VStack(spacing: 0) {
                stepPanel(close: true)
                    .padding(.top, safe.top + 4)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                    .frame(height: size.height * 0.56)
                ingredients.frame(maxHeight: .infinity)
                turnRow
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .padding(.bottom, max(safe.bottom, 16))
            }
        }
    }

    // MARK: The step

    private func stepPanel(close: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(model.step + 1)")
                    .font(.system(size: 46, weight: .semibold, design: .serif))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText(value: Double(model.step)))
                Text("of \(steps.count)")
                    .font(.system(size: 18, design: .serif))
                    .foregroundStyle(faint)
                Spacer(minLength: 0)
                if close { closeButton.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 8 } }
            }
            if !timers.running.isEmpty { timerRow }
            // The biggest size this step fits at; a very long one scrolls rather than being cut.
            ViewThatFits(in: .vertical) {
                ForEach([40, 34, 28, 24] as [CGFloat], id: \.self) { stepText(size: $0) }
                ScrollView { stepText(size: 22) }.scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(model.step)
            .transition(.push(from: goingOn ? .trailing : .leading))
            .tint(tint)
            // A time in the step, tapped: its timer.
            .environment(\.openURL, OpenURLAction { url in
                if let seconds = Int(url.host() ?? "") { startTimer(seconds) }
                return .handled
            })
        }
        .clipped()
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 24).onEnded { drag in
            guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
            turn(by: drag.translation.width < 0 ? 1 : -1)
        })
    }

    /// The step, with each time in it a link that starts its timer.
    private var stepWithTimes: AttributedString {
        let step = steps[min(model.step, steps.count - 1)]
        var text = AttributedString(step)
        for time in CookTime.find(in: step) {
            guard let range = Range(time.range, in: text) else { continue }
            text[range].link = URL(string: "timer://\(time.seconds)")
            text[range].underlineStyle = timers.isRunning(seconds: time.seconds, step: model.step, recipe: model.recipe.title) ? nil : .single
        }
        return text
    }

    private func stepText(size: CGFloat) -> some View {
        Text(stepWithTimes)
            .font(.system(size: size, design: .serif))
            .lineSpacing(size * 0.14)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Timers

    /// Each one running, big enough to read across a kitchen, and a way to call it
    /// off. Side by side while they fit, then one under another, none out of reach.
    private var timerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { timerItems }
            VStack(alignment: .leading, spacing: 0) { timerItems }
        }
    }

    private var timerItems: some View {
        ForEach(timers.running) { timer in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    if timer.isRinging {
                        Text("Time's up")
                    } else {
                        Text(timerInterval: Date.now...max(timer.endsAt, .now), countsDown: true)
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(tint)
                .fixedSize()
                Text(timer.recipe == model.recipe.title ? "step \(timer.step + 1)" : timer.recipe)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(faint)
                    .lineLimit(1)
                Button { timers.end(timer) } label: {
                    Glyph(.close, size: 13, weight: 2)
                        .foregroundStyle(faint)
                        .frame(width: 32, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                .accessibilityLabel(timer.isRinging ? "Stop this timer" : "Cancel this timer")
            }
        }
    }

    private func startTimer(_ seconds: Int) {
        Task {
            if let problem = await timers.start(seconds: seconds, step: model.step, recipe: model.recipe.title) {
                browser.showToast(problem)
            }
        }
    }

    // MARK: Turning

    private var turnRow: some View {
        HStack(spacing: 8) {
            backButton.frame(width: 110)
            nextButton
        }
        .frame(height: 68)
    }

    private var nextButton: some View {
        Button { isLast ? (browser.cook = nil) : turn(by: 1) } label: {
            HStack(spacing: 10) {
                Text(isLast ? "Done" : "Next")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                if !isLast { Glyph(.forward, size: 20, weight: 2) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ink.opacity(0.09), in: .rect(cornerRadius: 22, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
    }

    /// Holds its place on the first step, so Next doesn't shift.
    private var backButton: some View {
        Button { turn(by: -1) } label: {
            HStack(spacing: 8) {
                Glyph(.back, size: 18, weight: 2)
                Text("Back").font(.system(size: 18, design: .serif))
            }
            .foregroundStyle(faint)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .opacity(model.step == 0 ? 0 : 1)
        .disabled(model.step == 0)
    }

    private var closeButton: some View {
        Button { browser.cook = nil } label: {
            Glyph(.close, size: 18, weight: 2).frame(width: 48, height: 48).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Cook Mode")
    }

    private func turn(by change: Int) {
        let next = model.step + change
        guard steps.indices.contains(next) else { return }
        goingOn = change > 0
        withAnimation(.snappy(duration: 0.34)) { model.step = next }
    }

    // MARK: What to have

    private var ingredients: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.recipe.title)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .lineSpacing(2)
                Text([model.recipe.servings, model.recipe.time, model.recipe.site].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(faint)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                ForEach(Array(model.recipe.ingredients.enumerated()), id: \.offset) { index, item in
                    ingredient(item, index: index)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        // What scrolls below dissolves rather than being cut off at the edge.
        .overlay(alignment: .bottom) { FadeEdge(color: Color(uiColor: BookStyle.paper), height: 28).offset(y: 28) }
    }

    /// Ticked off with a tap, as a recipe's are in a summary.
    private func ingredient(_ item: String, index: Int) -> some View {
        let ticked = model.ticked.contains(index)
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if ticked { model.ticked.remove(index) } else { model.ticked.insert(index) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(ticked ? tint : faint, lineWidth: 1.6)
                    if ticked {
                        Circle().fill(tint)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(uiColor: BookStyle.paper))
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .frame(width: 24, height: 24)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                Text(item)
                    .font(.system(size: 19, design: .serif))
                    .foregroundStyle(ticked ? faint : ink)
                    .strikethrough(ticked, color: faint)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(ticked ? .isSelected : [])
    }
}
