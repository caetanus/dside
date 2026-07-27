import App 1.0
import QtQml 2.15
// The D backing constructor of Boom throws. The engine still asks the factory to create it;
// the failure must be OBSERVABLE (recorded, warned) and must NOT crash the process.
Boom {
    value: 3
}
