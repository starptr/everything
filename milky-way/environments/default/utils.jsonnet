{
  assertEqualAndReturn(got, expected):: (
    assert got == expected : 'Expected ' + std.toString(expected) + ', got ' + std.toString(got);
    got
  ),
}