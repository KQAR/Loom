import IdentifiedCollections
import LoomSharedModels

/// A value the two change-detection systems **announce** rather than diff.
///
/// Two independent change-detection systems compare the capture window on the main
/// thread, and both do it elementwise: TCA's `@ObservableState` calls
/// `shouldNotifyObservers(old, new)` on every assignment to a stored property, and
/// SwiftUI's AttributeGraph compares a view's output value and an
/// `NSViewRepresentable`'s stored properties (`AGDispatchEquatable`) to decide
/// whether anything changed. With a 20 000-row window of `Flow` — a struct whose
/// synthesized `==` walks the header arrays, `FlowTransport`, `UpstreamTLSInfo`,
/// `SourceDevice` and `FlowOutcome` — that was **58 % of the main thread while
/// scrolling**, against 2 % for the table's own diff, cells and glide. Five call
/// sites, none of them the list:
///
/// | site | share of a 30 s scroll |
/// |---|---|
/// | `flows.setter` → `shouldNotifyObservers` | 16 % |
/// | `visibleFlows.setter` → `shouldNotifyObservers` | 16 % |
/// | AttributeGraph comparing the view body's output | 19 % |
/// | AttributeGraph comparing `RequestTable`'s stored rows | 8 % |
///
/// Every one of those comparisons asks a question whose answer is already known:
/// the window is assigned only when a batch changed it.
///
/// **So this type is deliberately not `Equatable`, and that is the whole mechanism.**
/// The `@ObservableState` macro picks its `shouldNotifyObservers` overload from the
/// member's static type — a non-`Equatable` member takes the one that returns `true`
/// — and AttributeGraph's field-by-field compare bails at the first field it cannot
/// compare. Both then cost O(1) and both answer "changed", which is the truth.
///
/// A version stamp would have been the other way to do it, and it is worse: a stamp
/// lands in `State`'s synthesized `Equatable`, so two states with identical contents
/// compare unequal when one of them was assigned a different *number of times*. That
/// is an implementation detail, and it broke four `TestStore` assertions the moment
/// it existed. `CaptureFeature.State.==` is written by hand instead, comparing
/// `value`, and `StateEqualityCensusTests` fails when a stored property is added
/// without being compared.
///
/// The cost of always answering "changed" is one redundant `updateNSView` on a graph
/// pass where the rows happened not to move; `RowDiff` reports `.none` and nothing
/// visual runs. A missed update — the failure mode of a cheap hand-written
/// `Flow.==` that skips a field — cannot happen.
///
/// Reading is the wrapped collection, so a call site that counts, subscripts,
/// iterates or maps does not know this type exists.
public struct Versioned<Value: RandomAccessCollection>: RandomAccessCollection
where Value.Index == Int {
    /// The contents live behind a reference **on purpose**, and this is the half of
    /// the mechanism that AttributeGraph needs.
    ///
    /// Not being `Equatable` is enough for TCA, which picks its `shouldNotifyObservers`
    /// overload from the member's static type. It is *not* enough for AttributeGraph:
    /// `AG::LayoutDescriptor::compare` walks a value's field layout and dispatches on
    /// each field's own conformance, so a struct wrapping a `[Flow]` is descended into
    /// and the array is deep-compared anyway — measured, that left the layout half of
    /// the cost exactly where it was. A single reference field is one pointer, which
    /// is compared by identity: a new box after every `replace(with:)`, so "changed"
    /// is the answer and it costs nothing to reach.
    private final class Box {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private var box: Box

    public var value: Value { box.value }

    public init(_ value: Value) { box = Box(value) }

    /// Replace the contents. Named rather than a setter so the call site reads as
    /// the one thing this type is about: the change is announced, not diffed.
    public mutating func replace(with newValue: Value) { box = Box(newValue) }

    /// Whether this holds the *same contents object* as `other` — O(1), and the only
    /// comparison this type offers.
    ///
    /// It exists because the cheap answer has to land somewhere: AttributeGraph can no
    /// longer tell whether the window moved, so `RequestTable.updateNSView` now runs on
    /// graph passes that changed nothing else. Asking here costs a pointer compare;
    /// asking AttributeGraph cost a walk of 20 000 `Flow`s.
    public func isIdentical(to other: Self) -> Bool { box === other.box }

    public var startIndex: Int { value.startIndex }
    public var endIndex: Int { value.endIndex }
    public subscript(position: Int) -> Value.Element { value[position] }
    public func index(after i: Int) -> Int { value.index(after: i) }
    public func index(before i: Int) -> Int { value.index(before: i) }
}

// The box is immutable and never shared across a mutation (`replace` makes a new
// one), so the reference does not weaken the value semantics this promises.
extension Versioned: @unchecked Sendable where Value: Sendable {}

extension Versioned where Value == IdentifiedArrayOf<Flow> {
    public init() { self.init([]) }
    public subscript(id id: Flow.ID) -> Flow? { value[id: id] }
    public func index(id: Flow.ID) -> Int? { value.index(id: id) }
    /// The backing array, handed over without copying.
    public var elements: [Flow] { value.elements }
}

extension Versioned where Value == [Flow] {
    public init() { self.init([]) }
}
