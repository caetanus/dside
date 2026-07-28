// A list<> of a VALUE type (not QtObject): the elements are ints living in the property itself,
// reached by index, and length is readable. Distinct from ListHolder's list<QtObject>, whose
// elements are separate objects the engine reaches through the list reference.
import QtQml
QtObject {
    property list<int> nums: [3, 1, 4]
    property int count: nums.length
    property int first: nums[0]
    property int last: nums[nums.length - 1]
}
