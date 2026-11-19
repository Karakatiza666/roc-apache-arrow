import ListItems

## A zero-copy view of one list value's items: rows `start ..< start + count`
## of a child column, read on demand. `src` is the source, a type with two
## methods:
##
## - `item_at : src, U64 -> item` reads one child row;
## - `iter_range : src, U64, U64 -> Iter(item)` iterates `count` child rows
##   from `start`. A source over a plain values list returns
##   `values.sublist(..).iter()`; any other source returns `Items.walk(..)`.
##
## The view holds no closure, so it stays a plain value inside `Try`, tuples
## and records (a closure there is boxed: one allocation per value).
Items(item, src) :: { src : src, start : U64, count : U64 }.{

	## The view of child rows `start ..< start + count`. The caller makes sure
	## the source has those rows (for example from validated list offsets).
	view : src, U64, U64 -> Items(item, src)
		where [src.item_at : src, U64 -> item]
	view = |src, start, count| { src, start, count }

	## A view over a Roc list, for tests and for code that has no column.
	from_list : List(item) -> Items(item, ListItems(item))
	from_list = |list| { src: ListItems.wrap(list), start: 0, count: list.len() }

	## The item count. O(1).
	len : Items(item, src) -> U64
	len = |xs| xs.count

	## Whether the count is 0.
	is_empty : Items(item, src) -> Bool
	is_empty = |xs| xs.count == 0

	## Item `j`, read from the source.
	get : Items(item, src), U64 -> Try(item, [OutOfBounds])
		where [src.item_at : src, U64 -> item]
	get = |xs, j| if (j < xs.count) Ok(xs.src.item_at(xs.start + j)) else Err(OutOfBounds)

	## The items in order, read one at a time: `for x in xs { .. }`.
	iter : Items(item, src) -> Iter(item)
		where [src.iter_range : src, U64, U64 -> Iter(item)]
	iter = |xs| xs.src.iter_range(xs.start, xs.count)

	## Copy the items into a new list: one allocation, every item read once.
	to_list : Items(item, src) -> List(item)
		where [src.item_at : src, U64 -> item]
	to_list = |xs| {
		var $out = List.with_capacity(xs.count)
		var $j = xs.start
		while $j < xs.start + xs.count {
			$out = $out.append(xs.src.item_at($j))
			$j = $j + 1
		}
		$out
	}

	## An iterator over `count` rows of `src` from `start`, each read with
	## `item_at`: the `iter_range` of a source that has no values list.
	walk : src, U64, U64 -> Iter(item)
		where [src.item_at : src, U64 -> item]
	walk = |src, start, count| {
		end = start + count
		Iter.custom(start, Ok(count), |j| if (j < end) Ok((src.item_at(j), j + 1)) else Err(NoMore))
	}
}

Squares := {}.{
	item_at : Squares, U64 -> U64
	item_at = |_, j| j * j

	iter_range : Squares, U64, U64 -> Iter(U64)
	iter_range = |src, start, count| Items.walk(src, start, count)
}

expect {
	src : Squares
	src = {}
	xs = Items.view(src, 2, 3)
	var $sum = 0
	for x in xs {
		$sum = $sum + x
	}
	$sum == 4 + 9 + 16 and xs.get(1) == Ok(9) and xs.get(3) == Err(OutOfBounds) and xs.to_list() == [4, 9, 16] and xs.len() == 3
}

expect {
	xs = Items.from_list(["a", "b"])
	xs.to_list() == ["a", "b"] and xs.get(0) == Ok("a") and !xs.is_empty() and Items.from_list([]).is_empty() and xs.iter().collect() == ["a", "b"]
}
