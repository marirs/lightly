import Foundation

/// A single reversible operation applied to a photograph.
///
/// Spec §27 requires the history structure to exist from day one even though V1
/// exposes only a single Undo. Cases beyond `develop` are declared now because
/// the shape of the stack determines whether later features can be reversed at
/// all; retrofitting that is far more expensive than reserving it.
enum EditOperation: Equatable, Sendable {
    /// The Develop engine produced a recipe.
    case develop(DevelopRecipe)
    /// A Look was applied.
    ///
    /// Carries the recipe as well as the identifier so the stack is
    /// self-describing: history can be replayed without consulting the preset
    /// catalogue, and a Look that is later renamed or withdrawn cannot
    /// invalidate an edit already made.
    case look(id: String, recipe: DevelopRecipe)

    /// The intensity of the applied Look changed.
    ///
    /// Intensity is stored separately from the Look's recipe (spec §7), so it
    /// is its own reversible step rather than a mutation of the Look entry.
    case intensity(Double)
    /// A crop was committed.
    case crop
    /// A repair operation was applied.
    case repair
}

/// The non-destructive edit stack for one photograph (spec §27).
///
/// The original is the implicit root and is never stored as an operation — it
/// cannot be undone, only returned to. Reversing an operation removes it from
/// the stack; it never reprocesses or rewrites the source asset.
struct EditHistory: Equatable, Sendable {

    /// Operations in application order. The original sits conceptually before
    /// index 0.
    private(set) var operations: [EditOperation] = []

    /// Whether anything can be undone.
    var canUndo: Bool { !operations.isEmpty }

    /// Whether the photograph has been developed.
    ///
    /// This is the single source of truth for gating Compare: spec §0.11 and
    /// §4.3 require Compare to be unavailable until a developed version exists,
    /// and deriving it from history means the rule cannot drift out of sync
    /// with what has actually been applied.
    var hasDevelopedVersion: Bool {
        operations.contains { operation in
            if case .develop = operation { return true }
            return false
        }
    }

    /// The recipe produced by the most recent Develop, if any.
    var currentDevelopRecipe: DevelopRecipe? {
        for operation in operations.reversed() {
            if case .develop(let recipe) = operation { return recipe }
        }
        return nil
    }

    /// The identifier of the currently applied Look, if any.
    var currentLookID: String? {
        currentLook?.id
    }

    /// The currently applied Look's identifier and recipe.
    private var currentLook: (id: String, recipe: DevelopRecipe)? {
        for operation in operations.reversed() {
            if case .look(let id, let recipe) = operation { return (id, recipe) }
        }
        return nil
    }

    /// The intensity applied to the current Look, `1` when untouched.
    ///
    /// Only intensity changes recorded *after* the most recent Look count:
    /// applying a new Look resets intensity to full rather than inheriting the
    /// previous Look's setting.
    var currentIntensity: Double {
        for operation in operations.reversed() {
            switch operation {
            case .intensity(let value): return value
            case .look: return 1
            default: continue
            }
        }
        return 1
    }

    /// The recipe describing the current state of the photograph.
    ///
    /// Composes the Develop result with the applied Look, scaled by intensity.
    /// This is the single definition of "what the image should look like now",
    /// so rendering can never disagree with history.
    var composedRecipe: DevelopRecipe {
        let base = currentDevelopRecipe ?? .unmodified
        guard let look = currentLook else { return base }
        return base.combined(with: look.recipe.scaled(by: currentIntensity))
    }

    /// Appends an operation to the stack.
    mutating func record(_ operation: EditOperation) {
        operations.append(operation)
    }

    /// Records an intensity change, coalescing consecutive adjustments.
    ///
    /// A slider drag would otherwise push dozens of entries onto the stack and
    /// make Undo useless — the user expects one undo to reverse "the intensity
    /// change", not the last pixel of drag.
    mutating func recordIntensity(_ value: Double) {
        if case .intensity = operations.last {
            operations[operations.count - 1] = .intensity(value)
        } else {
            operations.append(.intensity(value))
        }
    }

    /// Removes and returns the most recent operation.
    ///
    /// - Returns: The reversed operation, or `nil` when already at the original.
    @discardableResult
    mutating func undo() -> EditOperation? {
        operations.popLast()
    }

    /// Returns to the original, discarding every operation.
    ///
    /// Backs the `Reset` action in the More screen (spec §12).
    mutating func reset() {
        operations.removeAll()
    }
}
