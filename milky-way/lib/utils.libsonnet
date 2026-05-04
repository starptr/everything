{
  assertEqualAndReturn(got, expected):: (
    assert got == expected : 'Expected ' + std.toString(expected) + ', got ' + std.toString(got);
    got
  ),
  assertAndReturn(value, predicate, message=('Value ' + std.toString(value) + ' did not satisfy predicate')):: (
    assert predicate(value) : message;
    value
  ),
}