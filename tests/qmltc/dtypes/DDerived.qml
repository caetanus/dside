// Inherited properties feed a chain of derived bindings, and a string property of the D base
// is concatenated — exercising both scalar kinds through the base type.
import AppTypes 1.0
Backend {
    value: 7
    label: "unit"
    property int twice: value * 2
    property int quad: twice * 2
    property string tag: label + "-" + value
}
