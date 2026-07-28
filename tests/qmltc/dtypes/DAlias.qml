// Same, with a D base: an inherited @Property is a real field, so the alias reads it directly.
import AppTypes 1.0
Backend {
    id: root
    value: 7
    label: "seven"
    property alias valueAlias: root.value
    property alias labelAlias: root.label
    property int plus: valueAlias + 1
}
