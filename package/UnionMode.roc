## Sparse unions have every child at full length; dense unions add an i32
## offsets buffer.
UnionMode := [Sparse, Dense].{

	## Derived structural equality: `==` and `!=`.
	is_eq : _
}
