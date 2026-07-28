// `property alias` whose target is a property of the C++ BASE type (not one declared here).
// `xy` carries NOTIFY xyChanged, so the alias — which we compile as a recomputed copy — can
// actually stay in sync; a MEMBER property with no NOTIFY is refused rather than emitted stale.
import QmltcTests
TypeWithSpecialProperties {
    id: root
    xy: "pair"
    property alias xyAlias: root.xy
    property string tagged: xyAlias + "!"
}
