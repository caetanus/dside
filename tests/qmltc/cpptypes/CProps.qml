// TypeWithProperties (also verbatim from the corpus) mixes double/QString/int properties, with
// differently-named notify signals (bChanged, dSignal) — the registry supplies both the types
// and the notify names, so no <prop>Changed spelling is assumed.
import QmltcTests
TypeWithProperties {
    a: 1.5
    b: "beta"
    d: 4
    property double doubled: a * 2
    property string tag: b + "/" + d
}
